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

import CoreGraphics
import FacetCore

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

    /// Window → 1-based workspace assignment. Survives across
    /// reconciles so a window the user moved stays where they put
    /// it; new windows land in `activeIndex` on the next reconcile.
    public private(set) var windowMap: [WindowID: Int] = [:]

    /// Windows currently parked at the bottom-right anchor sliver.
    /// `markAnchorParked` populates; `markAnchorRestored` clears.
    /// The adapter checks `shouldParkAnchor` / `shouldRestoreAnchor`
    /// before invoking AX so a poll-driven refresh can't re-park
    /// on top of a park.
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

    public init() {}

    // MARK: - Reconcile

    public struct ReconcileResult: Equatable, Sendable {
        public let added: Int
        public let removed: Int
    }

    /// Reconcile `windowMap` against the live CGWindowList ID set.
    /// Gone IDs are dropped from `windowMap`, `anchorParked`,
    /// `minimizeParked`, and `originalPositions` in one sweep.
    /// New IDs are assigned to `activeIndex` (memory:
    /// `facet-workspace-model` — "newly opened windows → current
    /// active facet WS").
    @discardableResult
    public mutating func reconcile(liveIDs: Set<WindowID>) -> ReconcileResult {
        let goneIDs = windowMap.keys.filter { !liveIDs.contains($0) }
        for id in goneIDs {
            windowMap.removeValue(forKey: id)
            anchorParked.remove(id)
            minimizeParked.remove(id)
            originalPositions.removeValue(forKey: id)
        }
        var added = 0
        for id in liveIDs where windowMap[id] == nil {
            windowMap[id] = activeIndex
            added += 1
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
        public let toPark: Set<WindowID>
        /// Windows in the new-active workspace that should be
        /// restored back into view.
        public let toRestore: Set<WindowID>
    }

    /// Switch to `n1Based`. Returns the plan when the switch is
    /// valid and meaningful; nil when target is invalid or already
    /// active. Caller applies AX side-effects against the
    /// returned ID sets.
    @discardableResult
    public mutating func setActive(_ n1Based: Int,
                                   configuredIndexes: [Int]) -> SwitchPlan? {
        guard isValid(n1Based, configuredIndexes: configuredIndexes),
              n1Based != activeIndex else { return nil }
        let old = activeIndex
        activeIndex = n1Based
        let toPark = Set(windowMap.compactMap { $1 == old ? $0 : nil })
        let toRestore = Set(windowMap.compactMap { $1 == n1Based ? $0 : nil })
        return SwitchPlan(oldActive: old, newActive: n1Based,
                          toPark: toPark, toRestore: toRestore)
    }

    // MARK: - Move window

    public enum MoveOutcome: Equatable, Sendable {
        /// Window left the active workspace — adapter should park it.
        case park(WindowID)
        /// Window entered the active workspace — adapter should
        /// restore (un-hide) it.
        case restore(WindowID)
        /// Window moved between two non-active workspaces — no
        /// visible change needed (window stays parked / hidden).
        case stateOnly
        /// Move was rejected (unknown window, invalid target, or
        /// already on target). No state change.
        case rejected
    }

    @discardableResult
    public mutating func moveWindow(_ id: WindowID, to n1Based: Int,
                                    configuredIndexes: [Int]) -> MoveOutcome {
        guard isValid(n1Based, configuredIndexes: configuredIndexes),
              let current = windowMap[id],
              current != n1Based else { return .rejected }
        windowMap[id] = n1Based
        if n1Based == activeIndex { return .restore(id) }
        if current == activeIndex { return .park(id) }
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
                         configured: [(index: Int, name: String)],
                         layoutMode: String) -> [Workspace] {
        let stamped = live.map { w in
            Window(id: w.id, pid: w.pid, appName: w.appName,
                   title: w.title,
                   isFocused: w.id == focused,
                   isFloating: w.isFloating,
                   frame: w.frame)
        }
        let byWS = Dictionary(grouping: stamped) { w in
            windowMap[w.id] ?? activeIndex
        }
        return configured.map { entry in
            Workspace(
                index: entry.index - 1,
                name: entry.name,
                isActive: entry.index == activeIndex,
                layoutMode: layoutMode,
                windows: byWS[entry.index] ?? [])
        }
    }
}
