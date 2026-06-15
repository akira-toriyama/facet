// Tag mode (M11-3, `by = "tag"`) — tag seeding, lens plans, tag snapshots.
// Extracted unchanged from WorkspaceCatalog.swift (#182 phase 2) —
// same-module extension, no logic change. Stored state stays on the
// primary declaration (WorkspaceCatalog.swift).

import CoreGraphics
import FacetCore

extension WorkspaceCatalog {

    // MARK: - Tag mode (M11-3, `by = "tag"`)

    /// Seed the tag grouping state once at startup (mirrors `seed` for
    /// workspace names). Idempotent-ish: only meaningful before any
    /// window is assigned. `lens` is normally `TagModel.defaultBit`
    /// (the floor — show-all at startup).
    mutating func seedTags(grouping: Grouping, model: TagModel,
                           lens: UInt64) {
        // Seed once. `grouping` starts `.workspace` (the default); the
        // first seed flips it to `.tag`. A later refresh calling this
        // again would otherwise reset `lens` to the seed value on every
        // poll, clobbering the user's `setLens` changes.
        guard self.grouping == .workspace, grouping != .workspace else {
            return
        }
        self.grouping = grouping
        self.tagModel = model
        self.lens = lens
    }

    /// Tag bitmask for a newly-appeared window (tag mode). A fresh
    /// window inherits the current lens's PRIMARY tag (its lowest set
    /// bit) so it lands in exactly one visible place — never the whole
    /// lens union (a broad `--all` lens shouldn't freeze every tag onto
    /// a new window). Always carries the `_default` floor
    /// (`TagModel.defaultBit`) so the window is never `0` / lost (#191).
    /// At startup the lens IS the floor alone, so a window opened before
    /// any lens switch is floor-only (untagged) until the user tags it
    /// via `facet window --tag`. (There is no static `[[assign]]` —
    /// retired in #191; runtime tagging is the only path.)
    func tagsForNewWindow() -> UInt64 {
        let base: UInt64
        if lens != 0 {
            base = UInt64(1) << UInt64(lens.trailingZeroBitCount)
        } else {
            base = tagModel.firstBit ?? 0
        }
        return base | TagModel.defaultBit
    }

    /// Non-floating, non-hidden windows visible under the current lens
    /// — the union to tile in tag mode. One global member set (no
    /// per-workspace split), same stable serverID order as the
    /// workspace-mode `nonFloatingMembers`.
    func visibleNonFloatingMembers() -> [WindowID] {
        windowMap
            .filter { ($0.value.tags & lens) != 0
                && !floatingWindows.contains($0.key)
                && !hiddenMembers.contains($0.key) }
            .map(\.key)
            .sorted { $0.serverID < $1.serverID }
    }

    /// Tiled frames for the visible lens-union, computed by the global
    /// default engine (tag mode has one layout over the union, not a
    /// per-workspace tree). Empty when the default mode isn't a
    /// stateless engine — `float` (windows keep position) and the
    /// workspace-only `bsp`/`stack` (forbidden in tag mode by config
    /// validation, but be defensive) all fall through to empty.
    func tagUnionFrames(in rect: CGRect) -> [WindowID: CGRect] {
        guard let engine = LayoutRegistry.engine(named: effectiveTagLayout)
        else { return [:] }
        return engine.frames(order: visibleNonFloatingMembers(),
                             focused: nil, params: LayoutParams(), in: rect)
    }

