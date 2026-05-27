// Pure value-type that holds the native adapter's self-managed
// workspace state.
//
// Why this exists separate from `NativeAdapter`:
//
//   - The state machine (window → workspace assignment, active
//     workspace, parked-window bookkeeping) is testable without
//     AX permission, CGWindowList, or any AppKit thread.
//   - `NativeAdapter` keeps only the effects (CGWindowList
//     enumeration, AX position / minimize, event stream
//     plumbing); it owns one `WorkspaceCatalog` and delegates
//     every state decision to it.
//
// Indexing convention
//
//   The catalog speaks 1-based indexes everywhere it borders the
//   user-facing CLI (`facet --workspace=N` is 1-indexed). The
//   `WindowBackend` protocol is 0-based on the wire, so
//   `NativeAdapter` translates at the seam (`index + 1` on entry,
//   `index - 1` on snapshot emit). Keeping the catalog 1-based
//   internally matches what the user sees in `facet status` and
//   `config.toml`'s `[workspace]` table.
//
// Why `WindowSlot` carries `pid` alongside `workspace`
//
//   AX operations (`AXGeom.window(for:pid:)`, the close-button
//   press) all need pid_t to construct an `AXUIElementCreateApplication`.
//   Without storing pid in `windowMap`, every `moveWindow` /
//   `closeWindow` re-enumerated CGWindowList just to recover pid.
//   With pid stored, the catalog can hand the adapter a
//   `WindowRef(id:, pid:)` directly and the AX dispatch is one
//   lookup.

import CoreGraphics
import FacetCore

/// One entry in `WorkspaceCatalog.windowMap`. Workspace assignment
/// plus the owning app's pid; pid is needed by every AX operation
/// the adapter performs on the window, so caching it here avoids
/// re-enumerating CGWindowList on `moveWindow` / `closeWindow`.
struct WindowSlot: Equatable, Sendable {
    /// 1-based workspace index.
    let workspace: Int
    let pid: Int
    init(workspace: Int, pid: Int) {
        self.workspace = workspace
        self.pid = pid
    }
}

/// A window referenced by id + pid — the minimum the adapter needs
/// to call `AXGeom.window(for:pid:)` on it. Plans and move
/// outcomes use this so the adapter never has to look pid up again.
struct WindowRef: Hashable, Sendable {
    let id: WindowID
    let pid: Int
    init(id: WindowID, pid: Int) {
        self.id = id
        self.pid = pid
    }
}

/// Self-managed workspace state for the native adapter.
///
/// All mutations return a *plan* (what windows the adapter should
/// park / restore) rather than performing the AX side-effects
/// themselves. This lets the AX side stay completely separate and
/// keeps the catalog unit-testable.
struct WorkspaceCatalog {

    // MARK: - State

    /// 1-based index of the active workspace.
    private(set) var activeIndex: Int = 1

    /// Window → slot (workspace + pid). Survives across reconciles
    /// so a window the user moved stays where they put it; new
    /// windows land in `activeIndex` on the next reconcile.
    private(set) var windowMap: [WindowID: WindowSlot] = [:]

    /// Windows currently parked at the bottom-right anchor sliver.
    /// `markAnchorParked` populates; `consumeAnchorRestore` clears.
    /// The adapter checks `shouldParkAnchor` before invoking AX so
    /// a poll-driven refresh can't re-park on top of a park.
    private(set) var anchorParked: Set<WindowID> = []

    /// Windows currently minimized via AX `kAXMinimized`. Mirrors
    /// `anchorParked` but tracks a different OS state (Dock vs
    /// off-screen position). Kept separate so a runtime hide-method
    /// flip wouldn't conflate the two.
    private(set) var minimizeParked: Set<WindowID> = []

    /// Position the window held before facet parked it via the
    /// anchor method. Recorded at park time, consumed at restore
    /// time. The minimize method doesn't need this — macOS
    /// remembers the un-minimized rect on its own.
    private(set) var originalPositions: [WindowID: CGPoint] = [:]

    /// Per-WS layout mode. Missing entries default to `"float"`
    /// (Phase γ frozen decision: existing users see no surprise
    /// behaviour on upgrade). Valid values: `"float"` / `"bsp"`
    /// / `"stack"`.
    private(set) var layoutModes: [Int: String] = [:]

