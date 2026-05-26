// `WindowBackend` conformance using only AX + public macOS APIs
// (no `rift-cli`, no SLS, no SIP-off injection). Phase α–ε grows
// each method from a no-op stub into a real implementation; this
// file is the seam.
//
// Phase plan (memory: facet-architecture-decisions):
//   α  — virtual workspace state self-managed; focus
//   β  — window move across workspaces; off-screen park/unpark
//        (`anchor` + `minimize` hide methods, memory:
//        native-window-hide-methods)
//   γ  — tiling layout engines
//   δ  — display reconfigure handling, geometry persistence
//   ε  — `FacetAdapterRift` deprecation
//
// Today (this file's birthday) we land a skeleton: every
// `WindowBackend` requirement is satisfied so the type is usable
// where `RiftAdapter` is. No backend selection wiring yet —
// `Main.swift` still constructs `RiftAdapter()`. The selection
// flip lands in the PR that fills in the Phase α queries.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

public final class NativeAdapter: WindowBackend, @unchecked Sendable {
    public let name = "native"

    /// Tentative layout-mode set — revisited at Phase γ when the
    /// tiling engines land. Keeping non-empty so the right-click
    /// menu builder doesn't trip over an empty list during the
    /// transition window where some views ask the backend's
    /// supported modes at startup.
    public let layoutModes = ["bsp", "stack"]

    // MARK: - Self-managed workspace state (Phase α)

    /// Index (1-based, user-facing) of the active workspace.
    /// Phase α implements `switchWorkspace` by mutating this and
    /// re-emitting `BackendEvent.refreshNeeded`.
    private var activeIndex: Int = 1

    /// Snapshot of workspaces, rebuilt every `workspaces()` call
    /// from the current CGWindowList enumeration + windowMap.
    private var workspaceList: [Workspace] = []

    /// Window → 1-based workspace index. Survives across
    /// reconciles so a window the user moved stays where they put
    /// it (Phase α-2 will give them the means to move; today
    /// every new window lands in `activeIndex`).
    private var windowMap: [WindowID: Int] = [:]

    /// Position the window held *before* facet parked it. Recorded
    /// at the moment of park so the matching `restoreAnchor` puts
    /// it back exactly. macOS-side window-state shenanigans (user
    /// drag while parked, etc.) would lose accuracy here — Phase β
    /// proper will cache `axSize` too so we can offer a sanity
    /// "if size changed, leave at park position" branch.
    private var originalPositions: [WindowID: CGPoint] = [:]

    /// Windows currently parked at the bottom-right sliver.
    /// `parkAnchor` early-exits when a window is already in this
    /// set so a poll-driven refresh can't re-park-on-top-of-park.
    private var parkedAnchorWindows: Set<WindowID> = []

    /// Windows currently minimized by facet. Mirrors the anchor
    /// set but tracks a different OS state (Dock minimization vs
    /// off-screen position). Separate so a runtime hide_method
    /// flip wouldn't conflate the two.
    private var parkedMinimizedWindows: Set<WindowID> = []

    /// Held so `refreshCatalog` can read the configured workspace
    /// list each tick (handles config hot-reload once the
    /// Controller starts piping it through, future PR).
    private let config: FacetConfig

    /// AX-driven event observer. Cuts the lag between "user
    /// opened a window" and "facet sees it" from the Controller's
    /// 2 s poll cadence to the system's own AX latency.
    /// Held here for the adapter's lifetime; never `stop()`d.
    private var eventObserver: WindowEventObserver?

    // MARK: - Event / error streams

    private let eventStream: AsyncStream<BackendEvent>
    private let eventContinuation: AsyncStream<BackendEvent>.Continuation
    private let errorStream: AsyncStream<String>
    private let errorContinuation: AsyncStream<String>.Continuation