    /// Tag-mode snapshot: ONE synthetic `Workspace` holding every tracked
    /// window as a flat list — no per-tag grouping (#191 PR-6). Each
    /// window appears once and carries ALL its tag names; the tree renders
    /// them as `#tag` chips on the row (the view's `tagMode` flag drops the
    /// workspace header so the list reads flat). This is the full-tag-world
    /// overview, independent of the lens: the tiled set is the lens union
    /// (one global layout), but parked (out-of-lens) windows still appear,
    /// shown at their pre-park position. Returns `[]` when no window is
    /// tracked so the panel hides (the Controller's empty-list guard)
    /// rather than show an empty frame.
    func tagSnapshot(live: [Window], focused: WindowID?,
                             activeRect: CGRect) -> [Workspace] {
        let tracked = live.filter {
            windowMap[$0.id] != nil && !stashedWindows.contains($0.id)
        }
        guard !tracked.isEmpty else { return [] }
        let unionFrames = tagUnionFrames(in: activeRect)
        // Master badge parity with workspace mode: when the tag-world's
        // engine has a master slot, the master is the first tiled member
        // (same rule as WorkspaceCatalog.snapshot). nil for float / non-
        // master engines so a `[master]` chip is never a lie.
        let masterID: WindowID? =
            (LayoutRegistry.engine(named: effectiveTagLayout)?.hasMaster ?? false)
            ? visibleNonFloatingMembers().first : nil
        let wins = tracked
            .sorted { $0.id.serverID < $1.id.serverID }
            .map { w -> Window in
                let mask = windowMap[w.id]?.tags ?? 0
                let floating = floatingWindows.contains(w.id)
                let inLens = (mask & lens) != 0
                // A floating window in the lens is on-screen at its OWN
                // position (it isn't tiled) — show its live frame, like
                // workspace mode does for active-WS floats. A tiled window
                // in the lens gets its union slot. Anything out of the lens
                // is parked → its pre-park position.
                let frame: CGRect?
                if floating {
                    frame = inLens ? w.frame : preParkFrame(for: w)
                } else if inLens {
                    frame = unionFrames[w.id] ?? preParkFrame(for: w)
                } else {
                    frame = preParkFrame(for: w)
                }
                return Window(id: w.id, pid: w.pid, appName: w.appName,
                              title: w.title,
                              isFocused: w.id == focused,
                              isFloating: floating,
                              frame: frame,
                              isOnscreen: w.isOnscreen,
                              isMaster: w.id == masterID,
                              mark: mark(forWindow: w.id),
                              isSticky: everywhereWindows.contains(w.id),
                              scratchpad: scratchpad(forWindow: w.id),
                              tags: tagModel.names(in: mask))
            }
        // One synthetic, always-active workspace (index 0). `isActive`
        // keeps the lone "workspace" current so a row click never fires a
        // spurious workspace switch; `layoutMode` is the tag-world's global
        // engine (`effectiveTagLayout`) — feeds the tree's tag-world header
        // layout picker (checkmark) + the window context menu's mode-gating.
        // `name` is the active lens label (the currently shown tags, else
        // `all` for the floor / empty lens) — the tag-world header text.
        let lensNames = tagModel.names(in: lens)
        // `#`-prefixed, lowercase, space-separated (item 14) — the canonical
        // tag spelling used by the per-row chips + the TagEditPanel checklist,
        // so the tag-world header reads as the same `#web` the rest of the UI
        // shows. Both the empty (floor) lens AND the every-tag lens show
        // everything, so both read `All tags` (item 15) rather than a bare
        // `all` / the full tag list; a real subset shows its `#tag`s.
        let allUserNames = Set(tagModel.names(in: lensAll))
        let label: String
        if lensNames.isEmpty || Set(lensNames) == allUserNames {
            label = "All tags"
        } else {
            label = lensNames.map { "#\($0)" }.joined(separator: " ")
        }
        return [Workspace(index: 0, name: label, isActive: true,
                          layoutMode: effectiveTagLayout, windows: wins)]
    }