    /// Per-WS BSP tree. Only present for WSs in `"bsp"` mode;
    /// other modes have no entry. Tree IDs are kept in sync with
    /// `windowMap` by `reconcile` / `moveWindow` / `drop` and by
    /// the explicit `setMode` migration path.
    private(set) var layoutTrees: [Int: LayoutTree] = [:]

    /// Per-WS stack-member order. Only present for WSs in
    /// `"stack"` mode. The element at index 0 is the *visible
    /// top* (the single window that fills the display); the rest
    /// are parked via the configured `hide_method`. New windows
    /// land at index 0 (Q7c: new = top); `cycleStack` rotates
    /// the array.
    private(set) var stackOrders: [Int: [WindowID]] = [:]

    /// Windows the user (or AX role detector) flagged as floating.
    /// Floating windows are skipped by the tiler and stay at the
    /// user's last-set position. Independent of `anchorParked` /
    /// `minimizeParked` (which are *hide-method* state, not
    /// per-window opt-out).
    private(set) var floatingWindows: Set<WindowID> = []

    /// Per-WS snapshot of which window was focused at the moment
    /// the user left that WS. Written by `recordLeaveFocus`
    /// (called unconditionally on every `switchWorkspace`),
    /// consumed by `autoFocusTarget` when a no-pick switch lands
    /// on this WS — restores the user back to the same window
    /// they were on. Cleared when the recorded window is closed
    /// or moved to a different WS, so a stale entry can't pin
    /// focus to a now-missing window.
    private(set) var lastFocusedOnLeave: [Int: WindowID] = [:]

    init() {}

    // MARK: - Reconcile

    struct ReconcileResult: Equatable, Sendable {
        let added: Int
        let removed: Int
    }

    /// Reconcile `windowMap` against the live CGWindowList. Gone
    /// IDs are dropped from `windowMap`, `anchorParked`,
    /// `minimizeParked`, `originalPositions`, `floatingWindows`,
    /// and from any `layoutTrees` that held them. New IDs land in
    /// `activeIndex` with their owning pid recorded; if the
    /// active WS is in `"bsp"` mode and the new window isn't
    /// flagged floating, it's also inserted into that WS's tree
    /// (memory: `facet-workspace-model` + `facet-phase-gamma-decisions`).
    ///
    /// Pid is refreshed on every reconcile even for known windows;
    /// pid is stable across a process's lifetime, but if a window
    /// id is ever reused after its owner died the fresh value wins.
    @discardableResult
    mutating func reconcile(live: [Window],
                                   focused: WindowID? = nil,
                                   activeRect: CGRect = .zero,
                                   autoFloat: Set<WindowID> = [])
        -> ReconcileResult
    {
        let liveByID = Dictionary(uniqueKeysWithValues:
                                  live.map { ($0.id, $0.pid) })
        let goneIDs = windowMap.keys.filter { liveByID[$0] == nil }
        for id in goneIDs {
            windowMap.removeValue(forKey: id)
            clearParkedState(of: id)
            floatingWindows.remove(id)
            detachFromLayouts(id)
            clearLeaveFocus(of: id)
        }
        var added = 0
        for (id, pid) in liveByID {
            if let existing = windowMap[id] {
                if existing.pid != pid {
                    windowMap[id] = WindowSlot(
                        workspace: existing.workspace, pid: pid)
                }
            } else {
                windowMap[id] = WindowSlot(
                    workspace: activeIndex, pid: pid)
                added += 1
                // Phase γ.3: AX role pre-flag — if the adapter
                // told us this id should be floating (sheet /
                // dialog / palette), mark it BEFORE the tile /
                // stack insert below so it skips both.
                if autoFloat.contains(id) {
                    floatingWindows.insert(id)
                }
                attachToLayout(id, workspace: activeIndex,
                               focused: focused,
                               in: activeRect)
            }
        }
        return ReconcileResult(added: added, removed: goneIDs.count)
    }

    /// Forget a window (called by `closeWindow` after AX press
    /// succeeded). Idempotent.
    mutating func drop(_ id: WindowID) {
        windowMap.removeValue(forKey: id)
        clearParkedState(of: id)
        floatingWindows.remove(id)
        detachFromLayouts(id)
        clearLeaveFocus(of: id)
    }

    /// Clear all hide-state bookkeeping for `id` without
    /// returning the originalPosition. Used by stack-top apply
    /// where the AX setPosition + setSize sweeps the window to
    /// a fresh rect, so the recorded pre-park position has no
    /// further meaning.
    mutating func clearParkedState(of id: WindowID) {
        anchorParked.remove(id)
        minimizeParked.remove(id)
        originalPositions.removeValue(forKey: id)
    }

