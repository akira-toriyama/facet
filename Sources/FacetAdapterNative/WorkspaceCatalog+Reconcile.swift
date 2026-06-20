// Reconcile — diff the live CGWindowList against the catalog (adopt / forget / hidden-window slot handling).
// Extracted unchanged from WorkspaceCatalog.swift (#182 phase 2) —
// same-module extension, no logic change. Stored state stays on the
// primary declaration (WorkspaceCatalog.swift).

import CoreGraphics
import FacetCore

extension WorkspaceCatalog {

    // MARK: - Reconcile

    struct ReconcileResult: Equatable, Sendable {
        let added: Int
        let removed: Int
        /// IDs that newly joined `windowMap` this reconcile. Empty
        /// when `added == 0`. Order is insertion order from this
        /// reconcile pass (which is dictionary-iteration order over
        /// `liveByID`, so non-deterministic across runs — fine for
        /// the open/close animation gate; not a stable handle).
        let addedIDs: [WindowID]
        /// IDs that left `windowMap` this reconcile (truly gone from
        /// the CGWindowList enumeration — `.optionAll` is on, so an
        /// off-screen / cross-mac-desktop window stays managed, not in
        /// here). Empty when `removed == 0`.
        let removedIDs: [WindowID]
        init(added: Int, removed: Int,
             addedIDs: [WindowID] = [], removedIDs: [WindowID] = []) {
            self.added = added
            self.removed = removed
            self.addedIDs = addedIDs
            self.removedIDs = removedIDs
        }
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
    /// genuinely new windows, which can't be a mac-desktop switch
    /// `isOnscreen` flip of an existing one. They skip the two-tick
    /// gate (added on first on-screen sight) but still honour
    /// `allowAutoAdd` and the off-screen defer, so off-desktop windows
    /// and the flip case remain protected.
    ///
    /// `ignore` lists ids that matched a config `[[exclude]]` rule
    /// with `action="ignore"` — they're marked examined and never
    /// enter `windowMap` (fully unmanaged). First-sight only: a
    /// window already in `windowMap` is untouched.
    @discardableResult
    mutating func reconcile(live: [Window],
                                   focused: WindowID? = nil,
                                   activeRect: CGRect = .zero,
                                   autoFloat: Set<WindowID> = [],
                                   trusted: Set<WindowID> = [],
                                   ignore: Set<WindowID> = [],
                                   deferred: Set<WindowID> = [],
                                   requireConfirm: Bool = false,
                                   tags: [WindowID: UInt64] = [:])
        -> ReconcileResult
    {
        let liveByID = Dictionary(uniqueKeysWithValues:
                                  live.map { ($0.id, $0) })
        let liveIDs = Set(liveByID.keys)
        // Truly-gone IDs only: a window absent from the full
        // CGWindowList enumeration (which now includes off-screen
        // windows via .optionAll). A window that's merely on a
        // different mac desktop, minimized to the Dock, or Cmd+H'd
        // stays in `liveByID` with `isOnscreen=false` — we keep its
        // WS assignment (a user hide gives up only its tile slot, which
        // `reconcileHidden` reclaims for the neighbours; the window
        // itself is never forgotten until it truly closes).
        let goneIDs = windowMap.keys.filter { !liveIDs.contains($0) }
        for id in goneIDs { forgetWindow(id) }
        // "Are we on a mac desktop that holds at least one window
        // facet already manages?" If not, suppress auto-add so a
        // window the user opens while parked on an unrelated mac desktop
        // (e.g. open Finder after switching to mac desktop 2) doesn't
        // slide into `activeIndex` and pollute the user's facet
        // tree. The catalog has no public way to know its own
        // mac-desktop membership without dipping into private SkyLight
        // APIs, so this heuristic uses the visibility of an
        // already-managed window as a proxy: if one of ours is
        // on-screen, the user is on "our" mac desktop. Empty-catalog
        // bootstrap is exempt — facet has to be able to pick up
        // its first batch of windows.
        let onFacetSpace = windowMap.keys.contains { id in
            liveByID[id]?.isOnscreen == true
        }
        let allowAutoAdd = windowMap.isEmpty || onFacetSpace
        var added = 0
        var addedIDs: [WindowID] = []
        for (id, w) in liveByID {
            if let existing = windowMap[id] {
                if existing.pid != w.pid {
                    windowMap[id] = WindowSlot(
                        workspace: existing.workspace, pid: w.pid,
                        tags: existing.tags)
                }
                continue
            }
            // Bulk-marked pre-existing (other mac desktop at startup /
            // mac-desktop-change snapshot, Cmd+H'd window seen at
            // startup, etc.). Stay out of `windowMap` even if
            // the OS later flips them on-screen.
            if examinedIDs.contains(id) { continue }
            // Config `[[exclude]] action="ignore"`: never manage.
            // Mark examined so it's not reconsidered (and the
            // adapter's classify pass stops re-probing it).
            if ignore.contains(id) {
                examinedIDs.insert(id)
                continue
            }
            // Adapter couldn't resolve this window's AX role yet (the
            // probe raced a still-creating window, or the per-call probe
            // cap was hit). Skip WITHOUT marking examined so the next
            // reconcile re-probes it: a real window resolves and joins
            // within a poll or two; a transient popup (autocomplete /
            // dropdown) vanishes before it resolves and never joins.
            // Mirrors the off-screen defer below — both are "decide
            // later" states, not "never manage" (`examined`) states.
            if deferred.contains(id) {
                pendingAddCandidates.remove(id)
                continue
            }
            // Off-desktop new window: see `allowAutoAdd` above.
            // Don't mark examined either — when the user comes
            // back to facet's mac desktop and the window is moved here
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
            // mac-desktop visibility flip that happens during a
            // mac-desktop switch animation: a Finder window
            // opened on mac desktop N briefly reads `isOnscreen=true`
            // when the user swipes back to mac desktop 1, but settles
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
            // the gate: a brand-new window can't be the cross-mac-desktop
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
                workspace: activeIndex, pid: w.pid, tags: tags[id] ?? 0)
            examinedIDs.insert(id)
            added += 1
            addedIDs.append(id)
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
        return ReconcileResult(added: added, removed: goneIDs.count,
                               addedIDs: addedIDs, removedIDs: goneIDs)
    }

