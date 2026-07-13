// What the user picked inside the rail carousel — mirrors `GridPick`
// (FacetViewGrid) so the Controller routes both overview surfaces through
// the same `activateSection` throughline (EX-2b). Replaces the rail's old
// `onPick(Int)` + `onPickWindow` pair.
//
//   • workspace  : a workspace cell's empty area / header / browse commit
//   • window     : a specific window thumb — `homeWorkspaceIndex` is the
//                  WINDOW's home WS (0-based), resolved from the live snapshot
//                  (`windowHomeWS`), NOT the cell's `wsIndex`.

import FacetCore

public enum RailPick: Sendable {
    case workspace(workspaceIndex: Int)
    case window(homeWorkspaceIndex: Int, pid: Int, windowID: WindowID)
}
