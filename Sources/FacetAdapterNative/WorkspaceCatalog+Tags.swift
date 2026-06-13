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
    /// window is assigned. `lens` is normally `model.firstBit`.
    mutating func seedTags(grouping: Grouping, model: TagModel,
                           rules: AssignRules, lens: UInt64) {
        // Seed once. `grouping` starts `.workspace` (the default); the
        // first seed flips it to `.tag`. A later refresh calling this
        // again would otherwise reset `lens` to the seed value on every
        // poll, clobbering the user's `setLens` changes.
        guard self.grouping == .workspace, grouping != .workspace else {
            return
        }
        self.grouping = grouping
        self.tagModel = model
        self.assignRules = rules
        self.lens = lens
    }

    /// Tag bitmask for a newly-appeared window (tag mode). The UNION of
    /// every matching `[[assign]]` rule; an unmatched window inherits
    /// the current lens's PRIMARY tag (its lowest set bit) so it lands
    /// in exactly one visible place — never the whole lens union (a
    /// broad `--all` lens shouldn't freeze every tag onto a new
    /// window). Always carries the `_default` floor
    /// (`TagModel.defaultBit`) so the window is never `0` / lost (#191).
    func tagsForNewWindow(_ probe: WindowProbe) -> UInt64 {
        let base: UInt64
        let assigned = assignRules.mask(for: probe, in: tagModel)
        if assigned != 0 {
            base = assigned
        } else if lens != 0 {
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
        guard let engine = LayoutRegistry.engine(named: defaultMode)
        else { return [:] }
        return engine.frames(order: visibleNonFloatingMembers(),
                             focused: nil, params: LayoutParams(), in: rect)
    }

    /// Tag-mode snapshot: one `Workspace` per tag (header = tag name,
    /// `isActive` = tag is in the current lens), each tracked window
    /// listed under its PRIMARY tag once (full-tag-world overview,
    /// independent of the lens). The tiled set is the lens union (one
    /// global layout); a window not in the lens shows at its parked
    /// position. Secondary-tag badges + multi-active styling are the
    /// view's job (M11-3 PR3).
    func tagSnapshot(live: [Window], focused: WindowID?,
                             activeRect: CGRect) -> [Workspace] {
        let tracked = live.filter {
            windowMap[$0.id] != nil && !stashedWindows.contains($0.id)
        }
        let unionFrames = tagUnionFrames(in: activeRect)
        let fallbackTag = tagModel.names.first ?? ""
        let byTag = Dictionary(grouping: tracked) { w -> String in
            let mask = windowMap[w.id]?.tags ?? 0
            return tagModel.primaryName(of: mask) ?? fallbackTag
        }
        return tagModel.names.enumerated().map { (i, tagName) in
            let bit = UInt64(1) << UInt64(i)
            let isActive = (bit & lens) != 0
            let wins = (byTag[tagName] ?? []).map { w -> Window in
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
                              isMaster: false,
                              mark: mark(forWindow: w.id),
                              isSticky: everywhereWindows.contains(w.id),
                              scratchpad: scratchpad(forWindow: w.id),
                              tags: tagModel.names(in: mask))
            }
            return Workspace(index: i, name: tagName, isActive: isActive,
                             layoutMode: defaultMode, windows: wins)
        }
    }

    // Lens-command resolvers (pure: name → new mask). `nil` = unknown
    // tag name (caller surfaces lastError, makes no change).
    func lensOnly(_ name: String) -> UInt64? { tagModel.bit(for: name) }
    func lensToggled(_ name: String) -> UInt64? {
        guard let b = tagModel.bit(for: name) else { return nil }
        return lens ^ b
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

    /// Append `name` to the session tag vocabulary if absent and return
    /// its bit; returns the existing bit when already defined. `nil`
    /// when the vocabulary is full (63 user tags) or `name` is the
    /// reserved `_default`. The auto-vivify primitive shared by
    /// `window --tag`/`--toggle-tag` (and later `tag --add`). The CLI
    /// parser already rejects malformed names.
    @discardableResult
    mutating func addTagName(_ name: String) -> UInt64? {
        if let bit = tagModel.bit(for: name) { return bit }     // defined
        guard name != TagModel.defaultName else { return nil }  // reserved
        guard tagModel.count < TagModel.maxUserTags else { return nil } // full
        tagModel = TagModel(tagModel.names + [name])
        return tagModel.bit(for: name)
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
        guard grouping == .tag, newLens != lens else { return nil }
        let old = lens
        lens = newLens
        func shows(_ mask: UInt64, _ tags: UInt64) -> Bool {
            (tags & mask) != 0
        }
        let toPark = windowMap
            .filter { shows(old, $0.value.tags)
                && !shows(newLens, $0.value.tags)
                && !everywhereWindows.contains($0.key)
                && !stashedWindows.contains($0.key) }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        let toRestore = windowMap
            .filter { shows(newLens, $0.value.tags)
                && !shows(old, $0.value.tags)
                && !everywhereWindows.contains($0.key)
                && !stashedWindows.contains($0.key) }
            .map { WindowRef(id: $0.key, pid: $0.value.pid) }
        return LensPlan(oldLens: old, newLens: newLens,
                        toPark: toPark, toRestore: toRestore)
    }

}
