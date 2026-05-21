// What the user picked inside the overview grid. The workspace
// case fires for clicks on a cell's empty area; the window case
// fires for clicks on a specific window thumb inside a cell
// (z-order: window thumbs draw last so they win the more-specific
// hit).

import FacetCore

public enum GridPick: Sendable {
    case workspace(workspaceIndex: Int)
    case window(workspaceIndex: Int, pid: Int, windowID: WindowID)
}
