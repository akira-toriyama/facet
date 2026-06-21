// Section-lens park / restore (tag-unification Phase 1 → EX-1 exclusive model)
// — the section-model analog of the tag-mode lens
// (`WorkspaceCatalog+Tags.swift`). A `type="lens"` `[[desktop.N.section]]`
// becomes a REAL hide across ALL workspaces on the current mac desktop: the
// windows its `match` excludes are anchor-parked + detached from the layout so
// the in-lens windows reclaim the freed slots. Pure state machine (AX-free,
// unit-tested in `FacetAdapterNativeTests`).
//
// The catalog can't evaluate a lens `match` — it holds no live
// `appName`/`title` (only `windowMap`'s workspace + pid + tags). So the
// EVALUATION lives adapter-side (`NativeAdapter+Queries.swift`), which builds
// the in-lens id set from live windows + the shared `LensMembership` predicate
// and hands it here as `visibleIDs`. The tree display (`FilterProjection`) and
// this hide path therefore route through the SAME predicate — they can never
// disagree about a window's lens membership; grid/rail then drop the parked
// windows via the snapshot's `Window.isLensParked` flag, so they ride this same
// verdict too.
//
// `lensParkedMembers` is the section-model twin of `hiddenMembers`: excluded
// from `nonFloatingMembers` (so stateless engines + the bsp re-seed skip it)
// AND detached from the layout containers (so bsp / stack drop it), exactly
// like a Cmd+H hide. Unlike a hide it is anchor-parked (facet moved it to the
// sliver). It holds windows from ANY workspace (cross-workspace exclusive model
// — EX-1): `applySectionLens` scans all workspaces; `attachToLayout` on restore
// uses `slot.workspace` so each window re-attaches to its OWN home workspace.

import CoreGraphics
import FacetCore

extension WorkspaceCatalog {

    /// The park/restore delta of a section-lens application — the section-model
    /// analog of the tag-mode `LensPlan` / the `SwitchPlan` (no lens-mask
    /// fields: a section lens is a string `match`, evaluated adapter-side).
    struct SectionLensPlan: Equatable, Sendable {
        /// Members (from any workspace) that left the lens (now parked off-screen).
        let toPark: [WindowRef]
        /// Members (from any workspace) that re-entered the lens (restored into view).
        let toRestore: [WindowRef]

        var isEmpty: Bool { toPark.isEmpty && toRestore.isEmpty }
    }

    /// Display name of the 1-based workspace `n1Based`, or `""` for an
    /// out-of-range index (the "show the number" sentinel). The adapter needs
    /// this to overlay the workspace name when evaluating a lens
    /// `match='workspace=Dev'` (`LensMembership` / `ProjectedWindowFields`).
    func workspaceName(_ n1Based: Int) -> String {
        (n1Based >= 1 && n1Based <= workspaceNames.count)
            ? workspaceNames[n1Based - 1] : ""
    }

    /// Apply the active section-lens across ALL workspaces on the current mac
    /// desktop given the adapter's match verdict. `visibleIDs` is the set of
    /// members (from any workspace) whose live `Window` passes the lens
    /// `match`; everything else parks. Mirrors the tag-mode `setLens`
    /// park/restore filter but is string-match driven + cross-workspace scoped
    /// (EX-1 exclusive model), and idempotent: re-running with an unchanged
    /// verdict returns an empty plan (so the continuous re-park can call it
    /// every reconcile cheaply). Sticky / stashed windows are park-exempt
    /// (`isParkEligible`); a user-hidden (Cmd+H) member is left alone (it
    /// already gave up its slot — re-parking it would fight the hide-reclaim).
    ///
    /// On restore, each window re-attaches to its OWN home workspace's layout
    /// (`slot.workspace`), not to `activeIndex` — a window in WS2 that
    /// re-enters the lens must rejoin WS2's layout containers, not WS1's.
    ///
    /// Returns the AX park/restore plan; the catalog half (record + detach /
    /// un-record + re-attach) is applied here so `nonFloatingMembers` and the
    /// layout containers stay consistent with the on-screen reality.
    mutating func applySectionLens(visibleIDs: Set<WindowID>,
                                   in rect: CGRect) -> SectionLensPlan {
        var toPark: [WindowRef] = []
        var toRestore: [WindowRef] = []
        for (id, slot) in windowMap
        where isParkEligible(id) && !hiddenMembers.contains(id) {
            let shouldShow = visibleIDs.contains(id)
            let isLensParked = lensParkedMembers.contains(id)
            if !shouldShow && !isLensParked {
                lensParkedMembers.insert(id)
                detachFromLayouts(id)
                toPark.append(WindowRef(id: id, pid: slot.pid))
            } else if shouldShow && isLensParked {
                lensParkedMembers.remove(id)
                attachToLayout(id, workspace: slot.workspace,
                               focused: nil, in: rect)
                toRestore.append(WindowRef(id: id, pid: slot.pid))
            }
        }
        return SectionLensPlan(toPark: toPark, toRestore: toRestore)
    }

    /// The cross-workspace union currently shown by the active section-lens:
    /// every tracked, tileable window NOT parked out of the lens. The
    /// section-model twin of tag-mode's `visibleNonFloatingMembers()`, but the
    /// "in lens" decision is the already-applied `lensParkedMembers` set (the
    /// adapter evaluated the match and parked the rest). Spans ALL workspaces of
    /// the current mac desktop — there is deliberately NO active-workspace clause.
    /// Stable serverID order so tiling is deterministic.
    func sectionLensUnionMembers() -> [WindowID] {
        windowMap
            .filter { !lensParkedMembers.contains($0.key)
                && !floatingWindows.contains($0.key)
                && !hiddenMembers.contains($0.key) }
            .map(\.key)
            .sorted { $0.serverID < $1.serverID }
    }

    /// Tiled frames for the active section-lens union — one stateless engine over
    /// the cross-workspace set (the section-model twin of `tagUnionFrames`).
    /// `layout` is the lens's resolved stateless engine name (see `LensLayout`).
    func sectionLensUnionFrames(layout: String, in rect: CGRect) -> [WindowID: CGRect] {
        guard let engine = LayoutRegistry.engine(named: layout) else { return [:] }
        return engine.frames(order: sectionLensUnionMembers(),
                             focused: nil, params: LayoutParams(), in: rect)
    }

    /// Clear the active section-lens: every lens-parked window (from any
    /// workspace) re-enters its own workspace's layout and is restored into
    /// view, and the lens drops. Returns the restore plan (`toPark` is always
    /// empty). Also clears `activeSectionLens` so the authority + the parked
    /// set move together.
    mutating func clearSectionLens(in rect: CGRect) -> SectionLensPlan {
        activeSectionLens = nil
        guard !lensParkedMembers.isEmpty else {
            return SectionLensPlan(toPark: [], toRestore: [])
        }
        var toRestore: [WindowRef] = []
        for id in lensParkedMembers {
            guard let slot = windowMap[id] else { continue }
            attachToLayout(id, workspace: slot.workspace,
                           focused: nil, in: rect)
            toRestore.append(WindowRef(id: id, pid: slot.pid))
        }
        lensParkedMembers.removeAll()
        return SectionLensPlan(toPark: [], toRestore: toRestore)
    }
}
