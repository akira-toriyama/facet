// What the user picked inside the overview grid. The workspace
// case fires for clicks on a cell's empty area; the window case
// fires for clicks on a specific window thumb inside a cell
// (z-order: window thumbs draw last so they win the more-specific
// hit).

import FacetCore

public enum GridPick: Sendable {
    case workspace(workspaceIndex: Int)
    /// EX-2 / §A: a lens-section cell was picked → activate that lens, keyed
    /// by its **stable section id** (`ProjectedSection.id`), not the display
    /// label (which may be empty / non-unique). The Controller routes it
    /// straight to `activateLensID`, no label→id lookup.
    case lens(sectionID: String)
    /// A specific window thumb. `homeWorkspaceIndex` is the WINDOW's home WS
    /// (0-based), resolved from the live snapshot — NOT the cell's `wsIndex`
    /// (a window thumb may sit inside a lens cell whose `wsIndex` is −1).
    case window(homeWorkspaceIndex: Int, pid: Int, windowID: WindowID)
}
