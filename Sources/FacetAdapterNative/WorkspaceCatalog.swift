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
public struct WindowSlot: Equatable, Sendable {
    /// 1-based workspace index.
    public let workspace: Int
    public let pid: Int
    public init(workspace: Int, pid: Int) {
        self.workspace = workspace
        self.pid = pid
    }
}

/// A window referenced by id + pid — the minimum the adapter needs
/// to call `AXGeom.window(for:pid:)` on it. Plans and move
/// outcomes use this so the adapter never has to look pid up again.
public struct WindowRef: Hashable, Sendable {
    public let id: WindowID
    public let pid: Int
    public init(id: WindowID, pid: Int) {
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
public struct WorkspaceCatalog {

    // MARK: - State

    /// 1-based index of the active workspace.
    public private(set) var activeIndex: Int = 1

    /// Window → slot (workspace + pid). Survives across reconciles
    /// so a window the user moved stays where they put it; new
    /// windows land in `activeIndex` on the next reconcile.
    public private(set) var windowMap: [WindowID: WindowSlot] = [:]

    /// Windows currently parked at the bottom-right anchor sliver.
    /// `markAnchorParked` populates; `consumeAnchorRestore` clears.
    /// The adapter checks `shouldParkAnchor` before invoking AX so
    /// a poll-driven refresh can't re-park on top of a park.
    public private(set) var anchorParked: Set<WindowID> = []

    /// Windows currently minimized via AX `kAXMinimized`. Mirrors
    /// `anchorParked` but tracks a different OS state (Dock vs
    /// off-screen position). Kept separate so a runtime hide-method
    /// flip wouldn't conflate the two.
    public private(set) var minimizeParked: Set<WindowID> = []

    /// Position the window held before facet parked it via the
    /// anchor method. Recorded at park time, consumed at restore
    /// time. The minimize method doesn't need this — macOS
    /// remembers the un-minimized rect on its own.
    public private(set) var originalPositions: [WindowID: CGPoint] = [:]

    /// Per-WS layout mode. Missing entries default to `"float"`
    /// (Phase γ frozen decision: existing users see no surprise
    /// behaviour on upgrade). Valid values for γ.1: `"float"`,
    /// `"bsp"`. `"stack"` lands in γ.2.
    public private(set) var layoutModes: [Int: String] = [:]

    /// Per-WS BSP tree. Only present for WSs in `"bsp"` mode;
    /// other modes have no entry. Tree IDs are kept in sync with
    /// `windowMap` by `reconcile` / `moveWindow` / `drop` and by
    /// the explicit `setMode` migration path.
    public private(set) var layoutTrees: [Int: LayoutTree] = [:]

    /// Per-WS stack-member order. Only present for WSs in
    /// `"stack"` mode. The element at index 0 is the *visible
    /// top* (the single window that fills the display); the rest
    /// are parked via the configured `hide_method`. New windows
    /// land at index 0 (Q7c: new = top); `cycleStack` rotates
    /// the array.
    public private(set) var stackOrders: [Int: [WindowID]] = [:]

    /// Windows the user (or AX role detector) flagged as floating.
    /// Floating windows are skipped by the tiler and stay at the
    /// user's last-set position. Independent of `anchorParked` /
    /// `minimizeParked` (which are *hide-method* state, not
    /// per-window opt-out).
    public private(set) var floatingWindows: Set<WindowID> = []

    public init() {}

    // MARK: - Reconcile

    public struct ReconcileResult: Equatable, Sendable {
        public let added: Int
        public let removed: Int
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
    public mutating func reconcile(live: [Window],
                                   focused: WindowID? = nil,
                                   activeRect: CGRect = .zero)
        -> ReconcileResult
    {
        let liveByID = Dictionary(uniqueKeysWithValues:
                                  live.map { ($0.id, $0.pid) })
        let goneIDs = windowMap.keys.filter { liveByID[$0] == nil }
        for id in goneIDs {
            windowMap.removeValue(forKey: id)
            anchorParked.remove(id)
            minimizeParked.remove(id)
            originalPositions.removeValue(forKey: id)
            floatingWindows.remove(id)
            // Tree healing: a closed leaf's sibling absorbs the
            // space (LayoutTree.remove handles the recursion).
            for (ws, var tree) in layoutTrees where tree.contains(id) {
                tree.remove(id)
                layoutTrees[ws] = tree
            }
            // Stack-order maintenance — a closed window simply
            // exits the list; the next array element naturally
            // becomes the new top.
            for (ws, var order) in stackOrders
                where order.contains(id)
            {
                order.removeAll { $0 == id }
                stackOrders[ws] = order
            }
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
                let m = mode(of: activeIndex)
                if m == "bsp", !floatingWindows.contains(id) {
                    var tree = layoutTrees[activeIndex] ?? LayoutTree()
                    tree.insert(id, focused: focused, in: activeRect)
                    layoutTrees[activeIndex] = tree
                } else if m == "stack",
                          !floatingWindows.contains(id) {
                    // New window becomes the visible top (Q7c).
                    var order = stackOrders[activeIndex] ?? []
                    order.removeAll { $0 == id }
                    order.insert(id, at: 0)
                    stackOrders[activeIndex] = order
                }
            }
        }
        return ReconcileResult(added: added, removed: goneIDs.count)
    }

    /// Forget a window (called by `closeWindow` after AX press
    /// succeeded). Idempotent.
    public mutating func drop(_ id: WindowID) {
        windowMap.removeValue(forKey: id)
        anchorParked.remove(id)
        minimizeParked.remove(id)
        originalPositions.removeValue(forKey: id)
        floatingWindows.remove(id)
        for (ws, var tree) in layoutTrees where tree.contains(id) {
            tree.remove(id)
            layoutTrees[ws] = tree
        }
        for (ws, var order) in stackOrders where order.contains(id) {
            order.removeAll { $0 == id }
            stackOrders[ws] = order
        }
    }

    /// Clear all hide-state bookkeeping for `id` without
    /// returning the originalPosition. Used by stack-top apply
    /// where the AX setPosition + setSize sweeps the window to
    /// a fresh rect, so the recorded pre-park position has no
    /// further meaning.
    public mutating func clearParkedState(of id: WindowID) {
        anchorParked.remove(id)
        minimizeParked.remove(id)
        originalPositions.removeValue(forKey: id)
    }

    // MARK: - Layout mode (Phase γ)

    /// 1-based WS index → mode string. Missing entries default
    /// to `"float"` (Phase γ frozen default).
    public func mode(of n1Based: Int) -> String {
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
    public mutating func setMode(workspace n1Based: Int,
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

    // MARK: - Stack ops (Phase γ.2)

    /// Ordered stack members of `n1Based` (top first), or empty
    /// when the WS isn't in `"stack"` mode.
    public func stackOrder(of n1Based: Int) -> [WindowID] {
        stackOrders[n1Based] ?? []
    }

    public enum CycleDirection: Sendable { case next, prev }

    /// Rotate the stack array of `n1Based` so a different member
    /// becomes the top. `next` rotates left (current top goes to
    /// the end); `prev` rotates right (last member jumps to top).
    /// Returns the new top, or nil when the WS has fewer than 2
    /// stack members (cycle is a no-op).
    @discardableResult
    public mutating func cycleStack(workspace n1Based: Int,
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

    // MARK: - Floating

    public func isFloating(_ id: WindowID) -> Bool {
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
    public mutating func toggleFloat(_ id: WindowID,
                                     focused: WindowID? = nil,
                                     in rect: CGRect = .zero) {
        guard let slot = windowMap[id] else { return }
        let wasFloating = floatingWindows.contains(id)
        if wasFloating {
            floatingWindows.remove(id)
            switch mode(of: slot.workspace) {
            case "bsp":
                var tree = layoutTrees[slot.workspace] ?? LayoutTree()
                tree.insert(id, focused: focused, in: rect)
                layoutTrees[slot.workspace] = tree
            case "stack":
                var order = stackOrders[slot.workspace] ?? []
                order.removeAll { $0 == id }
                order.insert(id, at: 0)
                stackOrders[slot.workspace] = order
            default:
                break
            }
        } else {
            floatingWindows.insert(id)
            if var tree = layoutTrees[slot.workspace] {
                tree.remove(id)
                layoutTrees[slot.workspace] = tree
            }
            if var order = stackOrders[slot.workspace] {
                order.removeAll { $0 == id }
                stackOrders[slot.workspace] = order
            }
        }
    }

    // MARK: - Tree operations

    /// Rotate the parent split of `id`. Looks up the owning WS,
    /// then defers to `LayoutTree.toggleOrientation`. No-op when
    /// the window isn't in any tree (float / unknown / stack WS).
    public mutating func toggleOrientation(of id: WindowID) {
        guard let slot = windowMap[id],
              var tree = layoutTrees[slot.workspace] else { return }
        tree.toggleOrientation(of: id)
        layoutTrees[slot.workspace] = tree
    }

    /// Tree-computed frames for every tiled window in the WS,
    /// keyed by `WindowID`. Empty when the WS isn't in `"bsp"`
    /// mode or has no tree.
    public func tiledFrames(for n1Based: Int,
                            in rect: CGRect) -> [WindowID: CGRect] {
        guard mode(of: n1Based) == "bsp",
              let tree = layoutTrees[n1Based] else { return [:] }
        return tree.frames(in: rect)
    }

    /// Resolve the cached pid for a window, or nil if it's not in
    /// `windowMap`. Used by `closeWindow` so it can skip a
    /// CGWindowList re-enumeration just to recover pid.
    public func pid(for id: WindowID) -> Int? {
        windowMap[id]?.pid
    }

    // MARK: - Validation

    /// True when `n1Based` is a slot in the configured workspace
    /// list. Sparse configs (only `1`, `3`, `5` declared) are
    /// honoured: `2` is invalid even though raw count ≥ 2.
    public func isValid(_ n1Based: Int, configuredIndexes: [Int]) -> Bool {
        configuredIndexes.contains(n1Based)
    }

    // MARK: - Switch workspace

    public struct SwitchPlan: Equatable, Sendable {
        public let oldActive: Int
        public let newActive: Int
        /// Windows currently in the old-active workspace that
        /// should be parked by whichever hide method is active.
        public let toPark: [WindowRef]
        /// Windows in the new-active workspace that should be
        /// restored back into view.
        public let toRestore: [WindowRef]
    }

    /// Switch to `n1Based`. Returns the plan when the switch is
    /// valid and meaningful; nil when target is invalid or already
    /// active. Caller applies AX side-effects against the
    /// returned `WindowRef` lists.
    @discardableResult
    public mutating func setActive(_ n1Based: Int,
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

    public enum MoveOutcome: Equatable, Sendable {
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
    public mutating func moveWindow(_ id: WindowID, to n1Based: Int,
                                    configuredIndexes: [Int],
                                    in rect: CGRect = .zero) -> MoveOutcome {
        guard isValid(n1Based, configuredIndexes: configuredIndexes),
              let current = windowMap[id],
              current.workspace != n1Based else { return .rejected }
        windowMap[id] = WindowSlot(workspace: n1Based, pid: current.pid)
        // Layout maintenance: remove from source side (tree or
        // stack), insert into destination side (when dest mode
        // applies and the window isn't floating).
        if var srcTree = layoutTrees[current.workspace],
           srcTree.contains(id) {
            srcTree.remove(id)
            layoutTrees[current.workspace] = srcTree
        }
        if var srcOrder = stackOrders[current.workspace],
           srcOrder.contains(id) {
            srcOrder.removeAll { $0 == id }
            stackOrders[current.workspace] = srcOrder
        }
        if !floatingWindows.contains(id) {
            switch mode(of: n1Based) {
            case "bsp":
                var destTree = layoutTrees[n1Based] ?? LayoutTree()
                destTree.insert(id, focused: nil, in: rect)
                layoutTrees[n1Based] = destTree
            case "stack":
                // Q7c: window entering a stack WS lands on top.
                var destOrder = stackOrders[n1Based] ?? []
                destOrder.removeAll { $0 == id }
                destOrder.insert(id, at: 0)
                stackOrders[n1Based] = destOrder
            default:
                break
            }
        }
        let ref = WindowRef(id: id, pid: current.pid)
        if n1Based == activeIndex { return .restore(ref) }
        if current.workspace == activeIndex { return .park(ref) }
        return .stateOnly
    }

    // MARK: - Park bookkeeping (adapter calls after AX success)

    /// True when the anchor park should actually run (the window
    /// isn't already parked). Caller uses this as the early-exit
    /// guard before invoking AX.
    public func shouldParkAnchor(_ id: WindowID) -> Bool {
        !anchorParked.contains(id)
    }

    public mutating func markAnchorParked(_ id: WindowID,
                                          originalPosition: CGPoint) {
        anchorParked.insert(id)
        originalPositions[id] = originalPosition
    }

    /// Consume the recorded pre-park position. Returns nil when the
    /// window isn't currently parked (defensive against double-
    /// restore on rapid switch); side-effect-free in that case.
    public mutating func consumeAnchorRestore(_ id: WindowID) -> CGPoint? {
        guard anchorParked.contains(id),
              let pos = originalPositions[id] else { return nil }
        anchorParked.remove(id)
        originalPositions.removeValue(forKey: id)
        return pos
    }

    public func shouldMinimize(_ id: WindowID) -> Bool {
        !minimizeParked.contains(id)
    }

    public func shouldUnminimize(_ id: WindowID) -> Bool {
        minimizeParked.contains(id)
    }

    public mutating func markMinimized(_ id: WindowID) {
        minimizeParked.insert(id)
    }

    public mutating func markUnminimized(_ id: WindowID) {
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
    public func snapshot(live: [Window], focused: WindowID?,
                         configured: [(index: Int, name: String)])
        -> [Workspace]
    {
        let stamped = live.map { w in
            Window(id: w.id, pid: w.pid, appName: w.appName,
                   title: w.title,
                   isFocused: w.id == focused,
                   isFloating: floatingWindows.contains(w.id),
                   frame: w.frame)
        }
        let byWS = Dictionary(grouping: stamped) { w in
            windowMap[w.id]?.workspace ?? activeIndex
        }
        return configured.map { entry in
            Workspace(
                index: entry.index - 1,
                name: entry.name,
                isActive: entry.index == activeIndex,
                layoutMode: mode(of: entry.index),
                windows: byWS[entry.index] ?? [])
        }
    }
}
