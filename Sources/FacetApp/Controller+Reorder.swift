// Section drag-to-reorder commit (the Controller half). The tree / grid / rail
// hand over a dragged section id + an insertion boundary; the Controller mutates
// the session-only per-mac-desktop order override (`macDesktopSectionOrder`) and
// schedules a reconcile so the next `apply()` re-projects + re-permutes all three
// views (the override is applied to the PROJECTED result in `apply()`).
//
// DISPLAY-ONLY: no backend op runs here (windows never move — routing keys off
// `ws.index` / `sourceWorkspaceIndex`, not array position) and nothing is written
// to disk (config.toml stays read-only; a relaunch resets to config order). A
// no-op drop (boundary lands on the section's own slot) mutates nothing — the
// view just re-renders unchanged, mirroring `applyMove`'s "snap-back = do
// nothing". See `SectionOrder` for why the OUTPUT, not the config input, is
// permuted.

import FacetCore

extension Controller {
    /// Commit a reorder: move section `sectionID` to insertion BOUNDARY
    /// `boundary` (measured in the CURRENT display list's coordinate space —
    /// `0` = before the first row, `count` = after the last). Active mac
    /// desktop only (keyed by `currentMacDesktopOrdinal() ?? -1`).
    func reorderSection(move sectionID: String, toBoundary boundary: Int) {
        let key = currentMacDesktopOrdinal() ?? -1
        // The CURRENT display order of section ids — already reflects any
        // earlier reorder this session. Section model: the projected sections.
        // Degrade (no `[[desktop.N.section]]`): the workspace list keyed by
        // `"ws:<index>"`, re-permuted through the existing override so a second
        // drag composes on the first.
        let currentIDs: [String]
        if !lastSections.isEmpty {
            currentIDs = lastSections.map(\.id)
        } else {
            currentIDs = SectionOrder
                .applyWorkspaces(macDesktopSectionOrder[key], to: lastWorkspaces)
                .map { SectionOrder.workspaceID($0.index) }
        }
        let newOrder = SectionOrder.reorder(currentIDs, move: sectionID,
                                            toBoundary: boundary)
        guard newOrder != currentIDs else { return }   // no-op drop → no churn
        macDesktopSectionOrder[key] = newOrder
        scheduleReconcile(after: 0)
    }
}