    /// Init with config so workspace count + names come from the
    /// user's `[workspace]` section. The (default = 5) fallback in
    /// FacetConfig keeps a vanilla `~/.config/facet/config.toml`
    /// usable out of the box.
    public init(config: FacetConfig) {
        self.config = config
        var ec: AsyncStream<BackendEvent>.Continuation!
        self.eventStream = AsyncStream { c in ec = c }
        self.eventContinuation = ec
        var errC: AsyncStream<String>.Continuation!
        self.errorStream = AsyncStream { c in errC = c }
        self.errorContinuation = errC

        Log.debug("native: init workspaces="
            + "\(config.effectiveWorkspaceList.count) "
            + "hide_method=\(config.effectiveHideMethod)")

        // AX permission is the foundation of every native-backend
        // operation (focus, title resolution, window enumeration).
        // Same surface as RiftAdapter so the user sees the same
        // hint regardless of which backend is active.
        if !AXIsProcessTrusted() {
            DispatchQueue.main.async { [errorContinuation] in
                errorContinuation.yield(
                    "Accessibility permission not granted — open "
                    + "System Settings → Privacy & Security → "
                    + "Accessibility, enable facet, then restart")
            }
        }

        // AX event subscription. start() must run on main; init
        // is not MainActor-isolated, so hop. Throughput: each
        // observed event yields a single refreshNeeded — Controller
        // already debounces, so a focus burst collapses into one
        // backend.workspaces() round-trip.
        let observer = WindowEventObserver { [eventContinuation] in
            eventContinuation.yield(.refreshNeeded)
        }
        self.eventObserver = observer
        DispatchQueue.main.async {
            MainActor.assumeIsolated { observer.start() }
        }
    }

    public var events: AsyncStream<BackendEvent> { eventStream }
    public var errors: AsyncStream<String> { errorStream }

    // MARK: - Queries (Phase α implements; skeleton returns empty)

    public func workspaces() -> [Workspace] {
        refreshCatalog()
        return workspaceList
    }

    /// Re-enumerate CGWindowList, reconcile against `windowMap`
    /// (new windows → `activeIndex`, gone windows → dropped), and
    /// rebuild `workspaceList` from the current state.
    ///
    /// Called from `workspaces()` so the caller's natural reconcile
    /// cadence drives refresh. CGWindowList costs a few ms on a
    /// busy desktop — fine for facet's 2 s poll interval.
    private func refreshCatalog() {
        let rawLive = enumerateCGWindows()
        // Single focusedWindow() query per refresh — caller's
        // poll cadence (2 s) keeps this cheap. Stamping isFocused
        // here means tree / grid views get the marker without
        // taking on AX knowledge themselves.
        let focusedID = focusedWindow()
        let live = rawLive.map { w in
            Window(id: w.id, pid: w.pid, appName: w.appName,
                   title: w.title,
                   isFocused: w.id == focusedID,
                   isFloating: w.isFloating,
                   frame: w.frame)
        }
        let liveIDs = Set(live.map(\.id))

        // Count diffs for trace, then apply.
        let removed = windowMap.keys.filter {
            !liveIDs.contains($0)
        }.count
        let added = live.filter { windowMap[$0.id] == nil }.count
        if removed > 0 || added > 0 {
            Log.debug("native: refreshCatalog "
                + "added=\(added) removed=\(removed) "
                + "total=\(live.count)")
        }

        // Forget windows that have closed.
        windowMap = windowMap.filter { liveIDs.contains($0.key) }
        // New windows land in the active workspace (memory:
        // facet-workspace-model "newly opened windows → current
        // active facet WS" rule).
        for w in live where windowMap[w.id] == nil {
            windowMap[w.id] = activeIndex
        }

        // Build [Workspace] snapshot — each configured entry gets
        // the live windows currently assigned to its 1-based index.
        let byWS = Dictionary(grouping: live) { w in
            windowMap[w.id] ?? activeIndex
        }
        workspaceList = config.effectiveWorkspaceList.map { entry in
            Workspace(
                index: entry.index - 1,             // 0-based on the wire
                name: entry.name,
                isActive: entry.index == activeIndex,
                layoutMode: "bsp",                  // Phase γ revisits
                windows: byWS[entry.index] ?? [])
        }
    }

    /// Enumerate visible windows via the public CGWindowList API.
    /// Skips:
    ///   - facet's own process (avoid managing our own panel)
    ///   - Window Server scaffolding (StatusIndicator etc.)
    ///   - the `borders` companion app (decorative outlines, AX
    ///     element returns nil so we couldn't operate on them
    ///     anyway)
    /// `isFocused` is left as `false` for now — fills in at
    /// Phase α-1.5 (`focusedWindow()`).
    private func enumerateCGWindows() -> [Window] {
        let opts: CGWindowListOption = [
            .optionOnScreenOnly, .excludeDesktopElements,
        ]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        return raw.compactMap { dict in
            guard
                let cgID = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid = dict[kCGWindowOwnerPID as String] as? Int,
                pid != myPid
            else { return nil }
            let owner = dict[kCGWindowOwnerName as String]
                as? String ?? ""
            // Skip OS scaffolding + the borders companion. The
            // borders app paints decoration overlays that facet
            // shouldn't try to manage; rejecting by name is a
            // pragmatic match given there's no AX handle for them.
            if owner == "Window Server" || owner == "borders" {
                return nil
            }
            let title = dict[kCGWindowName as String] as? String ?? ""
            var frame: CGRect?
            if let b = dict[kCGWindowBounds as String] as? [String: Any] {
                frame = CGRect(
                    x: b["X"]      as? CGFloat ?? 0,
                    y: b["Y"]      as? CGFloat ?? 0,
                    width: b["Width"]  as? CGFloat ?? 0,
                    height: b["Height"] as? CGFloat ?? 0)
            }
            return Window(
                id: WindowID(serverID: Int(cgID)),
                pid: pid,
                appName: owner,
                title: title,
                isFocused: false,     // Phase α-1.5
                isFloating: false,
                frame: frame)
        }
    }