    // MARK: - Layout maintenance (internal)

    /// Remove `id` from any layout container (`layoutTrees` and
    /// `stackOrders`) that holds it. Memory: lessons file
    /// "stackOrders / layoutTrees 並列メンテ" — every mutator
    /// must touch both, this is the one place to forget.
    /// Idempotent.
    private mutating func detachFromLayouts(_ id: WindowID) {
        for (ws, var tree) in layoutTrees where tree.contains(id) {
            tree.remove(id)
            layoutTrees[ws] = tree
        }
        for (ws, var order) in stackOrders where order.contains(id) {
            order.removeAll { $0 == id }
            stackOrders[ws] = order
        }
    }

    /// Insert `id` into the layout container appropriate to
    /// `n1Based`'s mode (bsp → tree, stack → order at index 0,
    /// anything else → no-op). Skips when `id` is floating.
    /// `focused` / `rect` only matter for the bsp path (passed
    /// to `LayoutTree.insert` for orientation choice).
    private mutating func attachToLayout(_ id: WindowID,
                                         workspace n1Based: Int,
                                         focused: WindowID?,
                                         in rect: CGRect) {
        guard !floatingWindows.contains(id) else { return }
        switch mode(of: n1Based) {
        case "bsp":
            var tree = layoutTrees[n1Based] ?? LayoutTree()
            tree.insert(id, focused: focused, in: rect)
            layoutTrees[n1Based] = tree
        case "stack":
            var order = stackOrders[n1Based] ?? []
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
            stackOrders[n1Based] = order
        default:
            break
        }
    }

    // MARK: - Layout mode

    /// 1-based WS index → mode string. Missing entries default
    /// to `"float"` (Phase γ frozen default).
    func mode(of n1Based: Int) -> String {
        layoutModes[n1Based] ?? "float"
    }

    /// Change the mode of a workspace. Side-effects on layout
    /// state:
    ///   - → `"bsp"`: build a fresh tree from the WS's current
    ///     non-floating windows (auto-balance order, sorted by
    ///     `WindowID.serverID` for deterministic insertion).
    ///     Discards any existing stack order.
    ///   - → `"stack"`: build a fresh stack-order list from the
    ///     WS's current non-floating windows (id-sorted; caller
    ///     can promote a different top via `cycleStack` if the
    ///     starting top matters). Discards any existing tree.
    ///   - → `"float"` / anything else: discard both tree and
    ///     stack-order entries. Adapter leaves the windows
    ///     wherever they were last placed.
    ///
    /// Caller drives the AX side-effects (re-tile / re-stack /
    /// no-op). Returns the normalised mode so the caller can
    /// branch.
    @discardableResult
    mutating func setMode(workspace n1Based: Int,
                                 to mode: String,
                                 in rect: CGRect = .zero) -> String {
        let normalised = mode.lowercased()
        layoutModes[n1Based] = normalised
        let members = windowMap
            .filter { $0.value.workspace == n1Based
                && !floatingWindows.contains($0.key) }
            .map(\.key)
            .sorted { $0.serverID < $1.serverID }
        switch normalised {
        case "bsp":
            var tree = LayoutTree()
            for id in members {
                tree.insert(id, focused: nil, in: rect)
            }
            layoutTrees[n1Based] = tree
            stackOrders.removeValue(forKey: n1Based)
        case "stack":
            stackOrders[n1Based] = members
            layoutTrees.removeValue(forKey: n1Based)
        default:
            layoutTrees.removeValue(forKey: n1Based)
            stackOrders.removeValue(forKey: n1Based)
        }
        return normalised
    }

    // MARK: - Stack ops

    /// Ordered stack members of `n1Based` (top first), or empty
    /// when the WS isn't in `"stack"` mode.
    func stackOrder(of n1Based: Int) -> [WindowID] {
        stackOrders[n1Based] ?? []
    }

    enum CycleDirection: Sendable { case next, prev }

