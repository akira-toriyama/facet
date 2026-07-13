// What the user picked inside the overview grid. The workspace
// case fires for clicks on a cell's empty area; the window case
// fires for clicks on a specific window thumb inside a cell
// (z-order: window thumbs draw last so they win the more-specific
// hit).

import FacetCore

public enum GridPick: Sendable {
    case workspace(workspaceIndex: Int)
    /// §G: a NON-workspace section cell was picked → FOCUS ITS FIRST WINDOW
    /// (or do nothing if empty). Keyed by its **stable section id**
    /// (`ProjectedSection.id`), not the display label (which may be empty /
    /// non-unique). The Controller routes it to `focusFirstWindow(inSectionID:)`
    /// — no workspace switch (a receptacle has none behind it).
    ///
    /// There is no `.lens` sibling: a lens desktop is TREE-ONLY (the grid
    /// loud-rejects there), `FilterProjection.project` — the grid's only
    /// source — never mints a `.lens` section, and `hideGrid` now drops
    /// `gridView` synchronously so a travelling overlay can't be fed one
    /// mid-fade either. The pick it would have carried was identical to this
    /// one anyway once the section-lens ACTIVATE concept was retired (t-ec9s).
    case unassigned(sectionID: String)
    /// A specific window thumb. `homeWorkspaceIndex` is the WINDOW's home WS
    /// (0-based), resolved from the live snapshot — NOT the cell's `wsIndex`
    /// (a receptacle cell's `wsIndex` is −1).
    case window(homeWorkspaceIndex: Int, pid: Int, windowID: WindowID)
}
