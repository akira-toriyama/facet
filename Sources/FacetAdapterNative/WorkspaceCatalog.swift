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
//   user-facing CLI (`facet workspace --focus N` is 1-indexed). The
//   `WindowBackend` protocol is 0-based on the wire, so
//   `NativeAdapter` translates at the seam (`index + 1` on entry,
//   `index - 1` on snapshot emit). Keeping the catalog 1-based
//   internally matches what the user sees in `facet query` and
//   `config.toml`'s `[desktop.N]` tables.
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
    /// 1-based workspace index. Always set (workspace-mode authority;
    /// in tag mode it's bookkeeping only — visibility comes from
    /// `tags`).
    let workspace: Int
    let pid: Int
    /// Tag bitmask (M11-3 `[grouping] by = "tag"`). `0` in workspace
    /// mode (unused) and for a window not yet tag-assigned. In tag mode
    /// a window always carries the `_default` floor
    /// (`TagModel.defaultBit`, bit 63) so it is never `0` / lost.
    /// Mutable: #191 runtime tagging (`facet window
    /// --tag`/`--untag`/`--toggle-tag`) rewrites it in place. Every
    /// `WindowSlot` re-creation must still carry this forward or a
    /// tag-mode window silently loses its tags.
    var tags: UInt64
    init(workspace: Int, pid: Int, tags: UInt64 = 0) {
        self.workspace = workspace
        self.pid = pid
        self.tags = tags
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
    //
    // Stored state lives ONLY here on the primary declaration — the
    // behaviour clusters were split into WorkspaceCatalog+*.swift
    // same-module extensions (#182 phase 2), which is why most setters
    // are plain `var` rather than `private(set)` (a cross-file
    // extension can't reach a `private(set)` setter). The state is
    // still catalog-internal by convention: NativeAdapter consumes
    // snapshots / plans and never writes these fields directly.

    /// The live, mutable workspace set — authority for membership,
    /// order, and names (replaces the config list that callers used to
    /// pass in). Position-based: array element `i` is workspace
    /// `i+1` (1-based, contiguous); the string is its display name
    /// (`""` = show the number). Seeded once from config via
    /// `seed(names:)`, then mutated by `add`/`remove`/`rename`/`move`
    /// (session-only — config stays the read-only seed, memory
    /// `facet-cli-dynamic-runtime-model`). Per mac desktop: each
    /// catalog owns its own set.
    private(set) var workspaceNames: [String] = []

    /// Number of live workspaces (= highest valid 1-based index).
    var workspaceCount: Int { workspaceNames.count }

    /// The live set as `(index, name)` pairs for `snapshot` / status.
    var workspaceEntries: [(index: Int, name: String)] {
        workspaceNames.enumerated().map {
            (index: $0.offset + 1, name: $0.element)
        }
    }

    /// 1-based index of the active workspace.
    private(set) var activeIndex: Int = 1

    /// 1-based index of the workspace that was active immediately
    /// before the current one, or nil before the first switch. Powers
    /// `workspace --focus recent`. Updated by `setActive` on every
    /// real transition; cleared to nil only at init.
    private(set) var previousActiveIndex: Int?

    /// Window → slot (workspace + pid). Survives across reconciles
    /// so a window the user moved stays where they put it; new
    /// windows land in `activeIndex` on the next reconcile.
    var windowMap: [WindowID: WindowSlot] = [:]

    // MARK: - Tag grouping state (M11-3, `by = "tag"`)

    /// Grouping paradigm. `.workspace` (default) keys visibility off
    /// `WindowSlot.workspace == activeIndex`; `.tag` keys it off
    /// `WindowSlot.tags & lens != 0`. Set once at `seedTags`, immutable
    /// for the session (config-static; change needs a restart).
    var grouping: Grouping = .workspace
    /// Tag vocabulary (declaration order = bit positions). Empty in
    /// workspace mode. Seeded from `[[tag]]`, then mutated at runtime by
    /// `facet tag --add/--remove/--rename` (#191).
    var tagModel = TagModel([])
    /// Current lens = the visible tag mask (tag mode). Seeded to the
    /// `_default` floor (show-all, nothing pre-selected); mutated by
    /// `setLens`. `0` in workspace mode.
    var lens: UInt64 = 0

    /// Windows currently parked at the bottom-right anchor sliver.
    /// `markAnchorParked` populates; `consumeAnchorRestore` clears.
    /// The adapter checks `shouldParkAnchor` before invoking AX so
    /// a poll-driven refresh can't re-park on top of a park.
    var anchorParked: Set<WindowID> = []

    /// Position the window held before facet parked it at the
    /// anchor sliver. Recorded at park time, consumed at restore
    /// time.
    var originalPositions: [WindowID: CGPoint] = [:]

    /// Per-WS layout mode. Missing entries default to `"float"`
    /// (Phase γ frozen decision: existing users see no surprise
    /// behaviour on upgrade). Valid values: `"float"` / `"bsp"`
    /// / `"stack"`.
    var layoutModes: [Int: String] = [:]

    /// Mode a WS uses when it has no explicit `layoutModes` entry.
    /// Seeded from `[layout] default` (config) by the adapter on
    /// every refresh; `"float"` (Phase γ frozen default) until set.
    /// Layout mode is otherwise session-only, so this is what a
    /// fresh launch / per-mac-desktop catalog starts every WS in.
    /// (Moved up from the Layout-mode cluster — extensions can't hold
    /// stored state; behaviour lives in WorkspaceCatalog+Layout.swift.)
    var defaultMode: String = "float"

    /// Per-WS BSP tree. Only present for WSs in `"bsp"` mode;
    /// other modes have no entry. Tree IDs are kept in sync with
    /// `windowMap` by `reconcile` / `moveWindow` / `drop` and by
    /// the explicit `setMode` migration path.
    var layoutTrees: [Int: LayoutTree] = [:]

    /// Per-WS window order, shared by `"stack"` mode and the
    /// stateless `LayoutEngine`s (master-* / grid / spiral). Index 0 is
    /// the master / visible-top: in stack it's the single window
    /// that fills the display (the rest parked at the anchor sliver);
    /// in a master layout it's the primary master. A new window lands at index 0
    /// in stack (so you see what you just opened) but APPENDS in the
    /// stateless engines (so it joins the stack without seizing the
    /// master — see `attachToLayout`); `cycleStack` rotates the array
    /// and `promoteToMaster` moves a chosen window to index 0. Absent
    /// for bsp (uses `layoutTrees`) and float (no managed order).
    var stackOrders: [Int: [WindowID]] = [:]

    /// Per-WS layout knobs (master ratio / master count) for the
    /// stateless engines that read them (the master-* engines).
    /// Runtime-only — never persisted to config (Theme B decision).
    /// Missing entry → `LayoutParams()` defaults. Kept across mode
    /// flips so a WS remembers its ratio when you toggle away and
    /// back.
    var layoutParams: [Int: LayoutParams] = [:]

    /// Windows the user (or AX role detector) flagged as floating.
    /// Floating windows are skipped by the tiler and stay at the
    /// user's last-set position. Independent of `anchorParked`
    /// (which is hide state, not a per-window opt-out).
    var floatingWindows: Set<WindowID> = []

    /// Per-WS snapshot of which window was focused at the moment
    /// the user left that WS. Written by `recordLeaveFocus`
    /// (called unconditionally on every `switchWorkspace`),
    /// consumed by `autoFocusTarget` when a no-pick switch lands
    /// on this WS — restores the user back to the same window
    /// they were on. Cleared when the recorded window is closed
    /// or moved to a different WS, so a stale entry can't pin
    /// focus to a now-missing window.
    var lastFocusedOnLeave: [Int: WindowID] = [:]

    /// User-assigned window marks (`facet window --mark NAME`), a 1:1
    /// bijection between mark name and window: each name maps to one
    /// window and each window carries at most one name. Setting a name
    /// reassigns it (the old window loses it) and clears any prior mark
    /// on the target window. Session-only and per-mac-desktop (this
    /// catalog is swapped per mac desktop). Pruned in `forgetWindow` when a
    /// window closes. Keyed by name → `WindowID`; stable across WS
    /// reorder (WindowID is the window-server id), so no remap needed.
    var marks: [String: WindowID] = [:]

    /// Sticky windows (`facet window --toggle-sticky`): pinned visible
    /// across **every facet workspace in this mac desktop**. Two
    /// invariants give the behaviour almost for free:
    ///   1. **Park-exempt** — `shouldParkAnchor` returns false for a
    ///      sticky id, so a WS switch never sweeps it to the anchor
    ///      sliver (it stays exactly on-screen, on every WS).
    ///   2. **Force-floating** — a sticky id is also in
    ///      `floatingWindows`, so it never joins a WS's tiling (a tiled
    ///      window that reflows per-WS can't also stay put everywhere).
    /// Mac-desktop crossing is out of scope (READ-only SkyLight, memory
    /// `facet-per-native-space-ws`) — that's macOS's "all desktops"
    /// job. Session-only, per-mac-desktop (this catalog is swapped per
    /// mac desktop). Pruned in `forgetWindow` on close. Orthogonal to `marks`
    /// (a window can carry both).
    var everywhereWindows: Set<WindowID> = []

    /// Named scratchpad shelves (`facet scratchpad --stash NAME`): a
    /// 1:1 bijection name ⇄ window, like `marks`, but the window is
    /// parked off-screen (anchor sliver) while *stashed*. Summoning
    /// re-homes it onto the current WS as a floating overlay (settle).
    /// Session-only, per-mac-desktop (this catalog is swapped per
    /// mac desktop); pruned in `forgetWindow`. Mutually exclusive with sticky
    /// (`stashWindow` clears sticky; `setSticky` clears the shelf).
    var scratchpads: [String: WindowID] = [:]

    /// Subset of `scratchpads` values that are currently *stashed*
    /// (hidden on the shelf), as opposed to *settled* (summoned, on a
    /// WS). `anchorParked` alone can't tell "parked because shelved"
    /// from "parked because its WS isn't active": a stashed window must
    /// stay parked through every WS switch, so `setActive` /
    /// `resyncVisibleState` skip it explicitly via this set. A settled
    /// scratchpad window is in `scratchpads` but NOT here, so it parks /
    /// restores like any normal floating window.
    var stashedWindows: Set<WindowID> = []

    /// IDs that have been observed `isOnscreen=true` once but not
    /// yet committed to `windowMap`. Reconcile requires **two
    /// consecutive on-screen observations** before adding so a
    /// transient cross-mac-desktop visibility flip during a macOS
    /// mac-desktop switch animation doesn't get mistaken for a genuine
    /// new window. Cleared when the window goes off-screen, the
    /// catalog leaves the mac desktop, or the window enters
    /// `windowMap` for real. See memory
    /// `facet-macos-spaces-coexistence`.
    var pendingAddCandidates: Set<WindowID> = []

    /// IDs reconcile has decided NOT to auto-manage on a later
    /// `isOnscreen` flip. Populated two ways:
    ///   1. **Bulk-marked as pre-existing** via `markPreExisting`
    ///      — called at startup with the initial enumeration and
    ///      on every `activeSpaceDidChange` with the post-switch
    ///      enumeration. Every CGWindowList ID at that moment is
    ///      flagged, so a window already alive when facet (or the
    ///      mac-desktop change) appeared can never grab a slot in
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
    var examinedIDs: Set<WindowID> = []

    /// Windows the user hid (Cmd+H) or minimized (Cmd+M): kept in
    /// `windowMap` (their WS assignment + marks survive) but detached
    /// from the layout containers so the remaining tiled windows
    /// reclaim the freed slot. `nonFloatingMembers` excludes them, so
    /// every stateless engine and the bsp re-seed skip them; the bsp
    /// tree node itself is removed by `detachFromLayouts`. Re-attached
    /// at the tail by `reconcileHidden` when the window returns
    /// on-screen. facet's own parking uses the on-screen anchor sliver
    /// (`isOnscreen` stays true), so it never lands a window here —
    /// only a user hide / minimize does. See memory
    /// `facet-hide-reclaim-decisions`.
    var hiddenMembers: Set<WindowID> = []

    /// Managed windows seen `isOnscreen=false` once but not yet
    /// reclaimed. Mirrors `pendingAddCandidates`: a window must read
    /// off-screen on TWO consecutive reconciles before `reconcileHidden`
    /// pulls its slot, so the transient off-screen flip during a
    /// mac-desktop switch animation isn't mistaken for a user Cmd+H /
    /// minimize. Cleared when the window comes back on-screen or is
    /// forgotten.
    var pendingHideCandidates: Set<WindowID> = []

    init() {}

    // MARK: - Dynamic workspace set (seed + mutate)

    /// Seed the live set from config, once, at catalog creation.
    /// Compacts to contiguous positions: a sparse config (`1`, `3`,
    /// `5`) becomes positions 1/2/3 keeping names in index order. The
    /// dynamic model is position-based and contiguous, so sparsity
    /// can't survive — names are the stable handle now. No-op once
    /// seeded (the set is then authoritative; config is just the
    /// seed). Falls back to one unnamed workspace if `entries` empty.
    ///
    /// Per-WS layout is seeded too when the entry's
    /// `WorkspaceConfig.layout` is non-nil: the catalog records it
    /// at the compacted position so the first `mode(of:)` returns
    /// the configured value. Runtime `setMode` can still override
    /// for the session (Q7 seed-only semantics).
    mutating func seed(configs entries: [(index: Int, config: WorkspaceConfig)]) {
        guard workspaceNames.isEmpty else { return }
        let sorted = entries.sorted { $0.index < $1.index }
        workspaceNames = sorted.isEmpty ? [""] : sorted.map(\.config.name)
        if activeIndex > workspaceNames.count { activeIndex = 1 }
        for (pos, e) in sorted.enumerated() {
            if let layout = e.config.layout {
                layoutModes[pos + 1] = layout
            }
        }
    }

    /// 1-based position of the first workspace named `name`, or nil.
    /// Empty `name` never matches (it's the "show the number"
    /// sentinel, not a real label).
    func index(ofName name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        return workspaceNames.firstIndex(of: name).map { $0 + 1 }
    }

    /// Append a new empty workspace; returns its 1-based position.
    @discardableResult
    mutating func addWorkspace() -> Int {
        workspaceNames.append("")
        return workspaceNames.count
    }

    /// Rename the workspace at `n1Based`. No-op for an invalid position.
    mutating func renameWorkspace(_ n1Based: Int, to name: String) {
        guard n1Based >= 1, n1Based <= workspaceNames.count else { return }
        workspaceNames[n1Based - 1] = name
    }

    /// Remove the workspace at `n1Based`. Its windows evacuate to a
    /// neighbour (P-1, or P+1 when removing the first) so nothing is
    /// lost; positions above shift down by one. No-op when only one
    /// workspace remains. `rect` rebuilds the neighbour's layout
    /// container after it absorbs the evacuees. Returns true on
    /// success.
    @discardableResult
    mutating func removeWorkspace(_ n1Based: Int, in rect: CGRect = .zero)
        -> Bool
    {
        let n = workspaceNames.count
        guard n > 1, n1Based >= 1, n1Based <= n else { return false }
        let neighbour = n1Based > 1 ? n1Based - 1 : 2      // old numbering
        // Evacuate windows P -> neighbour (old numbering).
        for (id, slot) in windowMap where slot.workspace == n1Based {
            windowMap[id] = WindowSlot(workspace: neighbour, pid: slot.pid,
                                       tags: slot.tags)
            clearLeaveFocus(of: id)
        }
        // Active / recent follow the evacuated windows.
        if activeIndex == n1Based { activeIndex = neighbour }
        if previousActiveIndex == n1Based { previousActiveIndex = neighbour }
        // Drop P from the name list, then shift positions > P down by
        // one across every index-keyed structure (P's own state is
        // discarded — its windows already moved out).
        workspaceNames.remove(at: n1Based - 1)
        var map: [Int: Int] = [:]
        for pos in 1...n where pos != n1Based {
            map[pos] = pos < n1Based ? pos : pos - 1
        }
        remapIndices(map)
        // Rebuild the neighbour's container from its now-larger member
        // set so absorbed windows tile correctly.
        let neighbourNew = neighbour < n1Based ? neighbour : neighbour - 1
        _ = setMode(workspace: neighbourNew,
                    to: mode(of: neighbourNew), in: rect)
        return true
    }

    /// Move the active workspace to 1-based `target` (reorder). No-op
    /// for an out-of-range or unchanged target. Each workspace keeps
    /// its windows + layout; only the position numbers change.
    @discardableResult
    mutating func moveActiveWorkspace(to target: Int) -> Bool {
        let n = workspaceNames.count
        let from = activeIndex
        guard target >= 1, target <= n, target != from else { return false }
        let moved = workspaceNames.remove(at: from - 1)
        workspaceNames.insert(moved, at: target - 1)
        // Permutation. Moving `from` -> `target`:
        //   from < target: positions (from, target] shift down by 1.
        //   from > target: positions [target, from) shift up by 1.
        var map: [Int: Int] = [from: target]
        if from < target {
            for pos in (from + 1)...target { map[pos] = pos - 1 }
        } else {
            for pos in target...(from - 1) { map[pos] = pos + 1 }
        }
        for pos in 1...n where map[pos] == nil { map[pos] = pos }
        remapIndices(map)
        return true
    }

    /// Re-key every index-keyed structure (per-WS dicts + windowMap
    /// slots + active / previous) by `map` (oldPos -> newPos).
    /// Positions absent from `map` are dropped; `map`'s values must be
    /// unique (a permutation of the surviving positions).
    private mutating func remapIndices(_ map: [Int: Int]) {
        func remap<V>(_ d: [Int: V]) -> [Int: V] {
            var out: [Int: V] = [:]
            for (k, v) in d where map[k] != nil { out[map[k]!] = v }
            return out
        }
        layoutModes = remap(layoutModes)
        layoutTrees = remap(layoutTrees)
        stackOrders = remap(stackOrders)
        layoutParams = remap(layoutParams)
        lastFocusedOnLeave = remap(lastFocusedOnLeave)
        for (id, slot) in windowMap where map[slot.workspace] != nil {
            windowMap[id] = WindowSlot(workspace: map[slot.workspace]!,
                                       pid: slot.pid, tags: slot.tags)
        }
        activeIndex = map[activeIndex]
            ?? min(activeIndex, max(1, workspaceNames.count))
        previousActiveIndex = previousActiveIndex.flatMap { map[$0] }
    }

    // MARK: - Validation

    /// True when `n1Based` is a live workspace position (contiguous
    /// 1...count). The dynamic set is the authority (memory
    /// `facet-cli-dynamic-runtime-model`).
    func isValid(_ n1Based: Int) -> Bool {
        n1Based >= 1 && n1Based <= workspaceNames.count
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
    mutating func setActive(_ n1Based: Int) -> SwitchPlan? {
        guard isValid(n1Based), n1Based != activeIndex else { return nil }
        let old = activeIndex
        activeIndex = n1Based
        previousActiveIndex = old
        // Sticky windows stay on-screen across the switch (they're
        // park-exempt via `shouldParkAnchor`), so leave them out of both
        // lists entirely — keeps the adapter's park/restore counts
        // honest and skips the pointless guarded calls. Stashed
        // scratchpad windows are the mirror image: already parked on the
        // shelf and must STAY parked through the switch, so they're
        // excluded too (restoring one when its home WS activates would
        // un-hide the shelf).
        let toPark = windowMap
            .filter { $0.value.workspace == old
                && !everywhereWindows.contains($0.key)
                && !stashedWindows.contains($0.key) }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        let toRestore = windowMap
            .filter { $0.value.workspace == n1Based
                && !everywhereWindows.contains($0.key)
                && !stashedWindows.contains($0.key) }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        return SwitchPlan(oldActive: old, newActive: n1Based,
                          toPark: toPark, toRestore: toRestore)
    }

    /// Resolve a relative workspace target to a concrete 1-based
    /// index over the live (contiguous 1...count) set, or nil when
    /// there's nowhere to go.
    ///   - `next` / `prev`: neighbour of `activeIndex`, wrapping at the
    ///     ends; nil with fewer than 2 workspaces.
    ///   - `recent`: `previousActiveIndex` when it's still valid.
    func relativeTarget(_ target: RelativeWorkspace) -> Int? {
        let count = workspaceNames.count
        switch target {
        case .recent:
            guard let p = previousActiveIndex, isValid(p) else { return nil }
            return p
        case .next, .prev:
            guard count >= 2, isValid(activeIndex) else { return nil }
            let step = target == .next ? 1 : -1
            let n = (activeIndex - 1 + step + count) % count
            return n + 1
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
                                    in rect: CGRect = .zero) -> MoveOutcome {
        // A sticky window is a member of *every* WS in this mac desktop, so
        // "move it to WS N" is incoherent — reject it (unstick first).
        // Without this guard the slot would change but `attachToLayout`
        // skips floating windows and `clearSticky` re-homes to the
        // active WS anyway, so the move would be a silent no-op that
        // only relocated the tree badge.
        // A stashed scratchpad window lives off-screen on a named shelf,
        // not on any visible WS, so "move it to WS N" is incoherent —
        // reject it (release or summon first). A *settled* scratchpad
        // window is a normal floating window and moves fine.
        guard isValid(n1Based),
              let current = windowMap[id],
              current.workspace != n1Based,
              !everywhereWindows.contains(id),
              !stashedWindows.contains(id) else { return .rejected }
        windowMap[id] = WindowSlot(workspace: n1Based, pid: current.pid,
                                   tags: current.tags)
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
    /// isn't already parked, and isn't sticky). Caller uses this as
    /// the early-exit guard before invoking AX. This is the single
    /// chokepoint that makes sticky windows stay on-screen across WS
    /// switches: every park path (`parkAnchor`, `animateSwitch`'s
    /// outgoing slide, `applyStack`'s non-top members) gates on it, so
    /// a sticky id is never swept to the anchor sliver.
    func shouldParkAnchor(_ id: WindowID) -> Bool {
        !anchorParked.contains(id) && !everywhereWindows.contains(id)
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
                         activeRect: CGRect)
        -> [Workspace]
    {
        if grouping == .tag {
            return tagSnapshot(live: live, focused: focused,
                               activeRect: activeRect)
        }
        // Group raw live windows by WS first so per-WS layout
        // queries (tiledFrames / stackOrders) only run once.
        // `windowMap` is the authority on which windows facet
        // manages — drop anything else (the `.optionAll`
        // enumeration deliberately returns Cmd+H'd /
        // other-mac-desktop / minimized windows we never accepted as
        // entries, and falling those back to `activeIndex`
        // would pile them all into WS1).
        // Stashed scratchpad windows stay in `windowMap` (so their WS
        // assignment + shelf survive) but must be invisible to the
        // views: drop them here so they appear in neither the tree nor
        // a WS's window count. They surface only via `facet query`'s
        // `stashed:` line. A *settled* (summoned) scratchpad window is
        // NOT in `stashedWindows`, so it stays and carries its badge.
        let tracked = live.filter {
            windowMap[$0.id] != nil && !stashedWindows.contains($0.id)
        }
        let byWS = Dictionary(grouping: tracked) { w in
            windowMap[w.id]!.workspace
        }
        return workspaceEntries.map { entry in
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
            // Master = first in the WS's tiling order (order[0]) —
            // consumed by the right-click menu's master-aware
            // actions AND the tree's right-edge `master` chip. Only
            // the master-stack engines (master-*) have a
            // real master; bsp / stack / float keep their stateful
            // adapter paths (absent from the registry) and grid /
            // spiral tile co-equally (`hasMaster == false`), so all of
            // them report no master — a chip there would be a lie. The
            // engine declares its own master-ness via `hasMaster`.
            let hasMasterSlot =
                LayoutRegistry.engine(named: m)?.hasMaster ?? false
            let master = hasMasterSlot
                ? orderedMembers(of: entry.index).first
                : nil
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
                       isMaster: w.id == master,
                       mark: mark(forWindow: w.id),
                       isSticky: everywhereWindows.contains(w.id),
                       scratchpad: scratchpad(forWindow: w.id))
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
            // Stateless layout engine (master-* / grid / spiral): the
            // frame the window will occupy once its WS is active. Empty map →
            // float mode → fall back to the pre-park position.
            if !engineFrames.isEmpty {
                return engineFrames[w.id] ?? preParkFrame(for: w)
            }
            return preParkFrame(for: w)
        }
    }

    func preParkFrame(for w: Window) -> CGRect? {
        if let origin = originalPositions[w.id], let size = w.frame?.size {
            return CGRect(origin: origin, size: size)
        }
        return w.frame
    }
}