    /// Rotate the stack array of `n1Based` so a different member
    /// becomes the top. `next` rotates left (current top goes to
    /// the end); `prev` rotates right (last member jumps to top).
    /// Returns the new top, or nil when the WS has fewer than 2
    /// stack members (cycle is a no-op).
    @discardableResult
    mutating func cycleStack(workspace n1Based: Int,
                                    direction: CycleDirection)
        -> WindowID?
    {
        guard var order = stackOrders[n1Based],
              order.count >= 2 else { return nil }
        switch direction {
        case .next:
            order.append(order.removeFirst())
        case .prev:
            order.insert(order.removeLast(), at: 0)
        }
        stackOrders[n1Based] = order
        return order.first
    }

    // MARK: - Leave-focus snapshot (auto-focus on re-entry)

    /// Remember which window was focused on `ws` at leave time.
    /// Called unconditionally on every `switchWorkspace` so the
    /// snapshot is fresh regardless of whether the next entry to
    /// `ws` will auto-focus or not. `id` is whatever
    /// `frontmostFocusedCGID` reported at leave time — even if it
    /// turns out to belong to a different WS (rare race), the
    /// stale entry self-cleans on the next reconcile / drop /
    /// move that touches `id`.
    mutating func recordLeaveFocus(_ id: WindowID, in ws: Int) {
        lastFocusedOnLeave[ws] = id
    }

    /// Drop `id` from every WS's leave-focus snapshot. Called
    /// from `reconcile` / `drop` / `moveWindow` so a closed or
    /// relocated window can't keep pinning auto-focus on a
    /// no-longer-valid target.
    mutating func clearLeaveFocus(of id: WindowID) {
        for (ws, recorded) in lastFocusedOnLeave where recorded == id {
            lastFocusedOnLeave.removeValue(forKey: ws)
        }
    }

    /// Pick the window an auto-focus switch into `ws` should
    /// settle on. `windows` is the live window list of that WS
    /// (caller passes the filtered subset so this method stays
    /// pure on the snapshot). Returns:
    ///   1. `lastFocusedOnLeave[ws]` if still present in `windows`
    ///   2. else the existing `pred` chain from sidebar header
    ///      click — `windows.first(where: \.isFocused)?.id ?? min(serverID)`
    ///      — so optimistic highlight and auto-focus always
    ///      settle on the same window.
    /// `nil` only when `windows` is empty (= the 2-b empty-WS
    /// branch the caller handles with a defocus instead).
    func autoFocusTarget(in ws: Int,
                                windows: [Window]) -> WindowID?
    {
        if let recorded = lastFocusedOnLeave[ws],
           windows.contains(where: { $0.id == recorded }) {
            return recorded
        }
        if let focused = windows.first(where: { $0.isFocused })?.id {
            return focused
        }
        return windows.map(\.id).min(by: {
            $0.serverID < $1.serverID
        })
    }

    // MARK: - Floating

    func isFloating(_ id: WindowID) -> Bool {
        floatingWindows.contains(id)
    }

    /// Flip the floating flag on `id` and adjust the tree of the
    /// owning WS (if it's in `"bsp"` mode): a window flipping to
    /// floating is removed from the tree; flipping back inserts
    /// it (auto-balance against the focused leaf).
    ///
    /// `rect` is the active display's `visibleFrame` — only used
    /// for the *orientation choice* when re-inserting; tile
    /// frames are recomputed every time `tiledFrames` runs.
    mutating func toggleFloat(_ id: WindowID,
                                     focused: WindowID? = nil,
                                     in rect: CGRect = .zero) {
        guard let slot = windowMap[id] else { return }
        let wasFloating = floatingWindows.contains(id)
        if wasFloating {
            floatingWindows.remove(id)
            // Re-enter the WS's layout (no-op if mode is float).
            attachToLayout(id, workspace: slot.workspace,
                           focused: focused, in: rect)
        } else {
            floatingWindows.insert(id)
            detachFromLayouts(id)
        }
    }

    // MARK: - Tree operations

    /// Rotate the parent split of `id`. Looks up the owning WS,
    /// then defers to `LayoutTree.toggleOrientation`. No-op when
    /// the window isn't in any tree (float / unknown / stack WS).
    mutating func toggleOrientation(of id: WindowID) {
        guard let slot = windowMap[id],
              var tree = layoutTrees[slot.workspace] else { return }
        tree.toggleOrientation(of: id)
        layoutTrees[slot.workspace] = tree
    }

    /// Tree-computed frames for every tiled window in the WS,
    /// keyed by `WindowID`. Empty when the WS isn't in `"bsp"`
    /// mode or has no tree.
    func tiledFrames(for n1Based: Int,
                            in rect: CGRect) -> [WindowID: CGRect] {
        guard mode(of: n1Based) == "bsp",
              let tree = layoutTrees[n1Based] else { return [:] }
        return tree.frames(in: rect)
    }

