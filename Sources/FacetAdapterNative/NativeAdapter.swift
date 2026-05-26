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
    /// asks the catalog to reconcile against the live ID set, and
    /// builds the `[Workspace]` snapshot through the catalog.
    private func refreshCatalog() {
        let live = enumerateCGWindows()
        let liveIDs = Set(live.map(\.id))
        let result = catalog.reconcile(liveIDs: liveIDs)
        if result.added > 0 || result.removed > 0 {
            Log.debug("native: refreshCatalog "
                + "added=\(result.added) removed=\(result.removed) "
                + "total=\(live.count)")
        }
        let focused = focusedWindow()
        workspaceList = catalog.snapshot(
            live: live,
            focused: focused,
            configured: config.effectiveWorkspaceList,
            layoutMode: "bsp")
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

        // Apply hide / show side-effects via the configured method.
        let live = enumerateCGWindows()
        let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        var parked = 0, restored = 0
        switch config.effectiveHideMethod {
        case "anchor":
            for id in plan.toPark {
                if let w = byID[id] { parkAnchor(w); parked += 1 }
            }
            for id in plan.toRestore {
                if let w = byID[id] { restoreAnchor(w); restored += 1 }
            }
            Log.debug("native: anchor parked=\(parked) restored=\(restored)")
        case "minimize":
            for id in plan.toPark {
                if let w = byID[id] { parkMinimize(w); parked += 1 }
            }
            for id in plan.toRestore {
                if let w = byID[id] { restoreMinimize(w); restored += 1 }
            }
            Log.debug("native: minimize parked=\(parked) restored=\(restored)")
        default:
            break
        }
        eventContinuation.yield(.refreshNeeded)
    }

    public func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        let target = index + 1
        let configured = config.effectiveWorkspaceList.map(\.index)
        let outcome = catalog.moveWindow(id, to: target,
                                         configuredIndexes: configured)
        guard outcome != .rejected else { return }
        Log.debug("native: moveWindow \(id.serverID) -> WS \(target) "
            + "outcome=\(outcome)")
        // Hide / show side-effect for this single window.
        if let w = enumerateCGWindows().first(where: { $0.id == id }) {
            switch (config.effectiveHideMethod, outcome) {
            case ("anchor", .park):    parkAnchor(w)
            case ("anchor", .restore): restoreAnchor(w)
            case ("minimize", .park):    parkMinimize(w)
            case ("minimize", .restore): restoreMinimize(w)
            default: break
            }
        }
        eventContinuation.yield(.refreshNeeded)
    }

    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        // Phase γ.
    }

    public func closeWindow(_ id: WindowID) {
        // Look up pid via the live CGWindowList (we don't cache
        // pid in catalog.windowMap — keeping the map narrow). Few-ms
        // cost, close is rare enough that this is acceptable.
        guard let w = enumerateCGWindows()
                .first(where: { $0.id == id }) else {
            Log.debug("native: closeWindow \(id.serverID) "
                + "— not in live catalog")
            return
        }
        let pid = pid_t(w.pid)
        guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID), pid: pid) else {
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
        // Phase γ.
    }

    public func windowMenu(mode: String, floating: Bool) -> [WindowMenuItem] {
        // Phase γ adds the layout-mode-specific items (toggle stack /
        // promote to master / etc). Close stays applicable across
        // every layout mode so it's safe to land today; without it
        // the right-click menu would be empty and the user couldn't
        // reach `closeWindow` from the tree view.
        [WindowMenuItem("Close window", [], close: true)]
    }

    // MARK: - Anchor hide / show (AX side-effects)

    /// Move `w` to a 1×41 px sliver in the bottom-right corner of
    /// the display it currently sits on. macOS's clamp guarantees
    /// 41 px of title-bar stays on-screen (memory:
    /// native-window-hide-methods), so we can't fully hide via
    /// public APIs — anchor minimises the visible footprint while
    /// keeping the window recoverable from Mission Control if
    /// facet crashes (memory: facet-buddha-palm-principle).
    private func parkAnchor(_ w: Window) {
        guard catalog.shouldParkAnchor(w.id) else { return }
        let pid = pid_t(w.pid)
        guard
            let ax = AXGeom.window(for: CGWindowID(w.id.serverID), pid: pid),
            let pos = AXGeom.position(ax),
            let size = AXGeom.size(ax)
        else { return }
        let center = CGPoint(x: pos.x + size.width / 2,
                             y: pos.y + size.height / 2)
        let screen = Displays.containing(center)
        let hidden = CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
        AXGeom.setPosition(ax, hidden)
        catalog.markAnchorParked(w.id, originalPosition: pos)
    }

    /// Reverse of `parkAnchor`: place the window back at its
    /// pre-park position. No-ops when the window isn't currently
    /// parked (defensive against double-restore on rapid switch).
    private func restoreAnchor(_ w: Window) {
        guard let orig = catalog.consumeAnchorRestore(w.id) else { return }
        let pid = pid_t(w.pid)
        guard let ax = AXGeom.window(
                for: CGWindowID(w.id.serverID), pid: pid)
        else { return }
        AXGeom.setPosition(ax, orig)
    }

    // MARK: - Minimize hide / show (AX side-effects)

    /// Minimize via AX. macOS remembers the un-minimized rect, so
    /// no equivalent of `originalPositions` is needed here.
    private func parkMinimize(_ w: Window) {
        guard catalog.shouldMinimize(w.id) else { return }
        let pid = pid_t(w.pid)
        guard let ax = AXGeom.window(
                for: CGWindowID(w.id.serverID), pid: pid)
        else { return }
        AXUIElementSetAttributeValue(
            ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        catalog.markMinimized(w.id)
    }

    private func restoreMinimize(_ w: Window) {
        guard catalog.shouldUnminimize(w.id) else { return }
        let pid = pid_t(w.pid)
        guard let ax = AXGeom.window(
                for: CGWindowID(w.id.serverID), pid: pid)
        else { return }
        AXUIElementSetAttributeValue(
            ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        catalog.markUnminimized(w.id)
    }

    // AX helpers (window lookup, position / size, display match)
    // live in FacetAccessibility.AXGeom / .Displays — both adapters
    // share the same code path.
}
