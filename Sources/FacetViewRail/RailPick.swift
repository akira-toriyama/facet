// What the user picked inside the rail carousel — mirrors `GridPick`
// (FacetViewGrid) so the Controller routes both overview surfaces through
// the same `activateSection` throughline (EX-2b). Replaces the rail's old
// `onPick(Int)` + `onPickWindow` pair.
//
//   • workspace : a workspace cell's empty area / header / browse commit
//   • lens      : a lens-section cell → activate that lens
//   • window    : a specific window thumb — `homeWorkspaceIndex` is the
//                 WINDOW's home WS (0-based), resolved from the live snapshot
//                 (`windowHomeWS`), NOT the cell's `wsIndex` (a window thumb
//                 may sit inside a lens cell whose `wsIndex` is −1).

import FacetCore

public enum RailPick: Sendable {
    case workspace(workspaceIndex: Int)
    /// §A: keyed by stable section id (`ProjectedSection.id`), mirrors `GridPick`.
    case lens(sectionID: String)
    /// §G: an unassigned-section cell was picked → FOCUS ITS FIRST WINDOW (or
    /// do nothing if empty). Keyed by stable section id like lens; the
    /// Controller routes it to `focusFirstWindow(inSectionID:)` — mirrors
    /// `GridPick.unassigned`.
    case unassigned(sectionID: String)
    case window(homeWorkspaceIndex: Int, pid: Int, windowID: WindowID)
}
