// Section-model MOVE orchestration — the Controller half of the tree's
// section-path drag / kb-lift. The view hands over section IDs + the dest
// workspace index; the Controller resolves the plan with the PURE
// `ApplyResolver` and, on a real move, re-files the window into the dest
// workspace on `cliQueue` (ws→ws membership — the ONLY move there is, since
// t-6rbc retired the orphan concept). Since section-lens was retired (t-ec9s),
// a MOVE carries no tag / apply ops.
//
// Snap-back is "do nothing": an inert / stale plan runs NO backend op, and
// because the section tree row is never hidden during the drag (only
// de-emphasised), the next reconcile re-projects the unchanged state — the row
// simply stays put. (Unlike grid/rail, there is no `OverviewPendingDrop` to
// roll back.)

import FacetCore
import Foundation

extension Controller {
    func applyMove(windowID: WindowID, fromSectionID: String,
                   toSectionID: String, destSourceWorkspaceIndex: Int?) {
        guard let plan = resolveApplyPlan(
            windowID: windowID, fromSectionID: fromSectionID,
            toSectionID: toSectionID, destWorkspaceIndex: destSourceWorkspaceIndex)
        else { return }                          // inert / stale → snap-back
        runApplyPlan(plan, on: windowID)
    }

    /// Build the plan on the main actor (the pure resolver over the live
    /// section config + last-rendered workspaces). `nil` ⇒ no spatial substrate
    /// / window gone / inert — the caller does nothing (snap-back).
    ///
    /// `isSectionModelActive` is the RIGHT question here (not
    /// `desktopRenderMode.rendersSections`): a drop has to LAND on a real
    /// `[[desktop.N.section]]` workspace cell. An isolate desktop renders sections,
    /// but they are synthesized from `match` — membership there is a predicate,
    /// not a place, so there is nothing to drop into. (Its holding rows are
    /// inert as a drag SOURCE too — t-63h2.)
    private func resolveApplyPlan(windowID: WindowID, fromSectionID: String?,
                                  toSectionID: String, destWorkspaceIndex: Int?)
        -> ApplyResolver.Plan?
    {
        let ordinal = currentMacDesktopOrdinal()
        guard config.isSectionModelActive(ordinal: ordinal) else { return nil }
        guard let (win, _) = findRenderedWindow(windowID) else { return nil }
        let plan = ApplyResolver.plan(
            window: win,
            fromSectionID: fromSectionID, toSectionID: toSectionID,
            destWorkspaceIndex: destWorkspaceIndex)
        if plan.isInert {
            if let r = plan.reason { Log.debug("apply: inert — \(r)") }
            return nil
        }
        return plan
    }

    /// Dispatch a resolved plan onto `cliQueue` — a workspace MEMBERSHIP move
    /// (ws→ws, the only kind there is) by 0-based wire index — then
    /// schedule a single coalesced reconcile. ONE `cliQueue.async` block so the
    /// move can't interleave with a refresh poll. (Since section-lens was retired
    /// there are no tag / apply ops left — a MOVE is purely a workspace re-file.)
    private func runApplyPlan(_ plan: ApplyResolver.Plan, on id: WindowID) {
        let bk = backend
        cliQueue.async {
            if let dst = plan.destWorkspaceIndex {
                bk.moveWindow(id, toWorkspaceIndex: dst)
            }
        }
        scheduleReconcile(after: 0.05)
    }

    /// The live window + its workspace name from the last rendered snapshot.
    /// Internal (not private): `openTagEditor` reuses it to read the window's
    /// app name + current tags.
    func findRenderedWindow(_ id: WindowID) -> (Window, String?)? {
        for ws in lastWorkspaces {
            if let w = ws.windows.first(where: { $0.id == id }) {
                return (w, ws.name)        // assigned: the ws name (may be "")
            }
        }
        // (The §G orphan-rescue lookup that used to sit here is gone with the
        // orphan concept — t-6rbc. `lastWorkspaces` IS the universe: a window
        // facet manages is in a workspace, so a window absent from it is a
        // window facet does not manage.)
        return nil
    }
}
