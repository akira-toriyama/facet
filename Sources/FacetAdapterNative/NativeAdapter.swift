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
    /// at the moment of park so the matching `restoreWindow` puts
    /// it back exactly. macOS-side window-state shenanigans (user
    /// drag while parked, etc.) would lose accuracy here — Phase β
    /// proper will cache `axSize` too so we can offer a sanity
    /// "if size changed, leave at park position" branch.
    private var originalPositions: [WindowID: CGPoint] = [:]

    /// Windows currently parked at the bottom-right sliver.
    /// `parkWindow` early-exits when a window is already in this
    /// set so a poll-driven refresh can't re-park-on-top-of-park.
    private var parkedWindows: Set<WindowID> = []

    /// Held so `refreshCatalog` can read the configured workspace
    /// list each tick (handles config hot-reload once the
    /// Controller starts piping it through, future PR).
    private let config: FacetConfig

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
        let live = enumerateCGWindows()
        let liveIDs = Set(live.map(\.id))

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
        // Phase α: NSWorkspace.frontmostApplication → AX focused
        // window → private `_AXUIElementGetWindow` (already used in
        // `FacetAdapterRift/AXFocus.swift`, moves to a shared
        // `FacetAccessibility` module at Phase α impl time).
        nil
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

        // Apply hide / show side-effects via the configured method.
        // Today only `"anchor"` is wired; `"minimize"` lands in the
        // next slice (Phase β-2) and any future deep-core methods
        // come with `facet-x` (M6+).
        switch config.effectiveHideMethod {
        case "anchor":
            applyAnchorHide(oldActive: oldActive, newActive: target)
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
        windowMap[id] = target
        // Hide / show side-effect for this single window.
        if config.effectiveHideMethod == "anchor",
           let w = enumerateCGWindows().first(where: { $0.id == id }) {
            if target == activeIndex {
                restoreWindow(w)
            } else {
                parkWindow(w)
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
        for (wid, ws) in windowMap where ws == oldActive {
            if let w = byID[wid] { parkWindow(w) }
        }
        for (wid, ws) in windowMap where ws == newActive {
            if let w = byID[wid] { restoreWindow(w) }
        }
    }

    /// Move `w` to a 1×41 px sliver in the bottom-right corner of
    /// the display it currently sits on. macOS's clamp guarantees
    /// 41 px of title-bar stays on-screen (memory:
    /// native-window-hide-methods), so we can't fully hide via
    /// public APIs — anchor minimises the visible footprint while
    /// keeping the window recoverable from Mission Control if
    /// facet crashes (memory: facet-buddha-palm-principle).
    private func parkWindow(_ w: Window) {
        guard !parkedWindows.contains(w.id) else { return }
        let pid = pid_t(w.pid)
        guard
            let ax = axWindow(for: CGWindowID(w.id.serverID), pid: pid),
            let pos = axPosition(ax),
            let size = axSize(ax)
        else { return }
        originalPositions[w.id] = pos
        let center = CGPoint(x: pos.x + size.width / 2,
                             y: pos.y + size.height / 2)
        let screen = displayContaining(center)
        let hidden = CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
        _ = axSetPosition(ax, hidden)
        parkedWindows.insert(w.id)
    }

    /// Reverse of `parkWindow`: place the window back at its
    /// pre-park position. No-ops when the window isn't currently
    /// parked (defensive against double-restore on rapid switch).
    private func restoreWindow(_ w: Window) {
        guard parkedWindows.contains(w.id),
              let orig = originalPositions[w.id] else { return }
        let pid = pid_t(w.pid)
        guard let ax = axWindow(for: CGWindowID(w.id.serverID), pid: pid)
        else { return }
        _ = axSetPosition(ax, orig)
        parkedWindows.remove(w.id)
        originalPositions[w.id] = nil
    }

    // MARK: - AX helpers (Phase β preview)
    //
    // Lifted verbatim from sandbox/native-spike. MOVE-AT-M5: these
    // belong in a shared FacetAccessibility module alongside
    // FacetAdapterRift/AXFocus.swift once the second consumer
    // (the lifted helpers' first caller) makes the duplication
    // visible. Today this is the second consumer — extraction is
    // the next refactor opportunity.

    private func axWindow(for cgID: CGWindowID, pid: pid_t)
        -> AXUIElement?
    {
        let app = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                app, kAXWindowsAttribute as CFString, &winsRef
            ) == .success,
            let wins = winsRef as? [AXUIElement]
        else { return nil }
        return wins.first { cgWindowID(of: $0) == cgID }
    }

    private func axPosition(_ win: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                win, kAXPositionAttribute as CFString, &ref
              ) == .success else { return nil }
        var pt = CGPoint.zero
        AXValueGetValue(ref as! AXValue, .cgPoint, &pt)
        return pt
    }

    private func axSetPosition(_ win: AXUIElement, _ pt: CGPoint) -> Bool {
        var p = pt
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(
            win, kAXPositionAttribute as CFString, v) == .success
    }

    private func axSize(_ win: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                win, kAXSizeAttribute as CFString, &ref
              ) == .success else { return nil }
        var sz = CGSize.zero
        AXValueGetValue(ref as! AXValue, .cgSize, &sz)
        return sz
    }

    /// Pick the display whose bounds contain `point`, or fall back
    /// to the nearest display by centre distance. Quartz coords
    /// (top-left origin) match AX position / size.
    private func displayContaining(_ point: CGPoint) -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let screens = ids.map { CGDisplayBounds($0) }
        if let hit = screens.first(where: { $0.contains(point) }) {
            return hit
        }
        return screens.min(by: {
            hypot($0.midX - point.x, $0.midY - point.y) <
            hypot($1.midX - point.x, $1.midY - point.y)
        }) ?? CGDisplayBounds(CGMainDisplayID())
    }
}

// Private API: `_AXUIElementGetWindow` translates an `AXUIElement`
// to its CGWindowID. Looked up via `dlsym` so we don't link
// against the private symbol at build time. Mirrors the binding
// in FacetAdapterRift/AXFocus.swift; MOVE-AT-M5 to a shared
// FacetAccessibility module.
private let axGetWindow: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError)? = {
    guard let h = dlopen(nil, RTLD_NOW),
          let p = dlsym(h, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(p, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
}()

private func cgWindowID(of ax: AXUIElement) -> CGWindowID? {
    guard let fn = axGetWindow else { return nil }
    var wid: CGWindowID = 0
    return fn(ax, &wid) == .success ? wid : nil
}