    // Lens-command resolvers (pure: names → new mask, #228 multi-tag).
    // `nil` = at least one undefined name — STRICT, the whole command
    // rejects (caller surfaces lastError, makes no change; no silent
    // drop). User verbs operate on USER bits only: the `_default` floor
    // is stripped here and re-introduced by `setLens` as the empty-lens
    // sentinel, so it never leaks into a user-chosen lens (`--add code`
    // from the floor-only lens = exactly `{code}`).
    func lensOnly(_ names: [String]) -> UInt64? { lensMaskStrict(names) }
    func lensAdded(_ names: [String]) -> UInt64? {
        lensMaskStrict(names).map { (lens | $0) & ~TagModel.defaultBit }
    }
    func lensRemoved(_ names: [String]) -> UInt64? {
        lensMaskStrict(names).map { (lens & ~$0) & ~TagModel.defaultBit }
    }
    func lensToggled(_ names: [String]) -> UInt64? {
        lensMaskStrict(names).map { (lens ^ $0) & ~TagModel.defaultBit }
    }

    /// Strict union of the bits for `names` (user tags only) — `nil` when
    /// ANY name is undefined, so a lens command with one typo changes
    /// nothing rather than silently dropping the bad name. `bit(for:)`
    /// never returns the floor (it isn't in the vocabulary), so the
    /// result carries user bits only.
    private func lensMaskStrict(_ names: [String]) -> UInt64? {
        var mask: UInt64 = 0
        for n in names {
            guard let b = tagModel.bit(for: n) else { return nil }
            mask |= b
        }
        return mask
    }

    /// `lens --all` — every user tag PLUS the `_default` floor, so the
    /// "show everything" lens also reveals windows that carry only the
    /// floor (no user tag). User-only `allMask` would park those (#191).
    var lensAll: UInt64 { tagModel.allMask | TagModel.defaultBit }

    // MARK: - Runtime window tagging (#191, tag mode)

    /// How a single-window retag changed its lens visibility, so the
    /// adapter can park / restore exactly that one window (the
    /// single-window analog of `LensPlan`). Sticky (`everywhere`) and
    /// stashed-scratchpad windows are never parked, so they always
    /// report `.unchanged`.
    enum RetagVisibility: Equatable, Sendable {
        case unchanged
        case park       // was in the lens union, now out
        case restore    // was out of the lens union, now in
    }

    /// Add `name` to the session tag vocabulary if absent and return
    /// its bit; returns the existing bit when already defined. `nil`
    /// when the vocabulary is full (63 user tags) or `name` is the
    /// reserved `_default`. Reuses a freed bit (a hole left by a
    /// `tag --remove`) before appending — the free-list lives in
    /// `TagModel.add`. The auto-vivify primitive shared by
    /// `window --tag`/`--toggle-tag` and `tag --add`. The CLI parser
    /// already rejects malformed names.
    @discardableResult
    mutating func addTagName(_ name: String) -> UInt64? {
        tagModel.add(name)
    }

    /// Add tag `name` to window `id`, auto-vivifying an unknown name.
    /// Keeps the `_default` floor. `nil` when the window isn't tracked
    /// or the vocabulary is full; otherwise the visibility transition
    /// the adapter should apply.
    mutating func addTagToWindow(_ id: WindowID,
                                 name: String) -> RetagVisibility? {
        guard var slot = windowMap[id] else { return nil }
        guard let bit = addTagName(name) else { return nil }
        let old = slot.tags
        slot.tags = old | bit | TagModel.defaultBit
        windowMap[id] = slot
        return retagVisibility(id, old: old, new: slot.tags)
    }

    /// Remove tag `name` from window `id`. Strict — rejects an unknown
    /// or reserved name (`nil`), unlike the auto-vivifying add. The
    /// `_default` floor is never removed. `nil` also when the window
    /// isn't tracked.
    mutating func removeTagFromWindow(_ id: WindowID,
                                      name: String) -> RetagVisibility? {
        guard var slot = windowMap[id] else { return nil }
        guard name != TagModel.defaultName,
              let bit = tagModel.bit(for: name) else { return nil }
        let old = slot.tags
        slot.tags = (old & ~bit) | TagModel.defaultBit
        windowMap[id] = slot
        return retagVisibility(id, old: old, new: slot.tags)
    }

