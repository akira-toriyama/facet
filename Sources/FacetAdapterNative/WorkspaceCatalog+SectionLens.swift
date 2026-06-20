// Section-lens park / restore (tag-unification Phase 1) — the section-model
// analog of the tag-mode lens (`WorkspaceCatalog+Tags.swift`). A `type="lens"`
// `[[desktop.N.section]]` becomes a REAL hide within the active workspace: the
// windows its `match` excludes are anchor-parked + detached from the layout so
// the in-lens windows reclaim the freed slots. Pure state machine (AX-free,
// unit-tested in `FacetAdapterNativeTests`).
//
// The catalog can't evaluate a lens `match` — it holds no live
// `appName`/`title` (only `windowMap`'s workspace + pid + tags). So the
// EVALUATION lives adapter-side (`NativeAdapter+Queries.swift`), which builds
// the in-lens id set from live windows + the shared `LensMembership` predicate
// and hands it here as `visibleIDs`. Display (`FilterProjection`/
// `OverviewProjection`) and this hide path therefore route through the SAME
// predicate — they can never disagree about a window's lens membership.
//
// `lensParkedMembers` is the section-model twin of `hiddenMembers`: excluded
// from `nonFloatingMembers` (so stateless engines + the bsp re-seed skip it)
// AND detached from the layout containers (so bsp / stack drop it), exactly
// like a Cmd+H hide. Unlike a hide it is anchor-parked (facet moved it to the
// sliver). It only ever holds ACTIVE-WS windows — `setActive` lifts the lens
// off the old workspace and re-applies to the new — so an inactive workspace's
// preview is never narrowed by the lens.

import CoreGraphics
import FacetCore

extension WorkspaceCatalog {

    /// The park/restore delta of a section-lens application — the section-model
    /// analog of the tag-mode `LensPlan` / the `SwitchPlan` (no lens-mask
    /// fields: a section lens is a string `match`, evaluated adapter-side).
    struct SectionLensPlan: Equatable, Sendable {
        /// Active-WS members that left the lens (now parked off-screen).
        let toPark: [WindowRef]
        /// Active-WS members that re-entered the lens (restored into view).
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

    /// Apply the active section-lens to the ACTIVE workspace given the
    /// adapter's match verdict. `visibleIDs` is the set of active-WS members
    /// whose live `Window` passes the lens `match`; everything else parks.
    /// Mirrors the tag-mode `setLens` park/restore filter but is string-match
    /// driven + active-WS scoped, and idempotent: re-running with an unchanged
    /// verdict returns an empty plan (so the continuous re-park can call it
    /// every reconcile cheaply). Sticky / stashed windows are park-exempt
    /// (`isParkEligible`); a user-hidden (Cmd+H) member is left alone (it
    /// already gave up its slot — re-parking it would fight the hide-reclaim).
    ///
    /// Returns the AX park/restore plan; the catalog half (record + detach /
    /// un-record + re-attach) is applied here so `nonFloatingMembers` and the
    /// layout containers stay consistent with the on-screen reality.
    mutating func applySectionLens(visibleIDs: Set<WindowID>,
                                   in rect: CGRect) -> SectionLensPlan {
        var toPark: [WindowRef] = []
        var toRestore: [WindowRef] = []
        for (id, slot) in windowMap
        where slot.workspace == activeIndex
            && isParkEligible(id)
            && !hiddenMembers.contains(id) {
            let shouldShow = visibleIDs.contains(id)
            let isLensParked = lensParkedMembers.contains(id)
            if !shouldShow && !isLensParked {
                lensParkedMembers.insert(id)
                detachFromLayouts(id)
                toPark.append(WindowRef(id: id, pid: slot.pid))
            } else if shouldShow && isLensParked {
                lensParkedMembers.remove(id)
                attachToLayout(id, workspace: activeIndex,
                               focused: nil, in: rect)
                toRestore.append(WindowRef(id: id, pid: slot.pid))
            }
        }
        return SectionLensPlan(toPark: toPark, toRestore: toRestore)
    }

    /// Clear the active section-lens: every lens-parked window re-enters its
    /// workspace's layout and is restored into view, and the lens drops.
    /// `lensParkedMembers` only ever holds ACTIVE-WS windows, so all of them
    /// want an AX restore. Returns the restore plan (`toPark` is always
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