    /// Hide-reclaim pass. A managed window reading `isOnscreen=false`
    /// was hidden by the user (Cmd+H app-hide / Cmd+M minimize) — facet
    /// parks its own off-WS / stack windows at the on-screen anchor
    /// sliver, which keeps `isOnscreen=true`, so it never produces this
    /// state. Such a window keeps its `windowMap` slot (WS assignment +
    /// marks survive) but is pulled out of the layout containers so the
    /// remaining tiled windows reclaim its freed slot; when it returns
    /// on-screen it re-attaches via `attachToLayout` exactly like a
    /// newly-opened window — at the tail for stateless engines
    /// (master-* / grid / spiral), re-inserted into the tree for bsp,
    /// and at the visible TOP (index 0) for stack mode.
    ///
    /// MUST run AFTER the adapter's off-desktop drift heal so a window
    /// merely parked on another mac desktop (also `isOnscreen=false`)
    /// has already been evicted from this catalog and isn't mistaken
    /// for a hide. The two-tick `pendingHideCandidates` gate additionally
    /// swallows the transient off-screen flip during a mac-desktop switch
    /// animation (mirrors the add path's `pendingAddCandidates`).
    ///
    /// Returns the ids whose state changed this pass so the caller can
    /// drive the open/close reflow animation (a hide reflows like a
    /// close; a reveal snaps in like an open).
    mutating func reconcileHidden(liveByID: [WindowID: Window],
                                  focused: WindowID?,
                                  activeRect: CGRect)
        -> (hidden: [WindowID], revealed: [WindowID])
    {
        var newlyHidden: [WindowID] = []
        var newlyRevealed: [WindowID] = []
        for (id, slot) in windowMap {
            // Default to on-screen when the live snapshot lacks the id
            // (shouldn't happen post-reconcile, but never strand a
            // window as hidden on a missing read).
            let onscreen = liveByID[id]?.isOnscreen ?? true
            if hiddenMembers.contains(id) {
                guard onscreen else { continue }   // still hidden
                hiddenMembers.remove(id)
                pendingHideCandidates.remove(id)
                attachToLayout(id, workspace: slot.workspace,
                               focused: focused, in: activeRect)
                newlyRevealed.append(id)
                continue
            }
            // Not currently hidden. A hide candidate is off-screen,
            // not parked by facet (sliver = on-screen), and tiled
            // (floating / sticky windows hold no tile slot to reclaim).
            guard !onscreen,
                  !anchorParked.contains(id),
                  !floatingWindows.contains(id)
            else {
                pendingHideCandidates.remove(id)
                continue
            }
            // Two-tick confirm: detach only after a second consecutive
            // off-screen sighting, so a mac-desktop switch transient doesn't
            // strip a window's slot then re-grant it (a visible flicker).
            guard pendingHideCandidates.contains(id) else {
                pendingHideCandidates.insert(id)
                continue
            }
            pendingHideCandidates.remove(id)
            hiddenMembers.insert(id)
            detachFromLayouts(id)
            newlyHidden.append(id)
        }
        return (newlyHidden, newlyRevealed)
    }

    /// Bulk-mark every id in `live` as pre-existing (don't
    /// auto-add later on an `isOnscreen` flip). Called from the
    /// adapter **once at startup** (the `didBootstrap` guard), with
    /// the first enumeration's off-screen windows — so pre-existing
    /// windows on other mac desktops can't slide into `activeIndex`
    /// when a later flip reads them on-screen. NOT re-run on
    /// mac-desktop switch: `classifyNewWindows` skips off-screen
    /// windows outright, and the destination desktop's own catalog
    /// adopts its windows once they read on-screen. Idempotent.
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
        hiddenMembers.remove(id)                  // drop hide-reclaim state
        pendingHideCandidates.remove(id)
        lensParkedMembers.remove(id)              // drop section-lens park state
        marks = marks.filter { $0.value != id }   // drop any mark on it
        everywhereWindows.remove(id)              // drop sticky on it
        scratchpads = scratchpads.filter { $0.value != id }  // drop shelf
        stashedWindows.remove(id)
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

}
