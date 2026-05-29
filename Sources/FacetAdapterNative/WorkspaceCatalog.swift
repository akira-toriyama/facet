// Pure value-type that holds the native adapter's self-managed
// workspace state.
//
// Why this exists separate from `NativeAdapter`:
//
//   - The state machine (window → workspace assignment, active
//     workspace, parked-window bookkeeping) is testable without
//     AX permission, CGWindowList, or any AppKit thread.
//   - `NativeAdapter` keeps only the effects (CGWindowList
//     enumeration, AX position, event stream plumbing); it owns
//     one `WorkspaceCatalog` and delegates every state decision
//     to it.
//
// Indexing convention
//
//   The catalog speaks 1-based indexes everywhere it borders the
//   user-facing CLI (`facet workspace --focus=N` is 1-indexed). The
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

    /// 1-based index of the workspace that was active immediately
    /// before the current one, or nil before the first switch. Powers
    /// `workspace --focus=recent`. Updated by `setActive` on every
    /// real transition; cleared to nil only at init.
    private(set) var previousActiveIndex: Int?

    /// Window → slot (workspace + pid). Survives across reconciles
    /// so a window the user moved stays where they put it; new
    /// windows land in `activeIndex` on the next reconcile.
    private(set) var windowMap: [WindowID: WindowSlot] = [:]

    /// Windows currently parked at the bottom-right anchor sliver.
    /// `markAnchorParked` populates; `consumeAnchorRestore` clears.
    /// The adapter checks `shouldParkAnchor` before invoking AX so
    /// a poll-driven refresh can't re-park on top of a park.
    private(set) var anchorParked: Set<WindowID> = []

    /// Position the window held before facet parked it at the
    /// anchor sliver. Recorded at park time, consumed at restore
    /// time.
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

    /// Per-WS window order, shared by `"stack"` mode and the
    /// stateless `LayoutEngine`s (tall / monocle / …). Index 0 is
    /// the master / visible-top: in stack it's the single window
    /// that fills the display (the rest parked at the anchor sliver);
    /// in tall it's the primary master. New windows land at index 0
    /// (Q7c: new = top / master); `cycleStack` rotates the array and
    /// `promoteToMaster` moves a chosen window to index 0. Absent for
    /// bsp (uses `layoutTrees`) and float (no managed order).
    private(set) var stackOrders: [Int: [WindowID]] = [:]

    /// Per-WS layout knobs (master ratio / master count) for the
    /// stateless engines that read them (tall, centered-master).
    /// Runtime-only — never persisted to config (Theme B decision).
    /// Missing entry → `LayoutParams()` defaults. Kept across mode
    /// flips so a WS remembers its ratio when you toggle away and
    /// back.
    private(set) var layoutParams: [Int: LayoutParams] = [:]

    /// Windows the user (or AX role detector) flagged as floating.
    /// Floating windows are skipped by the tiler and stay at the
    /// user's last-set position. Independent of `anchorParked`
    /// (which is hide state, not a per-window opt-out).
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

    /// IDs that have been observed `isOnscreen=true` once but not
    /// yet committed to `windowMap`. Reconcile requires **two
    /// consecutive on-screen observations** before adding so a
    /// transient cross-Space visibility flip during a macOS
    /// Space-switch animation doesn't get mistaken for a genuine
    /// new window. Cleared when the window goes off-screen, the
    /// catalog leaves the facet Space, or the window enters
    /// `windowMap` for real. See memory
    /// `facet-macos-spaces-coexistence`.
    private(set) var pendingAddCandidates: Set<WindowID> = []

    /// IDs reconcile has decided NOT to auto-manage on a later
    /// `isOnscreen` flip. Populated two ways:
    ///   1. **Bulk-marked as pre-existing** via `markPreExisting`
    ///      — called at startup with the initial enumeration and
    ///      on every `activeSpaceDidChange` with the post-switch
    ///      enumeration. Every CGWindowList ID at that moment is
    ///      flagged, so a window already alive when facet (or the
    ///      Space change) appeared can never grab a slot in
    ///      `activeIndex` later when its on-screen state flips.
    ///   2. **Self-marked on successful add** — when reconcile
    ///      genuinely adds a window to `windowMap` (saw it as
    ///      `isOnscreen=true` for the first time), it also marks
    ///      that ID examined so a subsequent close + replay
    ///      can't get added twice.
    /// Critical invariant: a window first observed `isOnscreen=
    /// false` is NOT auto-examined. Some windows (Chrome's first
    /// new window after launch, for example) briefly report
    /// `isOnscreen=false` during creation; the next reconcile
    /// catches them with `true` and adds them. See memory
    /// `facet-macos-spaces-coexistence`.
    private(set) var examinedIDs: Set<WindowID> = []

    init() {}

    // MARK: - Reconcile

    struct ReconcileResult: Equatable, Sendable {
        let added: Int
        let removed: Int
    }

    /// Reconcile `windowMap` against the live CGWindowList. Gone
    /// IDs are dropped from `windowMap`, `anchorParked`,
    /// `originalPositions`, `floatingWindows`, and from any
    /// `layoutTrees` that held them. New IDs land in
    /// `activeIndex` with their owning pid recorded; if the
    /// active WS is in `"bsp"` mode and the new window isn't
    /// flagged floating, it's also inserted into that WS's tree
    /// (memory: `facet-workspace-model` + `facet-phase-gamma-decisions`).
    ///
    /// Pid is refreshed on every reconcile even for known windows;
    /// pid is stable across a process's lifetime, but if a window
    /// id is ever reused after its owner died the fresh value wins.
    ///
    /// `trusted` lists ids the adapter saw a `kAXWindowCreated` for —
    /// genuinely new windows, which can't be a Space-switch
    /// `isOnscreen` flip of an existing one. They skip the two-tick
    /// gate (added on first on-screen sight) but still honour
    /// `allowAutoAdd` and the off-screen defer, so off-Space windows
    /// and the flip case remain protected.
    @discardableResult
    mutating func reconcile(live: [Window],
                                   focused: WindowID? = nil,
                                   activeRect: CGRect = .zero,
                                   autoFloat: Set<WindowID> = [],
                                   trusted: Set<WindowID> = [],
                                   requireConfirm: Bool = false)
        -> ReconcileResult
    {
        let liveByID = Dictionary(uniqueKeysWithValues:
                                  live.map { ($0.id, $0) })
        let liveIDs = Set(liveByID.keys)
        // Truly-gone IDs only: a window absent from the full
        // CGWindowList enumeration (which now includes off-screen
        // windows via .optionAll). A window that's merely on a
        // different macOS Space, minimized to the Dock, or Cmd+H'd
        // stays in `liveByID` with `isOnscreen=false` — we keep
        // its WS assignment so the user gets it back where they
        // left it.
        let goneIDs = windowMap.keys.filter { !liveIDs.contains($0) }
        for id in goneIDs { forgetWindow(id) }
        // "Are we on a macOS Space that holds at least one window
        // facet already manages?" If not, suppress auto-add so a
        // window the user opens while parked on an unrelated Space
        // (e.g. open Finder after switching to Space 2) doesn't
        // slide into `activeIndex` and pollute the user's facet
        // tree. The catalog has no public way to know its own
        // Space membership without dipping into private SkyLight
        // APIs, so this heuristic uses the visibility of an
        // already-managed window as a proxy: if one of ours is
        // on-screen, the user is on "our" Space. Empty-catalog
        // bootstrap is exempt — facet has to be able to pick up
        // its first batch of windows.
        let onFacetSpace = windowMap.keys.contains { id in
            liveByID[id]?.isOnscreen == true
        }
        let allowAutoAdd = windowMap.isEmpty || onFacetSpace
        var added = 0
        for (id, w) in liveByID {
            if let existing = windowMap[id] {
                if existing.pid != w.pid {
                    windowMap[id] = WindowSlot(
                        workspace: existing.workspace, pid: w.pid)
                }
                continue
            }
            // Bulk-marked pre-existing (other Space at startup /
            // Space-change snapshot, Cmd+H'd window seen at
            // startup, etc.). Stay out of `windowMap` even if
            // the OS later flips them on-screen.
            if examinedIDs.contains(id) { continue }
            // Off-Space new window: see `allowAutoAdd` above.
            // Don't mark examined either — when the user comes
            // back to facet's Space and the window is moved here
            // (or any managed window becomes visible alongside
            // it), the next reconcile will add it.
            if !allowAutoAdd {
                pendingAddCandidates.remove(id)
                continue
            }
            // First-sight off-screen: defer the decision. Don't
            // mark examined yet — newly-opened windows (e.g.
            // Chrome's first window post-launch) can briefly
            // report `isOnscreen=false` during creation, and a
            // premature examined-mark here would lock them out
            // for good.
            guard w.isOnscreen else {
                pendingAddCandidates.remove(id)
                continue
            }
            // Two-tick gate. A window must be seen `isOnscreen=
            // true` on TWO consecutive reconciles before joining
            // `windowMap`. This swallows the transient cross-
            // Space visibility flip that happens during a
            // macOS-Space switch animation: a Finder window
            // opened on Space N briefly reads `isOnscreen=true`
            // when the user swipes back to Space 1, but settles
            // to `false` by the next reconcile — without the
            // gate it would pile into `activeIndex`. Cost: a
            // genuine new window takes one extra ~2 s poll
            // before showing up in the sidebar.
            //
            // Tests that don't simulate the poll loop opt out
            // via `requireConfirm: false` and get the old
            // single-call commit behaviour.
            //
            // `trusted` ids (a `kAXWindowCreated` fired for them) skip
            // the gate: a brand-new window can't be the cross-Space
            // flip the gate defends against, so making it wait a
            // second tick only adds the ~2s latency we're removing.
            if requireConfirm,
               !pendingAddCandidates.contains(id),
               !trusted.contains(id)
            {
                pendingAddCandidates.insert(id)
                continue
            }
            pendingAddCandidates.remove(id)
            windowMap[id] = WindowSlot(
                workspace: activeIndex, pid: w.pid)
            examinedIDs.insert(id)
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
        return ReconcileResult(added: added, removed: goneIDs.count)
    }

    /// Bulk-mark every id in `live` as pre-existing (don't
    /// auto-add later on an `isOnscreen` flip). Called from the
    /// adapter at startup (with the first enumeration) and on
    /// every `activeSpaceDidChange` (with the post-switch
    /// enumeration) — so windows revealed by a Space transition
    /// stay out of `activeIndex`. Idempotent.
    mutating func markPreExisting(_ ids: some Sequence<WindowID>) {
        examinedIDs.formUnion(ids)
    }

    /// Forget a window (called by `closeWindow` after AX press
    /// succeeded). Idempotent.
    mutating func drop(_ id: WindowID) {
        forgetWindow(id)
    }

    /// Drop every per-window bookkeeping entry for `id`. Shared
    /// by `reconcile` (window gone from the live CGWindowList)
    /// and `drop` (explicit close). New per-window state (Phase ζ
    /// onward) should be cleared here too rather than at each
    /// call site — that's the invariant this helper exists to
    /// hold.
    private mutating func forgetWindow(_ id: WindowID) {
        windowMap.removeValue(forKey: id)
        clearParkedState(of: id)
        floatingWindows.remove(id)
        detachFromLayouts(id)
        clearLeaveFocus(of: id)
        examinedIDs.remove(id)
        pendingAddCandidates.remove(id)
    }

    /// Clear all hide-state bookkeeping for `id` without
    /// returning the originalPosition. Used by stack-top apply
    /// where the AX setPosition + setSize sweeps the window to
    /// a fresh rect, so the recorded pre-park position has no
    /// further meaning.
    mutating func clearParkedState(of id: WindowID) {
        anchorParked.remove(id)
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
        let m = mode(of: n1Based)
        if m == "bsp" {
            var tree = layoutTrees[n1Based] ?? LayoutTree()
            tree.insert(id, focused: focused, in: rect)
            layoutTrees[n1Based] = tree
        } else if m == "stack" || LayoutRegistry.engine(named: m) != nil {
            // Stack + stateless engines share one per-WS order; new
            // window lands at index 0 (= master / top).
            var order = stackOrders[n1Based] ?? []
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
            stackOrders[n1Based] = order
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
        let members = nonFloatingMembers(of: n1Based)
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
            if LayoutRegistry.engine(named: normalised) != nil {
                // Stateless engine (tall, monocle, …): seed the
                // shared per-WS order; discard any tree.
                stackOrders[n1Based] = members
                layoutTrees.removeValue(forKey: n1Based)
            } else {
                // float / unknown → no managed layout state.
                layoutTrees.removeValue(forKey: n1Based)
                stackOrders.removeValue(forKey: n1Based)
            }
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

    /// Move `id` to the front (master slot / index 0) of the WS's
    /// shared order. No-op — returns `false` — when the WS has no
    /// maintained order, doesn't contain `id`, or `id` is already the
    /// master. Used by `promoteToMaster` for tall / master-stack.
    @discardableResult
    mutating func promoteToMaster(_ id: WindowID,
                                         workspace n1Based: Int) -> Bool {
        guard var order = stackOrders[n1Based],
              let idx = order.firstIndex(of: id), idx != 0
        else { return false }
        order.remove(at: idx)
        order.insert(id, at: 0)
        stackOrders[n1Based] = order
        return true
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
    ///   2. else `Sequence<Window>.predictedFocus()` — the same
    ///      chain the sidebar's optimistic header highlight uses,
    ///      so the two never drift.
    /// `nil` only when `windows` is empty (= the 2-b empty-WS
    /// branch the caller handles with a defocus instead).
    func autoFocusTarget(in ws: Int, windows: [Window]) -> Window? {
        if let recorded = lastFocusedOnLeave[ws],
           let hit = windows.first(where: { $0.id == recorded }) {
            return hit
        }
        return windows.predictedFocus()
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

    /// Non-floating windows of `n1Based`, sorted by `serverID` for a
    /// stable, deterministic order. Shared by `setMode` (tree / stack
    /// seeding) and the stateless layout-engine path so both agree on
    /// "which windows, in what order".
    func nonFloatingMembers(of n1Based: Int) -> [WindowID] {
        windowMap
            .filter { $0.value.workspace == n1Based
                && !floatingWindows.contains($0.key) }
            .map(\.key)
            .sorted { $0.serverID < $1.serverID }
    }

    /// The WS's non-floating windows in maintained order
    /// (`stackOrders`), reconciled against current membership: stale
    /// ids dropped, any member missing from the order appended. Feeds
    /// stateless engines a stable + complete order even if the order
    /// and membership briefly drift (a missing member would otherwise
    /// get no frame and be left wherever it was).
    func orderedMembers(of n1Based: Int) -> [WindowID] {
        let members = nonFloatingMembers(of: n1Based)
        let memberSet = Set(members)
        let maintained = (stackOrders[n1Based] ?? [])
            .filter { memberSet.contains($0) }
        let have = Set(maintained)
        return maintained + members.filter { !have.contains($0) }
    }

    /// Frames from the registered stateless `LayoutEngine` for
    /// `n1Based`'s mode, or empty when the mode isn't a registered
    /// engine (bsp / stack / float). The engine is pure; this hands
    /// it the WS's stable, complete member order + the rect to carve.
    func engineFrames(for n1Based: Int,
                             in rect: CGRect) -> [WindowID: CGRect] {
        guard let engine = LayoutRegistry.engine(named: mode(of: n1Based))
        else { return [:] }
        return engine.frames(order: orderedMembers(of: n1Based),
                             focused: nil,
                             params: params(of: n1Based),
                             in: rect)
    }

    // MARK: - Layout knobs (master ratio / count)

    /// Per-WS layout knobs, or defaults when none set.
    func params(of n1Based: Int) -> LayoutParams {
        layoutParams[n1Based] ?? LayoutParams()
    }

    /// Nudge the master ratio by `delta` (clamped 0.05…0.95 by
    /// `LayoutParams`). Returns whether the value actually changed
    /// (false at the clamp boundary, so the caller can skip a
    /// pointless re-tile).
    @discardableResult
    mutating func adjustMasterRatio(workspace n1Based: Int,
                                           delta: CGFloat) -> Bool {
        let cur = params(of: n1Based)
        let next = LayoutParams(masterRatio: cur.masterRatio + delta,
                                masterCount: cur.masterCount,
                                orientation: cur.orientation)
        layoutParams[n1Based] = next
        return next.masterRatio != cur.masterRatio
    }

    /// Nudge the master count by `delta` (clamped ≥ 1). Returns
    /// whether the value actually changed.
    @discardableResult
    mutating func adjustMasterCount(workspace n1Based: Int,
                                           delta: Int) -> Bool {
        let cur = params(of: n1Based)
        let next = LayoutParams(masterRatio: cur.masterRatio,
                                masterCount: cur.masterCount + delta,
                                orientation: cur.orientation)
        layoutParams[n1Based] = next
        return next.masterCount != cur.masterCount
    }

    /// Flip the master axis (Tall ↔ Wide) for `n1Based`. Always
    /// changes, so returns `true`. Other knobs preserved.
    @discardableResult
    mutating func toggleMasterOrientation(workspace n1Based: Int) -> Bool {
        let cur = params(of: n1Based)
        let flipped: LayoutOrientation =
            cur.orientation == .vertical ? .horizontal : .vertical
        layoutParams[n1Based] = LayoutParams(masterRatio: cur.masterRatio,
                                             masterCount: cur.masterCount,
                                             orientation: flipped)
        return true
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
        previousActiveIndex = old
        let toPark = windowMap
            .filter { $0.value.workspace == old }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        let toRestore = windowMap
            .filter { $0.value.workspace == n1Based }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        return SwitchPlan(oldActive: old, newActive: n1Based,
                          toPark: toPark, toRestore: toRestore)
    }

    /// Resolve a relative workspace target to a concrete 1-based
    /// index, or nil when there's nowhere to go. `configured` is the
    /// ordered list of valid 1-based WS indices.
    ///   - `next` / `prev`: neighbour of `activeIndex` in `configured`,
    ///     wrapping at the ends; nil with fewer than 2 configured WSs.
    ///   - `recent`: `previousActiveIndex` when it's still configured,
    ///     else nil.
    func relativeTarget(_ target: RelativeWorkspace,
                               configured: [Int]) -> Int? {
        switch target {
        case .recent:
            guard let p = previousActiveIndex,
                  configured.contains(p) else { return nil }
            return p
        case .next, .prev:
            guard configured.count >= 2,
                  let pos = configured.firstIndex(of: activeIndex)
            else { return nil }
            let step = target == .next ? 1 : -1
            let n = (pos + step + configured.count) % configured.count
            return configured[n]
        }
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
        // `windowMap` is the authority on which windows facet
        // manages — drop anything else (the `.optionAll`
        // enumeration deliberately returns Cmd+H'd /
        // other-Space / minimized windows we never accepted as
        // entries, and falling those back to `activeIndex`
        // would pile them all into WS1).
        let tracked = live.filter { windowMap[$0.id] != nil }
        let byWS = Dictionary(grouping: tracked) { w in
            windowMap[w.id]!.workspace
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
            let engineF: [WindowID: CGRect] =
                LayoutRegistry.engine(named: m) != nil
                ? engineFrames(for: entry.index, in: activeRect)
                : [:]
            // Master = first in the WS's tiling order (order[0]). Used
            // by the right-click menu to vary master vs non-master.
            let master = orderedMembers(of: entry.index).first
            let wins = (byWS[entry.index] ?? []).map { w in
                Window(id: w.id, pid: w.pid, appName: w.appName,
                       title: w.title,
                       isFocused: w.id == focused,
                       isFloating: floatingWindows.contains(w.id),
                       frame: wouldBeFrame(
                           for: w, isActiveWS: isActive,
                           mode: m, tileFrames: tileF,
                           stackSet: stackSet,
                           engineFrames: engineF,
                           activeRect: activeRect),
                       isOnscreen: w.isOnscreen,
                       isMaster: w.id == master)
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
    /// it's been parked (a 1×41 corner sliver).
    private func wouldBeFrame(for w: Window,
                              isActiveWS: Bool,
                              mode m: String,
                              tileFrames: [WindowID: CGRect],
                              stackSet: Set<WindowID>,
                              engineFrames: [WindowID: CGRect],
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
            // Stateless layout engine (monocle, …): the frame the
            // window will occupy once its WS is active. Empty map →
            // float mode → fall back to the pre-park position.
            if !engineFrames.isEmpty {
                return engineFrames[w.id] ?? preParkFrame(for: w)
            }
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
