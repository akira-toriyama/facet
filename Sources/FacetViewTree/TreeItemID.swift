import FacetCore

/// Stable identity for one tree row — *logical*, not positional, so a
/// selection survives the reconcile rebuild.
///
/// Sections are DISJOINT (t-ec9s: a window lives in exactly one), so a bare
/// `WindowID` would in fact be unique. `group` is in the key for what it
/// TELLS you, not to uniquify: it is the row's SECTION membership, which is
/// what the host resolves (`lastSections[group]`) to route a click —
/// `activateSection` vs `focusFirstWindow`, or inert on a lens desktop's
/// holding row. A bare `WindowID` cannot answer "which section is this row in?".
/// Header rows key on the stable `ProjectedSection.id`.
public enum TreeItemID: Hashable, Sendable {
    case header(String)                 // ProjectedSection.id
    case window(group: Int, WindowID)   // group = render-group ordinal
}