    /// Resolve the cached pid for a window, or nil if it's not in
    /// `windowMap`. Used by `closeWindow` so it can skip a
    /// CGWindowList re-enumeration just to recover pid.
    func pid(for id: WindowID) -> Int? {
        windowMap[id]?.pid
    }

    // MARK: - Validation

    /// True when `n1Based` is a slot in the configured workspace
    /// list. Sparse configs (only `1`, `3`, `5` declared) are
    /// honoured: `2` is invalid even though raw count ≥ 2.
    func isValid(_ n1Based: Int, configuredIndexes: [Int]) -> Bool {
        configuredIndexes.contains(n1Based)
    }

    // MARK: - Switch workspace

    struct SwitchPlan: Equatable, Sendable {
        let oldActive: Int
        let newActive: Int
        /// Windows currently in the old-active workspace that
        /// should be parked by whichever hide method is active.
        let toPark: [WindowRef]
        /// Windows in the new-active workspace that should be
        /// restored back into view.
        let toRestore: [WindowRef]
    }

    /// Switch to `n1Based`. Returns the plan when the switch is
    /// valid and meaningful; nil when target is invalid or already
    /// active. Caller applies AX side-effects against the
    /// returned `WindowRef` lists.
    @discardableResult
    mutating func setActive(_ n1Based: Int,
                                   configuredIndexes: [Int]) -> SwitchPlan? {
        guard isValid(n1Based, configuredIndexes: configuredIndexes),
              n1Based != activeIndex else { return nil }
        let old = activeIndex
        activeIndex = n1Based
        let toPark = windowMap
            .filter { $0.value.workspace == old }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        let toRestore = windowMap
            .filter { $0.value.workspace == n1Based }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        return SwitchPlan(oldActive: old, newActive: n1Based,
                          toPark: toPark, toRestore: toRestore)
    }

    // MARK: - Move window

    enum MoveOutcome: Equatable, Sendable {
        /// Window left the active workspace — adapter should park it.
        case park(WindowRef)
        /// Window entered the active workspace — adapter should
        /// restore (un-hide) it.
        case restore(WindowRef)
        /// Window moved between two non-active workspaces — no
        /// visible change needed (window stays parked / hidden).
        case stateOnly
        /// Move was rejected (unknown window, invalid target, or
        /// already on target). No state change.
        case rejected
    }

    @discardableResult
    mutating func moveWindow(_ id: WindowID, to n1Based: Int,
                                    configuredIndexes: [Int],
                                    in rect: CGRect = .zero) -> MoveOutcome {
        guard isValid(n1Based, configuredIndexes: configuredIndexes),
              let current = windowMap[id],
              current.workspace != n1Based else { return .rejected }
        windowMap[id] = WindowSlot(workspace: n1Based, pid: current.pid)
        // Detach from source's layout container (if any), then
        // attach to dest's. Both helpers are no-ops when the
        // window isn't in the relevant container / mode, so the
        // call is unconditional.
        detachFromLayouts(id)
        attachToLayout(id, workspace: n1Based,
                       focused: nil, in: rect)
        // The window is no longer a valid leave-focus target for
        // the source WS — clear so the next return to that WS
        // falls back to pred instead of pointing at a window
        // that's now elsewhere.
        clearLeaveFocus(of: id)
        let ref = WindowRef(id: id, pid: current.pid)
        if n1Based == activeIndex { return .restore(ref) }
        if current.workspace == activeIndex { return .park(ref) }
        return .stateOnly
    }

    // MARK: - Park bookkeeping (adapter calls after AX success)

    /// True when the anchor park should actually run (the window
    /// isn't already parked). Caller uses this as the early-exit
    /// guard before invoking AX.
    func shouldParkAnchor(_ id: WindowID) -> Bool {
        !anchorParked.contains(id)
    }

    mutating func markAnchorParked(_ id: WindowID,
                                          originalPosition: CGPoint) {
        anchorParked.insert(id)
        originalPositions[id] = originalPosition
    }

