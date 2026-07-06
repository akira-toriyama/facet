import FacetCore

/// Stable identity for one tree row. A window appears in EVERY section it
/// matches (multi-match), so the render-group ordinal is part of the key —
/// `WindowID` alone would collide across sections. Header rows key on the
/// stable `ProjectedSection.id`.
public enum TreeItemID: Hashable, Sendable {
    case header(String)                 // ProjectedSection.id
    case window(group: Int, WindowID)   // group = render-group ordinal
}
