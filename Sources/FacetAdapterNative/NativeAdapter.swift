// `WindowBackend` conformance using only AX + public macOS APIs
// (no `rift-cli`, no SLS, no SIP-off injection). This file is the
// seam between facet and the OS for the native backend.
//
// Phase progression (memory: facet-architecture-decisions):
//   α (shipped) — virtual workspace state self-managed; focus
//   β (shipped) — window move across workspaces; off-screen
//                 park/unpark (`anchor` + `minimize` hide methods,
//                 memory: native-window-hide-methods)
//   γ (shipped) — tiling layout engines (BSP + stack, AX-role
//                 auto-float). Frozen 2026-05-26, memory:
//                 facet-phase-gamma-decisions.
//   δ (pending) — display reconfigure handling, geometry persistence
//   ε (pending) — `FacetAdapterRift` deprecation
//
// State lives in `WorkspaceCatalog` (pure value type, AX-free,
// unit-testable). This file owns only the effects: CGWindowList
// enumeration, AX focus / position / minimize / close, AX event
// subscription wiring, tile / stack frame application, and the
// AsyncStream plumbing for events and errors.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

public final class NativeAdapter: WindowBackend, @unchecked Sendable {
    public let name = "native"

    /// Phase γ frozen layout-mode set. `float` is the per-WS
    /// default but isn't advertised here because it isn't a
    /// *user-pickable mode* in the menu sense — it's the
    /// "no tiling applied" baseline. master_stack / scrolling /
    /// traditional are explicitly out of γ scope (memory:
    /// facet-phase-gamma-decisions Q1).
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
    /// list each tick. Note: this captures the config at adapter
    /// init time; `Controller.reloadConfig()` re-reads
    /// `config.toml` but does NOT push the fresh value back to
    /// the adapter, so `[workspace]` table edits during a session
    /// take effect only on restart. Wiring a config-push channel
    /// is a known follow-up.
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
        // Phase γ.3: probe AX role for every live ID that the
        // catalog hasn't seen yet — sheets / dialogs / floating
        // panels auto-float on first sight so they don't fight
        // the tiler.
        let autoFloat = detectAutoFloating(live: live)
        let result = catalog.reconcile(live: live,
                                       focused: focused,
                                       activeRect: rect,
                                       autoFloat: autoFloat)
        if result.added > 0 || result.removed > 0 {
            Log.debug("native: refreshCatalog "
                + "added=\(result.added) removed=\(result.removed) "
                + "total=\(live.count)")
            applyLayout(workspace: catalog.activeIndex, rect: rect)
        }
        workspaceList = catalog.snapshot(
            live: live,
            focused: focused,
            configured: config.effectiveWorkspaceList)
    }

    /// Cap on `detectAutoFloating`'s per-refresh AX probes. The
    /// role check costs ~3 AX round-trips per window (window
    /// lookup + role + subrole), and each round-trip has a
    /// default 6s timeout — a 100-window startup with one busy
    /// app could otherwise stall reconcile for minutes. Beyond
    /// the cap, new windows simply enter the tiler without the
    /// auto-float hint; the user can `--toggle-float` them
    /// manually. Tuned so a normal session start (≤16 new
    /// windows per refresh tick) is fully covered.
    private let maxAutoFloatProbes = 16

    /// Phase γ.3: which live windows should default to floating
    /// (sheet / dialog / palette). Only checks windows the
    /// catalog hasn't seen yet — known windows keep whatever
    /// `floatingWindows` state the user has set (toggleFloat
    /// must remain authoritative once they've explicitly chosen).
    /// Capped at `maxAutoFloatProbes` AX queries per call so a
    /// busy startup can't burn an unbounded number of AX
    /// round-trips on the foreground reconcile.
    private func detectAutoFloating(live: [Window]) -> Set<WindowID> {
        var out: Set<WindowID> = []
        var probed = 0
        for w in live where catalog.windowMap[w.id] == nil {
            if probed >= maxAutoFloatProbes {
                Log.debug("native: auto-float probe cap "
                    + "(\(maxAutoFloatProbes)) hit — "
                    + "remaining new windows skip role check")
                break
            }
            probed += 1
            guard let ax = AXGeom.window(
                for: CGWindowID(w.id.serverID),
                pid: pid_t(w.pid)) else { continue }
            if AXGeom.isFloatingByRole(ax) {
                out.insert(w.id)
                Log.debug("native: auto-float wsid=\(w.id.serverID) "
                    + "app=\(w.appName)")
            }
        }
        return out
    }

    /// Display rect to anchor tile / stack math against.
    /// Determined by the focused window's centre point (or the
    /// origin when nothing is focused — startup, mid-switch).
    ///
    /// Two branches with intentionally different rect semantics:
    ///
    ///   - **Main thread** (the normal path — `refreshCatalog` /
    ///     `applyLayout` callers all run on main via the
    ///     Controller's `MainActor`-isolated `requestRefresh` /
    ///     poll timer): returns `Displays.visibleFrame` (full
    ///     display *minus menu bar / Dock*), the correct rect
    ///     for tile geometry. `visibleFrame` is `@MainActor`
    ///     because it talks to `NSScreen`.
    ///
    ///   - **Off-main** (defensive — facet doesn't currently
    ///     call this path, but `WindowBackend.workspaces()` has
    ///     no MainActor contract, so a future caller from a
    ///     background task wouldn't crash): returns
    ///     `Displays.containing` (full display *including* menu
    ///     bar / Dock). Tiled windows would briefly cover those
    ///     regions but `applyLayout` is idempotent, so the next
    ///     main-thread tick re-tiles against the right rect.
    ///     If we ever observe this branch firing in production,
    ///     `MainActor.assumeIsolated` + a contract requirement
    ///     is the upgrade path (would crash callers instead of
    ///     silently degrading geometry).
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
        Log.debug("native: activeDisplayRect off-main — "
            + "using full display bounds (no visibleFrame)")
        return Displays.containing(probe)
    }

    /// Enumerate visible windows via the public CGWindowList API.
    /// Skips:
    ///   - facet's own process (avoid managing our own panel)
    ///   - non-normal `kCGWindowLayer` values — wallpapers
    ///     (negative), floating panels / Dock / menu-bar /
    ///     status overlays (positive), and any third-party
    ///     overlay tool (e.g. wand / Übersicht / Sketchybar
    ///     custom panels). User app windows live at layer 0;
    ///     anything else is structural OS chrome or a tool
    ///     that won't play nicely with tiling. Auto-detected
    ///     rather than hard-coded so new overlay tools don't
    ///     require a code change.
    ///   - explicit app-name guards for `Window Server` and
    ///     `borders` — both happen to ALSO fall outside layer 0
    ///     (Window Server is huge int, borders draws decoration
    ///     overlays via a child window-server process), but the
    ///     name guard is belt-and-braces against an OS change
    ///     that ever floats them onto layer 0.
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
            // Normal user windows live at layer 0. Everything
            // else (wallpaper, status overlays, third-party
            // chrome) gets skipped automatically.
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { return nil }
            let owner = dict[kCGWindowOwnerName as String]
                as? String ?? ""
            // Belt-and-braces: even if either of these ever
            // shows up at layer 0, we still don't want to manage
            // them.
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
        // Phase γ: overlay layout-specific frames on top of the
        // per-mode hide_method restore. Floating windows in the
        // same WS keep the restoreAnchor / restoreMinimize
        // position; tiled / stacked windows snap to their
        // computed frame.
        applyLayout(workspace: plan.newActive,
                    rect: activeDisplayRect())
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
        // Layout changed for source AND/OR destination — re-apply
        // the active WS if its mode produces an on-screen layout.
        // Inactive WSs catch up on their next switchWorkspace
        // (Phase γ: lazy retile / re-stack).
        applyLayout(workspace: catalog.activeIndex, rect: rect)
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
        // BSP → Stack migration uses the hide_method to park all
        // but the focused window. To respect that flow, call the
        // hide_method's park helper for departing tiled members
        // BEFORE catalog state flips — but the catalog's setMode
        // already discards layoutTrees / stackOrders entries, so
        // we instead rely on applyStack post-flip to park
        // non-top members. Symmetric for Stack → BSP.
        let applied = catalog.setMode(workspace: target,
                                      to: mode, in: rect)
        Log.debug("native: setLayoutMode WS \(target) -> \(applied)")
        if target == catalog.activeIndex {
            applyLayout(workspace: target, rect: rect)
        }
        eventContinuation.yield(.refreshNeeded)
    }

    /// `WindowBackend.retileActiveWorkspace` implementation:
    /// recompute + reapply the active workspace's layout. For
    /// BSP this re-tiles the tree; for stack this re-stacks
    /// (top fills, others park). No-op for float mode.
    public func retileActiveWorkspace() {
        let mode = catalog.mode(of: catalog.activeIndex)
        guard mode == "bsp" || mode == "stack" else {
            Log.debug("native: retile noop "
                + "(WS \(catalog.activeIndex) is \(mode))")
            return
        }
        applyLayout(workspace: catalog.activeIndex,
                    rect: activeDisplayRect())
        eventContinuation.yield(.refreshNeeded)
    }

    /// Apply stack mode to `n1Based`: the catalog's
    /// `stackOrder[0]` fills `rect` (un-parked from whichever
    /// hide_method last held it), all other members are parked
    /// via the configured hide_method. Floating windows are
    /// excluded entirely (they live outside the stack). No-op
    /// when the WS isn't in stack mode or has no members.
    private func applyStack(workspace n1Based: Int, rect: CGRect) {
        let order = catalog.stackOrder(of: n1Based)
        guard let top = order.first else { return }
        // Top: force visible, full rect. Bypass the regular
        // restore flow (which would use the recorded
        // originalPosition); the stack contract is that top
        // fills the display.
        if let pid = catalog.pid(for: top),
           let ax = AXGeom.window(for: CGWindowID(top.serverID),
                                  pid: pid_t(pid))
        {
            if config.effectiveHideMethod == "minimize" {
                AXUIElementSetAttributeValue(
                    ax, kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse)
            }
            AXGeom.setPosition(ax, rect.origin)
            AXGeom.setSize(ax, rect.size)
            catalog.clearParkedState(of: top)
        }
        // Others: park via hide_method (parkAnchor /
        // parkMinimize own the "skip if already parked" guard).
        for id in order.dropFirst() {
            guard let pid = catalog.pid(for: id) else { continue }
            let ref = WindowRef(id: id, pid: pid)
            switch config.effectiveHideMethod {
            case "anchor":   parkAnchor(ref)
            case "minimize": parkMinimize(ref)
            default:         break
            }
        }
        Log.debug("native: stack WS \(n1Based) "
            + "top=\(top.serverID) members=\(order.count) "
            + "rect=\(rect)")
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
        // Failures here all surface in the errors stream so
        // `facet status` lastError tells the user *why* the
        // right-click "Close window" appeared to do nothing —
        // a debug-log-only failure would be invisible.
        guard let pid = catalog.pid(for: id) else {
            let msg = "closeWindow \(id.serverID): not in catalog "
                + "(window may have just opened — try again)"
            Log.debug("native: \(msg)")
            errorContinuation.yield(msg)
            return
        }
        guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID), pid: pid_t(pid)) else {
            let msg = "closeWindow \(id.serverID): AX element "
                + "unavailable (app may have died, or has no AX)"
            Log.debug("native: \(msg)")
            errorContinuation.yield(msg)
            return
        }
        let pressed = AXGeom.closeButton(ax)
        Log.debug("native: closeWindow \(id.serverID) "
            + "pressed=\(pressed)")
        if !pressed {
            errorContinuation.yield(
                "closeWindow \(id.serverID): close button "
                + "missing or refused (app dialog intercepted?)")
        }
        // Best-effort eviction from catalog — the next event /
        // poll reconcile will fix it anyway if the app intercepted
        // (e.g. unsaved-changes dialog) and the window survives.
        if pressed { catalog.drop(id) }
        eventContinuation.yield(.refreshNeeded)
    }

    public func perform(_ action: WindowAction) {
        // BSP: toggleFloat, toggleOrientation. Stack:
        // cycleStackNext, cycleStackPrev. Everything else
        // (master_stack / scrolling / toggleStack /
        // toggleFullscreen) is out of Phase γ scope and no-ops.
        let rect = activeDisplayRect()
        switch action {
        case .toggleFloat:
            guard let id = focusedWindow() else { return }
            catalog.toggleFloat(id, focused: id, in: rect)
            Log.debug("native: perform toggleFloat "
                + "\(id.serverID) → "
                + "isFloating=\(catalog.isFloating(id))")
            applyLayout(workspace: catalog.activeIndex, rect: rect)
            eventContinuation.yield(.refreshNeeded)
        case .toggleOrientation:
            guard let id = focusedWindow() else { return }
            catalog.toggleOrientation(of: id)
            Log.debug("native: perform toggleOrientation "
                + "\(id.serverID)")
            applyLayout(workspace: catalog.activeIndex, rect: rect)
            eventContinuation.yield(.refreshNeeded)
        case .cycleStackNext, .cycleStackPrev:
            // Cycle is per-active-WS; no need for `focusedWindow`
            // — the catalog owns "who's the current top" via the
            // stack-order array, not via OS focus.
            let direction: WorkspaceCatalog.CycleDirection =
                action == .cycleStackNext ? .next : .prev
            let newTop = catalog.cycleStack(
                workspace: catalog.activeIndex,
                direction: direction)
            Log.debug("native: perform \(action) → newTop="
                + "\(newTop?.serverID.description ?? "nil")")
            if newTop != nil {
                applyStack(workspace: catalog.activeIndex,
                           rect: rect)
                eventContinuation.yield(.refreshNeeded)
            }
        // rift-only / out-of-γ-scope cases — no-op, but listed
        // explicitly so the compiler enforces a handling
        // decision on every future enum addition.
        case .toggleFullscreen,
             .promoteToMaster, .swapMasterStack,
             .toggleStack,
             .centerColumn, .snapStrip:
            break
        }
    }

    /// Apply the workspace's mode-specific layout (tile / stack /
    /// no-op). Single dispatch site — every callsite that mutates
    /// the catalog and might need to push fresh frames through AX
    /// (refresh / switch / move / setMode / retile / perform)
    /// funnels through here.
    private func applyLayout(workspace n1Based: Int, rect: CGRect) {
        switch catalog.mode(of: n1Based) {
        case "bsp":   applyTile(workspace: n1Based, rect: rect)
        case "stack": applyStack(workspace: n1Based, rect: rect)
        default:      break
        }
    }

    public func windowMenu(mode: String, floating: Bool) -> [WindowMenuItem] {
        // Menu items per layout mode (Phase γ): BSP non-floating
        // gets Toggle orientation; stack non-floating gets
        // cycle-next / cycle-prev; everyone gets Float/Unfloat
        // and Close. master_stack / scrolling actions stay out
        // of the menu (out of γ scope).
        var items: [WindowMenuItem] = []
        if mode == "bsp", !floating {
            items.append(.init("Toggle orientation",
                               [.toggleOrientation]))
        }
        if mode == "stack", !floating {
            items.append(.init("Next stack window",
                               [.cycleStackNext]))
            items.append(.init("Previous stack window",
                               [.cycleStackPrev]))
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
