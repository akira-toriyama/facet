// What the user picked inside the rail carousel — mirrors `GridPick`
// (FacetViewGrid) so the Controller routes both overview surfaces through
// the same `activateSection` throughline (EX-2b). Replaces the rail's old
// `onPick(Int)` + `onPickWindow` pair.
//
//   • workspace  : a workspace cell's empty area / header / browse commit
//   • unassigned : a receptacle cell → focus its first window
//   • window     : a specific window thumb — `homeWorkspaceIndex` is the
//                  WINDOW's home WS (0-based), resolved from the live snapshot
//                  (`windowHomeWS`), NOT the cell's `wsIndex` (a receptacle
//                  cell's `wsIndex` is −1).

import FacetCore

public enum RailPick: Sendable {
    case workspace(workspaceIndex: Int)
    /// §G: a NON-workspace section cell was picked → FOCUS ITS FIRST WINDOW
    /// (or do nothing if empty). Keyed by stable section id
    /// (`ProjectedSection.id`); the Controller routes it to
    /// `focusFirstWindow(inSectionID:)` — mirrors `GridPick.unassigned`.
    ///
    /// There is no `.lens` sibling — see `GridPick` for why (a lens desktop is
    /// tree-only, `FilterProjection.project` mints no `.lens` section, and both
    /// overviews now drop their view synchronously on hide).
    case unassigned(sectionID: String)
    case window(homeWorkspaceIndex: Int, pid: Int, windowID: WindowID)
}
