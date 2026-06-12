// Window marks + sticky windows + scratchpad shelf.
// Extracted unchanged from WorkspaceCatalog.swift (#182 phase 2) —
// same-module extension, no logic change. Stored state stays on the
// primary declaration (WorkspaceCatalog.swift).

import CoreGraphics
import FacetCore

extension WorkspaceCatalog {

    // MARK: - Window marks (1:1 name ⇄ window)

    /// Assign mark `name` to `id`, keeping the bijection: the name's
    /// previous window loses it, and `id`'s previous mark (if any) is
    /// cleared, so afterwards exactly `name ⇄ id` holds. No-op only on
    /// an empty name (the caller rejects that at parse time). `id` need
    /// not be in `windowMap` — but callers pass the focused window.
    mutating func setMark(_ name: String, to id: WindowID) {
        // Clear id's existing name (a window holds at most one mark).
        marks = marks.filter { $0.value != id }
        marks[name] = id          // reassigns the name to the new window
    }

    /// Remove mark `name`. Returns whether it existed, so the caller
    /// can surface "no such mark" when the user clears nothing.
    @discardableResult
    mutating func removeMark(_ name: String) -> Bool {
        marks.removeValue(forKey: name) != nil
    }

    /// The window a mark points to, or nil when the name is unset.
    func window(forMark name: String) -> WindowID? { marks[name] }

    /// The mark a window carries, or nil when unmarked. Used by the
    /// snapshot to stamp `Window.mark` for the tree badge.
    func mark(forWindow id: WindowID) -> String? {
        marks.first { $0.value == id }?.key
    }

    // MARK: - Sticky windows (pin across every WS)

    /// Whether `id` is sticky (pinned visible across every WS in this
    /// mac desktop). Stamped on `Window.isSticky` in the snapshot.
    func isSticky(_ id: WindowID) -> Bool {
        everywhereWindows.contains(id)
    }

    /// Make `id` sticky: a member of every facet WS in this native
    /// mac desktop and force-floating (Q2). No-op for an unknown window.
    /// Idempotent. Stays at its current frame — pinning shouldn't
    /// teleport the window (the caller leaves floating windows where
    /// they are; only the *other* windows of the WS reflow to fill the
    /// gap it left).
    mutating func setSticky(_ id: WindowID) {
        guard windowMap[id] != nil else { return }
        // Sticky and scratchpad are mutually exclusive (a window can't
        // be both "always visible everywhere" and "hidden on a shelf").
        // Drop any shelf membership so the XOR holds in both directions
        // (`stashWindow` does the reverse).
        scratchpads = scratchpads.filter { $0.value != id }
        stashedWindows.remove(id)
        everywhereWindows.insert(id)
        floatingWindows.insert(id)   // force floating (Q2)
        detachFromLayouts(id)        // leave its home WS's tiling
    }

    /// Clear sticky on `id`: stop pinning it, drop the forced float,
    /// and re-home it as a normal tiled window of the **active** WS
    /// (Q4 — it lands in front of the user, not back at its old home,
    /// so the window the user is looking at never vanishes). No-op when
    /// `id` isn't sticky / is unknown.
    mutating func clearSticky(_ id: WindowID,
                              focused: WindowID? = nil,
                              in rect: CGRect = .zero) {
        guard everywhereWindows.contains(id),
              let slot = windowMap[id] else { return }
        everywhereWindows.remove(id)
        floatingWindows.remove(id)
        windowMap[id] = WindowSlot(workspace: activeIndex, pid: slot.pid,
                                   tags: slot.tags)
        attachToLayout(id, workspace: activeIndex,
                       focused: focused, in: rect)
    }

    // MARK: - Scratchpad shelf (1:1 name ⇄ window, off-screen)

    /// Whether `id` is currently stashed (hidden on a shelf, parked
    /// off-screen). A *settled* (summoned) scratchpad window returns
    /// `false` — it lives on a WS like a normal floating window.
    func isStashed(_ id: WindowID) -> Bool { stashedWindows.contains(id) }

    /// The window on shelf `name`, or nil when the name is unset.
    func window(forScratchpad name: String) -> WindowID? { scratchpads[name] }

    /// The shelf a window is registered on, or nil. Used by the
    /// snapshot to stamp `Window.scratchpad` for the settled badge.
    func scratchpad(forWindow id: WindowID) -> String? {
        scratchpads.first { $0.value == id }?.key
    }

