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
// State lives in `WorkspaceCatalog` (pure value type, AX-free,
// unit-testable). This file owns only the effects: CGWindowList
// enumeration, AX focus / position / minimize / close, AX event
// subscription wiring, and the AsyncStream plumbing for events
// and errors.

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

    // MARK: - State (delegated to catalog)

    /// Self-managed workspace state. All mutations go through here
    /// so the state machine stays pure and testable; this file
    /// only applies the AX side-effects the catalog hands back.
    private var catalog = WorkspaceCatalog()

    /// Snapshot of the last `workspaces()` build, returned as-is on
    /// the next call. Rebuilt every `refreshCatalog()` invocation.
    private var workspaceList: [Workspace] = []

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
        if let msg = AXPermission.errorMessageIfMissing() {
            DispatchQueue.main.async { [errorContinuation] in
                errorContinuation.yield(msg)
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

    // MARK: - Queries

    public func workspaces() -> [Workspace] {
        refreshCatalog()
        return workspaceList
    }

    /// Refresh the cached snapshot. Re-enumerates CGWindowList,
    /// asks the catalog to reconcile against the live list (which
    /// also records each window's owning pid for later AX calls
    /// and threads new windows into the BSP tree of the active
    /// WS when that WS is in `"bsp"` mode), and builds the
    /// `[Workspace]` snapshot through the catalog.
    ///
    /// Lazy retile (Phase γ frozen): if `reconcile` added or
    /// removed any window AND the active WS is in `"bsp"` mode,
    /// re-apply tile frames so the on-screen layout matches the
    /// new tree. Pure UI / mode flips don't trigger AX writes
    /// here — they go through `switchWorkspace` /
    /// `setLayoutMode` / `perform`.
    private func refreshCatalog() {
        let live = enumerateCGWindows()
        let focused = focusedWindow()
        let rect = activeDisplayRect()
        let result = catalog.reconcile(live: live,
                                       focused: focused,
                                       activeRect: rect)
        if result.added > 0 || result.removed > 0 {
            Log.debug("native: refreshCatalog "
                + "added=\(result.added) removed=\(result.removed) "
                + "total=\(live.count)")
            if catalog.mode(of: catalog.activeIndex) == "bsp" {
                applyTile(workspace: catalog.activeIndex,
                          rect: rect)
            }
        }
        workspaceList = catalog.snapshot(
            live: live,
            focused: focused,
            configured: config.effectiveWorkspaceList)
    }

    /// Visible rect (display bounds minus menu bar / Dock) of
    /// the display the focused window currently sits on. Falls
    /// back to the main display when nothing is focused — keeps
    /// tile math meaningful even at startup.
    private func activeDisplayRect() -> CGRect {
        let probe: CGPoint
        if let id = focusedWindow(),
           let pid = catalog.pid(for: id),
           let ax = AXGeom.window(for: CGWindowID(id.serverID),
                                  pid: pid_t(pid)),
           let pos = AXGeom.position(ax),
           let size = AXGeom.size(ax) {
            probe = CGPoint(x: pos.x + size.width / 2,
                            y: pos.y + size.height / 2)
        } else {
            probe = .zero
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                Displays.visibleFrame(containing: probe)
            }
        }
        return Displays.containing(probe)
    }

    /// Enumerate visible windows via the public CGWindowList API.
    /// Skips:
    ///   - facet's own process (avoid managing our own panel)
    ///   - Window Server scaffolding (StatusIndicator etc.)
    ///   - the `borders` companion app (decorative outlines, AX
    ///     element returns nil so we couldn't operate on them
    ///     anyway)
    /// `isFocused` is stamped by `WorkspaceCatalog.snapshot` against
    /// the focused-window query, so this helper stays a pure
    /// CGWindowList adapter with no AX dependency.
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
                isFocused: false,
                isFloating: false,
                frame: frame)
        }
    }

    public func focusedWindow() -> WindowID? {
        // Frontmost-app → AX focused-window → CGWindowID is the
        // same dance the rift adapter would need; lives in
        // `AX.frontmostFocusedCGID` so the adapters share it.
        guard let cgID = AX.frontmostFocusedCGID() else { return nil }
        return WindowID(serverID: Int(cgID))
    }

    // MARK: - Commands

    public func switchWorkspace(toIndex index: Int) {
        // Backend protocol convention is 0-based; catalog (matching
        // the user-facing CLI) is 1-based. Translate at the seam.
        let target = index + 1
        let configured = config.effectiveWorkspaceList.map(\.index)
        guard let plan = catalog.setActive(target,
                                           configuredIndexes: configured)
        else { return }
        Log.debug("native: switchWorkspace \(plan.oldActive) -> "
            + "\(plan.newActive) (hide_method="
            + "\(config.effectiveHideMethod))")
        applyHide(toPark: plan.toPark, toRestore: plan.toRestore)
        // Phase γ: if the newly-active WS is in `"bsp"` mode,
        // overlay tree-computed frames on top of the per-mode
        // restore. Floating windows in the same WS keep the
        // restoreAnchor / restoreMinimize position; tiled
        // windows snap to their tree slot.
        if catalog.mode(of: plan.newActive) == "bsp" {
            applyTile(workspace: plan.newActive,
                      rect: activeDisplayRect())
        }
        eventContinuation.yield(.refreshNeeded)
    }

    public func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        let target = index + 1
        let configured = config.effectiveWorkspaceList.map(\.index)
        let rect = activeDisplayRect()
        let outcome = catalog.moveWindow(id, to: target,
                                         configuredIndexes: configured,
                                         in: rect)
        switch outcome {
        case .rejected:
            return
        case .stateOnly:
            Log.debug("native: moveWindow \(id.serverID) -> WS "
                + "\(target) outcome=stateOnly")
        case .park(let ref):
            Log.debug("native: moveWindow \(id.serverID) -> WS "
                + "\(target) outcome=park")
            applyHide(toPark: [ref], toRestore: [])
        case .restore(let ref):
            Log.debug("native: moveWindow \(id.serverID) -> WS "
                + "\(target) outcome=restore")
            applyHide(toPark: [], toRestore: [ref])
        }
        // Tree changed for source AND/OR destination — both need
        // a retile if they're in bsp mode and currently active.
        // Inactive WSs get re-tiled on their next switchWorkspace
        // (Phase γ: lazy retile).
        if catalog.mode(of: catalog.activeIndex) == "bsp" {
            applyTile(workspace: catalog.activeIndex, rect: rect)
        }
        eventContinuation.yield(.refreshNeeded)
    }

    /// Apply the configured hide method to two `WindowRef` lists.
    /// Centralises the anchor / minimize branch so callers (workspace
    /// switch, single-window move) don't repeat the switch. Unknown
    /// `hide_method` values silently no-op — matches the
    /// FacetConfig clamping rule that any out-of-set value falls
    /// back to the default at config-read time.
    private func applyHide(toPark: [WindowRef],
                           toRestore: [WindowRef]) {
        let method = config.effectiveHideMethod
        let park: (WindowRef) -> Void
        let restore: (WindowRef) -> Void
        switch method {
        case "anchor":
            park = parkAnchor(_:); restore = restoreAnchor(_:)
        case "minimize":
            park = parkMinimize(_:); restore = restoreMinimize(_:)
        default:
            return
        }
        for ref in toPark { park(ref) }
        for ref in toRestore { restore(ref) }
        if !toPark.isEmpty || !toRestore.isEmpty {
            Log.debug("native: \(method) "
                + "parked=\(toPark.count) restored=\(toRestore.count)")
        }
    }

    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        let target = index + 1
        let rect = activeDisplayRect()
        let applied = catalog.setMode(workspace: target,
                                      to: mode, in: rect)
        Log.debug("native: setLayoutMode WS \(target) -> \(applied)")
        // Re-tile only when the affected WS is currently active —
        // inactive WSs catch up on next switchWorkspace (Phase γ
        // lazy retile rule).
        if target == catalog.activeIndex, applied == "bsp" {
            applyTile(workspace: target, rect: rect)
        }
        eventContinuation.yield(.refreshNeeded)
    }

    /// `WindowBackend.retileActiveWorkspace` implementation:
    /// recompute + reapply the active workspace's BSP tree.
    /// No-op when the active WS isn't in bsp mode. Useful when an
    /// external resize or a drift from facet's view of the world
    /// needs a manual fix (`facet --retile`).
    public func retileActiveWorkspace() {
        let rect = activeDisplayRect()
        guard catalog.mode(of: catalog.activeIndex) == "bsp"
        else {
            Log.debug("native: retile noop "
                + "(WS \(catalog.activeIndex) not bsp)")
            return
        }
        applyTile(workspace: catalog.activeIndex, rect: rect)
        eventContinuation.yield(.refreshNeeded)
    }

    /// Iterate the WS's tree-computed frames and push each one
    /// through AX. Floating windows are skipped (they're not in
    /// the tree). No-op when the WS has no tree.
    private func applyTile(workspace n1Based: Int, rect: CGRect) {
        let frames = catalog.tiledFrames(for: n1Based, in: rect)
        guard !frames.isEmpty else { return }
        var applied = 0
        for (id, frame) in frames {
            guard let pid = catalog.pid(for: id) else { continue }
            guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID),
                pid: pid_t(pid)) else { continue }
            AXGeom.setPosition(ax, frame.origin)
            AXGeom.setSize(ax, frame.size)
            applied += 1
        }
        Log.debug("native: tile WS \(n1Based) "
            + "frames=\(frames.count) applied=\(applied) "
            + "rect=\(rect)")
    }

    public func closeWindow(_ id: WindowID) {
        // pid comes from `catalog.windowMap[id]` — recorded at
        // reconcile time, so no fresh CGWindowList sweep is needed.
        // Misses only if the window was never reconciled (e.g.
        // closeWindow racing a brand-new window before refresh).
        guard let pid = catalog.pid(for: id) else {
            Log.debug("native: closeWindow \(id.serverID) "
                + "— not in catalog")
            return
        }
        guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID), pid: pid_t(pid)) else {
            Log.debug("native: closeWindow \(id.serverID) — no AX")
            return
        }
        let pressed = AXGeom.closeButton(ax)
        Log.debug("native: closeWindow \(id.serverID) "
            + "pressed=\(pressed)")
        // Best-effort eviction from catalog — the next event /
        // poll reconcile will fix it anyway if the app intercepted
        // (e.g. unsaved-changes dialog) and the window survives.
        if pressed { catalog.drop(id) }
        eventContinuation.yield(.refreshNeeded)
    }

    public func perform(_ action: WindowAction) {
        // Phase γ.1 wires the two BSP-relevant actions:
        //   - toggleFloat: flip the focused window's float flag;
        //     non-floating ↔ tile-tree membership shifts in the
        //     catalog. Re-tile the active WS if it's bsp.
        //   - toggleOrientation: rotate the focused window's
        //     parent split (no-op when the WS is not bsp). Then
        //     re-tile so the new orientation lands on AX.
        // master_stack / scrolling / cycleStack actions are γ.2+;
        // they no-op here.
        guard let id = focusedWindow() else { return }
        let rect = activeDisplayRect()
        switch action {
        case .toggleFloat:
            catalog.toggleFloat(id, focused: id, in: rect)
            Log.debug("native: perform toggleFloat "
                + "\(id.serverID) → "
                + "isFloating=\(catalog.isFloating(id))")
            if catalog.mode(of: catalog.activeIndex) == "bsp" {
                applyTile(workspace: catalog.activeIndex,
                          rect: rect)
            }
            eventContinuation.yield(.refreshNeeded)
        case .toggleOrientation:
            catalog.toggleOrientation(of: id)
            Log.debug("native: perform toggleOrientation "
                + "\(id.serverID)")
            if catalog.mode(of: catalog.activeIndex) == "bsp" {
                applyTile(workspace: catalog.activeIndex,
                          rect: rect)
            }
            eventContinuation.yield(.refreshNeeded)
        default:
            // toggleFullscreen / promoteToMaster / swapMasterStack /
            // toggleStack / centerColumn / snapStrip — out of γ.1
            // scope. No-op rather than no-op-with-error, since the
            // menu builder hides these from the user; we only
            // reach this case if a script invokes them directly.
            break
        }
    }

    public func windowMenu(mode: String, floating: Bool) -> [WindowMenuItem] {
        // γ.1 surfaces toggleFloat (always applicable) and
        // toggleOrientation (bsp only). Stack-mode items
        // (cycleStack, promoteToMaster) come with γ.2+.
        var items: [WindowMenuItem] = []
        if mode == "bsp", !floating {
            items.append(.init("Toggle orientation",
                               [.toggleOrientation]))
        }
        items.append(.init(floating ? "Unfloat" : "Float",
                           [.toggleFloat]))
        items.append(.init("Close window", [], close: true))
        return items
    }

    // MARK: - Anchor hide / show (AX side-effects)

    /// Move the window to a 1×41 px sliver in the bottom-right
    /// corner of the display it currently sits on. macOS's clamp
    /// guarantees 41 px of title-bar stays on-screen (memory:
    /// native-window-hide-methods), so we can't fully hide via
    /// public APIs — anchor minimises the visible footprint while
    /// keeping the window recoverable from Mission Control if
    /// facet crashes (memory: facet-buddha-palm-principle).
    private func parkAnchor(_ ref: WindowRef) {
        guard catalog.shouldParkAnchor(ref.id) else { return }
        guard
            let ax = AXGeom.window(for: CGWindowID(ref.id.serverID),
                                   pid: pid_t(ref.pid)),
            let pos = AXGeom.position(ax),
            let size = AXGeom.size(ax)
        else { return }
        let center = CGPoint(x: pos.x + size.width / 2,
                             y: pos.y + size.height / 2)
        let screen = Displays.containing(center)
        let hidden = CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
        AXGeom.setPosition(ax, hidden)
        catalog.markAnchorParked(ref.id, originalPosition: pos)
    }

    /// Reverse of `parkAnchor`: place the window back at its
    /// pre-park position. No-ops when the window isn't currently
    /// parked (defensive against double-restore on rapid switch).
    private func restoreAnchor(_ ref: WindowRef) {
        guard let orig = catalog.consumeAnchorRestore(ref.id) else { return }
        guard let ax = AXGeom.window(
                for: CGWindowID(ref.id.serverID), pid: pid_t(ref.pid))
        else { return }
        AXGeom.setPosition(ax, orig)
    }

    // MARK: - Minimize hide / show (AX side-effects)

    /// Minimize via AX. macOS remembers the un-minimized rect, so
    /// no equivalent of `originalPositions` is needed here.
    private func parkMinimize(_ ref: WindowRef) {
        guard catalog.shouldMinimize(ref.id) else { return }
        guard let ax = AXGeom.window(
                for: CGWindowID(ref.id.serverID), pid: pid_t(ref.pid))
        else { return }
        AXUIElementSetAttributeValue(
            ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        catalog.markMinimized(ref.id)
    }

    private func restoreMinimize(_ ref: WindowRef) {
        guard catalog.shouldUnminimize(ref.id) else { return }
        guard let ax = AXGeom.window(
                for: CGWindowID(ref.id.serverID), pid: pid_t(ref.pid))
        else { return }
        AXUIElementSetAttributeValue(
            ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        catalog.markUnminimized(ref.id)
    }

    // AX helpers (window lookup, position / size, display match)
    // live in FacetAccessibility.AXGeom / .Displays — both adapters
    // share the same code path.
}