    public func focusedWindow() -> WindowID? {
        // Frontmost app → its AX focused-window attribute →
        // CGWindowID via the private _AXUIElementGetWindow we
        // already dlsym'd. nil when:
        //   - no frontmost app (rare; transient between apps)
        //   - app refuses AX (sandboxed / non-cooperative)
        //   - AX has no focused window for this app right now
        //   - the private symbol moved (we'd notice everywhere
        //     else first, so this case stays silent)
        guard let app = NSWorkspace.shared.frontmostApplication
        else { return nil }
        let pid = pid_t(app.processIdentifier)
        let axApp = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedWindowAttribute as CFString, &winRef)
        guard err == .success, let raw = winRef else { return nil }
        // `kAXFocusedWindowAttribute` always returns an
        // AXUIElement; the cast is unconditional (Swift warns on
        // `as?`). force-cast here matches the AX type contract.
        let element = raw as! AXUIElement
        guard let cgID = AXGeom.cgWindowID(of: element) else {
            return nil
        }
        return WindowID(serverID: Int(cgID))
    }

    // MARK: - Commands (Phase α-2 lands the state mutations;
    // Phase β adds hide / show side-effects on top.)

    public func switchWorkspace(toIndex index: Int) {
        // Backend protocol convention is 0-based; internal state
        // (matching the user-facing CLI) is 1-based. Translate
        // at the seam.
        let target = index + 1
        guard isValidWorkspace(target),
              target != activeIndex else { return }
        let oldActive = activeIndex
        activeIndex = target
        Log.debug("native: switchWorkspace \(oldActive) -> \(target) "
            + "(hide_method=\(config.effectiveHideMethod))")

        // Apply hide / show side-effects via the configured method.
        // Today only `"anchor"` is wired; `"minimize"` lands in the
        // next slice (Phase β-2) and any future deep-core methods
        // come with `facet-x` (M6+).
        switch config.effectiveHideMethod {
        case "anchor":
            applyAnchorHide(oldActive: oldActive, newActive: target)
        case "minimize":
            applyMinimizeHide(oldActive: oldActive, newActive: target)
        default:
            break
        }
        eventContinuation.yield(.refreshNeeded)
    }

    public func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        let target = index + 1
        guard isValidWorkspace(target),
              windowMap[id] != nil,
              windowMap[id] != target else { return }
        let oldWS = windowMap[id]!
        windowMap[id] = target
        Log.debug("native: moveWindow \(id.serverID) WS "
            + "\(oldWS) -> \(target)")
        // Hide / show side-effect for this single window.
        if let w = enumerateCGWindows().first(where: { $0.id == id }) {
            let movingToActive = (target == activeIndex)
            switch config.effectiveHideMethod {
            case "anchor":
                movingToActive ? restoreAnchor(w) : parkAnchor(w)
            case "minimize":
                movingToActive ? restoreMinimize(w) : parkMinimize(w)
            default:
                break
            }
        }
        eventContinuation.yield(.refreshNeeded)
    }

    /// True when `n` is a 1-based index that exists in the
    /// configured workspace set. Sparse configs (e.g. user only
    /// declared `1 = "dev", 3 = "sns"`) are honoured — N=2 is
    /// invalid in that case even though raw count >= 2.
    private func isValidWorkspace(_ n: Int) -> Bool {
        config.effectiveWorkspaceList.contains { $0.index == n }
    }

    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        // Phase γ.
    }

    public func closeWindow(_ id: WindowID) {
        // Phase β: AX `kAXCloseButtonAttribute` perform action.
    }

    public func perform(_ action: WindowAction) {
        // Phase γ.
    }

    public func windowMenu(mode: String, floating: Bool) -> [WindowMenuItem] {
        // Phase γ: layout-mode-specific items. Empty stub is fine
        // for now — the right-click menu hides when items.isEmpty.
        []
    }

    // MARK: - Anchor hide / show (Phase β preview)

    /// Park every window of `oldActive`, restore every window of
    /// `newActive`. Called from `switchWorkspace` after the
    /// `activeIndex` swap.
    private func applyAnchorHide(oldActive: Int, newActive: Int) {
        let live = enumerateCGWindows()
        let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        var parked = 0, restored = 0
        for (wid, ws) in windowMap where ws == oldActive {
            if let w = byID[wid] {
                parkAnchor(w)
                parked += 1
            }
        }
        for (wid, ws) in windowMap where ws == newActive {
            if let w = byID[wid] {
                restoreAnchor(w)
                restored += 1
            }
        }
        Log.debug("native: anchor parked=\(parked) restored=\(restored)")
    }

    /// Move `w` to a 1×41 px sliver in the bottom-right corner of
    /// the display it currently sits on. macOS's clamp guarantees
    /// 41 px of title-bar stays on-screen (memory:
    /// native-window-hide-methods), so we can't fully hide via
    /// public APIs — anchor minimises the visible footprint while
    /// keeping the window recoverable from Mission Control if
    /// facet crashes (memory: facet-buddha-palm-principle).
    private func parkAnchor(_ w: Window) {
        guard !parkedAnchorWindows.contains(w.id) else { return }
        let pid = pid_t(w.pid)
        guard
            let ax = AXGeom.window(for: CGWindowID(w.id.serverID), pid: pid),
            let pos = AXGeom.position(ax),
            let size = AXGeom.size(ax)
        else { return }
        originalPositions[w.id] = pos
        let center = CGPoint(x: pos.x + size.width / 2,
                             y: pos.y + size.height / 2)
        let screen = Displays.containing(center)
        let hidden = CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
        AXGeom.setPosition(ax, hidden)
        parkedAnchorWindows.insert(w.id)
    }

    /// Reverse of `parkAnchor`: place the window back at its
    /// pre-park position. No-ops when the window isn't currently
    /// parked (defensive against double-restore on rapid switch).
    private func restoreAnchor(_ w: Window) {
        guard parkedAnchorWindows.contains(w.id),
              let orig = originalPositions[w.id] else { return }
        let pid = pid_t(w.pid)
        guard let ax = AXGeom.window(
                for: CGWindowID(w.id.serverID), pid: pid)
        else { return }
        AXGeom.setPosition(ax, orig)
        parkedAnchorWindows.remove(w.id)
        originalPositions[w.id] = nil
    }

    /// Apply the `minimize` hide method: AX `kAXMinimized = true`
    /// on every window of `oldActive`, `false` on every window of
    /// `newActive`. Goes to / comes from the Dock with the genie
    /// animation. Cleaner visually than `anchor` but slower —
    /// trade-off documented in config.toml's [workspace]
    /// hide_method block.
    private func applyMinimizeHide(oldActive: Int, newActive: Int) {
        let live = enumerateCGWindows()
        let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        var parked = 0, restored = 0
        for (wid, ws) in windowMap where ws == oldActive {
            if let w = byID[wid] {
                parkMinimize(w)
                parked += 1
            }
        }
        for (wid, ws) in windowMap where ws == newActive {
            if let w = byID[wid] {
                restoreMinimize(w)
                restored += 1
            }
        }
        Log.debug("native: minimize parked=\(parked) restored=\(restored)")
    }

    /// Minimize via AX. macOS remembers the un-minimized rect, so
    /// we don't need a `originalPositions`-equivalent here.
    private func parkMinimize(_ w: Window) {
        guard !parkedMinimizedWindows.contains(w.id) else { return }
        let pid = pid_t(w.pid)
        guard let ax = AXGeom.window(
                for: CGWindowID(w.id.serverID), pid: pid)
        else { return }
        AXUIElementSetAttributeValue(
            ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        parkedMinimizedWindows.insert(w.id)
    }

    private func restoreMinimize(_ w: Window) {
        guard parkedMinimizedWindows.contains(w.id) else { return }
        let pid = pid_t(w.pid)
        guard let ax = AXGeom.window(
                for: CGWindowID(w.id.serverID), pid: pid)
        else { return }
        AXUIElementSetAttributeValue(
            ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        parkedMinimizedWindows.remove(w.id)
    }

    // AX helpers (window lookup, position / size, display match)
    // now live in FacetAccessibility.AXGeom / .Displays — both
    // adapters share the same code path.
}
