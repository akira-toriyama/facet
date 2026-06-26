// Section-model apply/un-apply DnD orchestration (PR8) — the Controller half
// of the tree's section-path MOVE (drag / kb-lift). The view hands over
// section IDs + the dest workspace index; the
// Controller resolves the executable plan with the PURE `ApplyResolver` over
// the LIVE section config (read FRESH here, matching `setActiveLens`'s
// discipline — a `ProjectedSection` carries no apply ops), then dispatches the op
// sequence on `cliQueue` and schedules one coalesced reconcile.
//
// Snap-back is "do nothing": an inert / stale / non-satisfying plan runs NO
// backend op, and because the section tree row is never hidden during the drag
// (only de-emphasised), the next reconcile re-projects the unchanged state —
// the row simply stays put. (Unlike grid/rail, there is no `OverviewPendingDrop`
// to roll back.)

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
    /// section config + last-rendered workspaces). `nil` ⇒ not section-model /
    /// window gone / inert — the caller does nothing (snap-back).
    private func resolveApplyPlan(windowID: WindowID, fromSectionID: String?,
                                  toSectionID: String, destWorkspaceIndex: Int?)
        -> ApplyResolver.Plan?
    {
        let ordinal = currentMacDesktopOrdinal()
        guard config.isSectionModelActive(ordinal: ordinal), let ord = ordinal
        else { return nil }
        let sections = config.effectiveMacDesktopSectionConfigs[ord] ?? []
        guard let (win, wsName) = findRenderedWindow(windowID) else { return nil }
        let plan = ApplyResolver.plan(
            window: win, workspaceName: wsName,
            fromSectionID: fromSectionID, toSectionID: toSectionID,
            destWorkspaceIndex: destWorkspaceIndex, in: sections)
        if plan.isInert {
            if let r = plan.reason { Log.debug("apply: inert — \(r)") }
            return nil
        }
        return plan
    }

    /// Dispatch a resolved plan's ops onto `cliQueue` in the frozen order
    /// (un-apply `removeTag`(s) → `setWorkspace` by index → forward apply in
    /// canonical order), then schedule a single coalesced reconcile. ONE
    /// `cliQueue.async` block so the multi-op sequence can't interleave with a
    /// refresh poll; each op yields `.refreshNeeded`, all coalesced by the one
    /// trailing `scheduleReconcile`. No inter-op sleep — these are focus-free
    /// single-window writes that settle synchronously on the serial queue.
    private func runApplyPlan(_ plan: ApplyResolver.Plan, on id: WindowID) {
        let bk = backend
        cliQueue.async {
            for op in plan.inverse {
                if case .removeTag(let t) = op {
                    _ = bk.removeTagSection(t, fromWindow: id)
                }
            }
            // EX-3: a ws→lens MOVE relocates the window OUT of its workspace
            // (迷子) via the dedicated primitive; a ws→ws MOVE uses the
            // 0-based wire index. The two are mutually exclusive (a lens dest
            // never carries a destWorkspaceIndex), but guard order makes that
            // explicit. Then the dest section's forward apply (tags etc.).
            if plan.relocateSourceToOrphan {
                bk.orphanWindow(id)
            } else if let dst = plan.destWorkspaceIndex {
                bk.moveWindow(id, toWorkspaceIndex: dst)
            }
            for op in plan.forward {
                switch op {
                case .addTag(let t):      _ = bk.addTagSection(t, toWindow: id)
                case .setFloating(let b): bk.setFloating(id, b)
                case .setSticky(let b):   bk.setSticky(id, b)
                case .setMaster(let b):   bk.setMaster(id, b)
                case .removeTag, .setWorkspace: break   // never present in forward
                }
            }
        }
        scheduleReconcile(after: 0.05)
    }

    /// The live window + its workspace name from the last rendered snapshot —
    /// the resolver needs the window's current workspace for the lens match
    /// invariant. Internal (not private): `openTagEditor` reuses it to read the
    /// window's app name + current tags.
    func findRenderedWindow(_ id: WindowID) -> (Window, String?)? {
        for ws in lastWorkspaces {
            if let w = ws.windows.first(where: { $0.id == id }) {
                return (w, ws.name)        // assigned: the ws name (may be "")
            }
        }
        // §G rescue: a window shown under the unassigned receptacle is a TRUE
        // orphan (in no workspace → absent from `lastWorkspaces`). Find it in
        // the orphan set so a drop onto a workspace resolves a real move plan.
        // `nil` name = orphan (no assignment), distinct from `""` (assigned to
        // an unnamed workspace) — the resolver's `not workspace` invariant.
        if let w = backend.orphanWindows().first(where: { $0.id == id }) {
            return (w, nil)
        }
        return nil
    }
}