    /// Toggle tag `name` on window `id`, auto-vivifying an unknown
    /// name. Keeps the `_default` floor (the toggled bit is never the
    /// floor — `addTagName` rejects `_default`). `nil` as `addTag…`.
    mutating func toggleTagOnWindow(_ id: WindowID,
                                    name: String) -> RetagVisibility? {
        guard var slot = windowMap[id] else { return nil }
        guard let bit = addTagName(name) else { return nil }
        let old = slot.tags
        slot.tags = (old ^ bit) | TagModel.defaultBit
        windowMap[id] = slot
        return retagVisibility(id, old: old, new: slot.tags)
    }

    /// Outcome of a single-window `retag` (`facet window --retag OLD NEW`,
    /// #228). A 4-way result rather than a `Bool` so the adapter can
    /// surface a precise error — `RenameOutcome` is the sibling pattern
    /// for the vocabulary `rename`.
    enum RetagOutcome: Equatable, Sendable {
        /// Retagged — carries the lens-visibility transition to apply.
        case retagged(RetagVisibility)
        /// `id` isn't tracked (no focused / managed window).
        case noWindow
        /// `old` isn't a defined tag — Strict-A reject (consistent with
        /// `--untag`), so a typo never silently degrades to a bare add.
        case oldUndefined
        /// `new` would auto-vivify but the vocabulary is full (63 tags).
        case vocabFull
    }

    /// Retag window `id`: replace tag `old` with `new` in a SINGLE atomic
    /// mask write — `(tags & ~oldBit) | newBit | floor` (`facet window
    /// --retag`, #228). One `windowMap[id] = slot` (not untag-then-tag,
    /// which would flash park→restore and retile twice). Semantics:
    ///   - `old` must be DEFINED — Strict-A (`.oldUndefined` otherwise),
    ///     so `bit(for: old)` is read BEFORE `addTagName(new)` and a
    ///     rejected retag never pollutes the vocabulary with `new`.
    ///   - a window that lacks `old` (but `old` is defined) degrades to a
    ///     bare add of `new` (the `& ~oldBit` is a no-op on its mask).
    ///   - `new` auto-vivifies (`.vocabFull` at the 63-tag cap).
    ///   - `old == new` is a success: ensures the bit is set (a no-op
    ///     when already present), mirroring `rename`'s `old == new`.
    /// The floor is always kept, so the window is never `0` / lost.
    mutating func retagWindow(_ id: WindowID,
                              old: String, new: String) -> RetagOutcome {
        guard var slot = windowMap[id] else { return .noWindow }
        // Guard order is load-bearing: the pure `bit(for: old)` read must
        // precede the mutating `addTagName(new)`, so a Strict-A reject of
        // an undefined `old` leaves the vocabulary untouched.
        guard let oldBit = tagModel.bit(for: old) else { return .oldUndefined }
        guard let newBit = addTagName(new) else { return .vocabFull }
        let prev = slot.tags
        slot.tags = (prev & ~oldBit) | newBit | TagModel.defaultBit
        windowMap[id] = slot
        return .retagged(retagVisibility(id, old: prev, new: slot.tags))
    }

    // MARK: - Runtime tag vocabulary (#191, tag mode — `facet tag`)

    /// Remove tag `name` from the vocabulary AND strip its bit from
    /// every window (`facet tag --remove`). The freed bit becomes
    /// reusable (the hole stays in `tagModel` until a later `add`
    /// reclaims it); each window keeps the `_default` floor. The bit is
    /// also cleared from the current lens so a future tag reusing it
    /// doesn't inherit stale visibility; if that empties the lens it
    /// falls back to the floor (show-all) so windows don't vanish
    /// wholesale. Returns the park/restore plan for windows whose lens
    /// visibility flipped (the mask + lens change combined), or `nil`
    /// when not in tag mode or `name` is unknown / reserved.
    mutating func removeTagName(_ name: String) -> LensPlan? {
        guard grouping == .tag, let bit = tagModel.remove(name) else {
            return nil
        }
        let oldLens = lens
        let wasShown = windowMap.mapValues { ($0.tags & oldLens) != 0 }
        windowMap = windowMap.mapValues { slot in
            guard (slot.tags & bit) != 0 else { return slot }
            var s = slot
            s.tags = (s.tags & ~bit) | TagModel.defaultBit
            return s
        }
        var newLens = oldLens & ~bit
        if newLens == 0 { newLens = TagModel.defaultBit }
        lens = newLens
        var toPark: [WindowRef] = []
        var toRestore: [WindowRef] = []
        for (id, slot) in windowMap {
            if everywhereWindows.contains(id)
                || stashedWindows.contains(id) { continue }
            let was = wasShown[id] ?? false
            let now = (slot.tags & newLens) != 0
            if was && !now {
                toPark.append(WindowRef(id: id, pid: slot.pid))
            } else if !was && now {
                toRestore.append(WindowRef(id: id, pid: slot.pid))
            }
        }
        return LensPlan(oldLens: oldLens, newLens: newLens,
                        toPark: toPark, toRestore: toRestore)
    }