    /// Consume the recorded pre-park position. Returns nil when the
    /// window isn't currently parked (defensive against double-
    /// restore on rapid switch); side-effect-free in that case.
    mutating func consumeAnchorRestore(_ id: WindowID) -> CGPoint? {
        guard anchorParked.contains(id),
              let pos = originalPositions[id] else { return nil }
        anchorParked.remove(id)
        originalPositions.removeValue(forKey: id)
        return pos
    }

    func shouldMinimize(_ id: WindowID) -> Bool {
        !minimizeParked.contains(id)
    }

    func shouldUnminimize(_ id: WindowID) -> Bool {
        minimizeParked.contains(id)
    }

    mutating func markMinimized(_ id: WindowID) {
        minimizeParked.insert(id)
    }

    mutating func markUnminimized(_ id: WindowID) {
        minimizeParked.remove(id)
    }

    // MARK: - Snapshot

    /// Build the `WindowBackend.workspaces()` return value from
    /// the current state + a fresh live-window list.
    ///
    /// `live` is the CGWindowList-derived `[Window]` with raw
    /// `isFocused: false`; this method stamps the real focus flag
    /// against `focused`. Windows whose ID isn't in `windowMap`
    /// fall back to `activeIndex` (consistent with reconcile, but
    /// also covers the race where snapshot runs before reconcile
    /// in the same call site).
    ///
    /// The returned `Workspace.index` is **0-based** to match the
    /// wire convention of the `WindowBackend` protocol — translation
    /// happens here at the seam.
    func snapshot(live: [Window], focused: WindowID?,
                         activeRect: CGRect,
                         configured: [(index: Int, name: String)])
        -> [Workspace]
    {
        // Group raw live windows by WS first so per-WS layout
        // queries (tiledFrames / stackOrders) only run once.
        let byWS = Dictionary(grouping: live) { w in
            windowMap[w.id]?.workspace ?? activeIndex
        }
        return configured.map { entry in
            let isActive = entry.index == activeIndex
            let m = mode(of: entry.index)
            let tileF = (m == "bsp")
                ? tiledFrames(for: entry.index, in: activeRect)
                : [:]
            let stackSet: Set<WindowID> = (m == "stack")
                ? Set(stackOrders[entry.index] ?? [])
                : []
            let wins = (byWS[entry.index] ?? []).map { w in
                Window(id: w.id, pid: w.pid, appName: w.appName,
                       title: w.title,
                       isFocused: w.id == focused,
                       isFloating: floatingWindows.contains(w.id),
                       frame: wouldBeFrame(
                           for: w, isActiveWS: isActive,
                           mode: m, tileFrames: tileF,
                           stackSet: stackSet,
                           activeRect: activeRect))
            }
            return Workspace(
                index: entry.index - 1,
                name: entry.name,
                isActive: isActive,
                layoutMode: m,
                windows: wins)
        }
    }

    /// Compute the frame the user *perceives* for `w`:
    ///   - Active WS: the raw CG bounds — the window is on-screen
    ///     right there.
    ///   - Inactive WS, floating or float-mode: the pre-anchor
    ///     position (recorded in `originalPositions` when we
    ///     parked it), combined with the current size. Falls back
    ///     to the raw frame when nothing was recorded (window
    ///     never parked, fresh app, …).
    ///   - Inactive WS, bsp-mode: the tile slot the window will
    ///     occupy when the WS becomes active.
    ///   - Inactive WS, stack-mode: the active rect (stack members
    ///     all fill the display once cycled to the top).
    ///
    /// This is what makes the tree-view "mirror" preview show the
    /// window where it *will be* after a switch instead of where
    /// it's been parked (a 1×41 corner sliver under
    /// `hide_method = "anchor"`).
    private func wouldBeFrame(for w: Window,
                              isActiveWS: Bool,
                              mode m: String,
                              tileFrames: [WindowID: CGRect],
                              stackSet: Set<WindowID>,
                              activeRect: CGRect) -> CGRect?
    {
        if isActiveWS { return w.frame }
        if floatingWindows.contains(w.id) {
            return preParkFrame(for: w)
        }
        switch m {
        case "bsp":
            return tileFrames[w.id] ?? preParkFrame(for: w)
        case "stack":
            return stackSet.contains(w.id)
                ? activeRect : preParkFrame(for: w)
        default:
            return preParkFrame(for: w)
        }
    }

    private func preParkFrame(for w: Window) -> CGRect? {
        if let origin = originalPositions[w.id], let size = w.frame?.size {
            return CGRect(origin: origin, size: size)
        }
        return w.frame
    }
}