    /// Names of currently *stashed* shelves (hidden), for `facet
    /// status`. Settled shelves are excluded (they show in the tree).
    func stashedScratchpadNames() -> [String] {
        scratchpads.filter { stashedWindows.contains($0.value) }
            .map(\.key).sorted()
    }

    /// Whether shelf `name`'s window is *visible on the current
    /// workspace* (settled here, not parked). Drives the toggle branch:
    /// visible → re-park to shelf; not visible (stashed, or settled on
    /// another WS) → summon to the current WS (Q8: "pull it here" and
    /// "summon from shelf" are the same gesture).
    func isScratchpadVisibleHere(_ name: String) -> Bool {
        guard let id = scratchpads[name] else { return false }
        return !stashedWindows.contains(id)
            && windowMap[id]?.workspace == activeIndex
    }

    /// Stash the focused window onto shelf `name`, keeping the 1:1
    /// bijection (the name's old window un-shelves, the window's old
    /// shelf is released). Clears any sticky (XOR), force-floats so the
    /// tiler ignores it, detaches it from its home WS's layout, and
    /// marks it stashed. The adapter does the AX park afterwards. No-op
    /// (returns false) for an unmanaged window.
    @discardableResult
    mutating func stashWindow(_ name: String, id: WindowID) -> Bool {
        guard windowMap[id] != nil else { return false }
        // bijection: the name's previous occupant un-shelves; the
        // window's previous shelf (if any) is released.
        if let prev = scratchpads[name] { stashedWindows.remove(prev) }
        scratchpads = scratchpads.filter { $0.value != id }
        scratchpads[name] = id
        everywhereWindows.remove(id)   // XOR with sticky
        floatingWindows.insert(id)     // overlay, not tiled
        detachFromLayouts(id)
        stashedWindows.insert(id)
        return true
    }

    /// Summon shelf `name` onto the active WS as a settled floating
    /// overlay: re-home its slot to `activeIndex`, clear the stashed
    /// flag (so visibility logic stops skipping it), keep it floating.
    /// The adapter restores it on-screen (`restoreAnchor`) + focuses it.
    /// Returns the window id, or nil when the shelf is unset / gone.
    @discardableResult
    mutating func summonScratchpad(_ name: String) -> WindowID? {
        guard let id = scratchpads[name], let slot = windowMap[id]
        else { return nil }
        windowMap[id] = WindowSlot(workspace: activeIndex, pid: slot.pid,
                                   tags: slot.tags)
        stashedWindows.remove(id)      // now settled / visible
        floatingWindows.insert(id)     // settle = floating overlay
        return id
    }

    /// Re-park (toggle off) a currently-summoned shelf window: mark it
    /// stashed again and re-detach. The adapter parks it via
    /// `parkAnchor`. Returns the window id, or nil when unset / gone.
    @discardableResult
    mutating func restashScratchpad(_ name: String) -> WindowID? {
        guard let id = scratchpads[name], windowMap[id] != nil
        else { return nil }
        stashedWindows.insert(id)
        floatingWindows.insert(id)
        detachFromLayouts(id)
        return id
    }

    /// Release shelf `name`: drop it from the shelf entirely and re-home
    /// the window as a normal *tiled* window of the active WS (Q4 — same
    /// landing as un-sticky, in front of the user). The adapter brings
    /// it on-screen first if it was parked. Returns the freed window id,
    /// or nil when the shelf was unset.
    @discardableResult
    mutating func releaseScratchpad(_ name: String,
                                    focused: WindowID? = nil,
                                    in rect: CGRect = .zero) -> WindowID? {
        guard let id = scratchpads.removeValue(forKey: name),
              let slot = windowMap[id] else { return nil }
        stashedWindows.remove(id)
        floatingWindows.remove(id)
        windowMap[id] = WindowSlot(workspace: activeIndex, pid: slot.pid,
                                   tags: slot.tags)
        attachToLayout(id, workspace: activeIndex,
                       focused: focused, in: rect)
        return id
    }

    /// Resolve the cached pid for a window, or nil if it's not in
    /// `windowMap`. Used by `closeWindow` so it can skip a
    /// CGWindowList re-enumeration just to recover pid.
    func pid(for id: WindowID) -> Int? {
        windowMap[id]?.pid
    }

}