    /// Rename tag `old` to `new` in place (`facet tag --rename`) — the
    /// bit is unchanged, so no window mask or lens edit is needed (pure
    /// vocabulary change). Returns the outcome so the adapter can
    /// surface a precise reject.
    mutating func renameTagName(_ old: String,
                                to new: String) -> TagModel.RenameOutcome {
        guard grouping == .tag else { return .unknownOld }
        return tagModel.rename(old, to: new)
    }

    /// The lens-visibility transition between two tag masks for one
    /// window — mirrors `setLens`'s park/restore filter (sticky and
    /// stashed windows are never parked).
    private func retagVisibility(_ id: WindowID,
                                 old: UInt64, new: UInt64) -> RetagVisibility {
        if everywhereWindows.contains(id) || stashedWindows.contains(id) {
            return .unchanged
        }
        let wasShown = (old & lens) != 0
        let nowShown = (new & lens) != 0
        if wasShown && !nowShown { return .park }
        if !wasShown && nowShown { return .restore }
        return .unchanged
    }

    /// The park/restore delta of a lens change (tag-mode analog of
    /// `SwitchPlan`).
    struct LensPlan: Equatable, Sendable {
        let oldLens: UInt64
        let newLens: UInt64
        /// Windows that left the visible union (were shown, now hidden).
        let toPark: [WindowRef]
        /// Windows that entered the visible union (were hidden, now
        /// shown).
        let toRestore: [WindowRef]
    }

    /// Set the lens to `newLens` (tag mode). Returns the union-delta
    /// park/restore plan, or nil when not in tag mode or the lens is
    /// unchanged. Sticky (`everywhere`) and stashed-scratchpad windows
    /// are excluded from both lists, exactly like `setActive`.
    @discardableResult
    mutating func setLens(_ newLens: UInt64) -> LensPlan? {
        guard grouping == .tag else { return nil }
        // Floor guard (#228): an empty lens would park EVERY window
        // (nothing intersects a 0 mask). Fall back to the `_default`
        // floor — every window carries it — so emptying the lens (a
        // `--toggle` / `--remove` that clears the last user tag) shows the
        // untagged baseline instead of a blank desktop. Without this a
        // user verb that lands on 0 silently hides everything.
        let target = newLens == 0 ? TagModel.defaultBit : newLens
        guard target != lens else { return nil }
        let old = lens
        lens = target
        func shows(_ mask: UInt64, _ tags: UInt64) -> Bool {
            (tags & mask) != 0
        }
        let toPark = windowMap
            .filter { shows(old, $0.value.tags)
                && !shows(target, $0.value.tags)
                && !everywhereWindows.contains($0.key)
                && !stashedWindows.contains($0.key) }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        let toRestore = windowMap
            .filter { shows(target, $0.value.tags)
                && !shows(old, $0.value.tags)
                && !everywhereWindows.contains($0.key)
                && !stashedWindows.contains($0.key) }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        return LensPlan(oldLens: old, newLens: target,
                        toPark: toPark, toRestore: toRestore)
    }

}
