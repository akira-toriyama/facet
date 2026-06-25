// Display caption for a section header / cell — shared by the grid, rail,
// and tree so the same caption renders identically in every view. The
// section's 1-based display index (tree order) is ALWAYS shown; an optional
// label follows in parens. §D: replaces the old `workspaceShortLabel`
// ("WS<n>" / "workspace " prefix-strip / emoji-pool) — unnamed sections are
// addressed by their index, named ones read "index (label)". Applies to
// every section type (workspace / lens / unassigned) so `facet section
// --focus N` and the on-screen caption agree.
//
// Pure / display-only: routing / CLI / config keep the section's stable id
// + raw label; only the caption composes index + label.

/// `index` (when `label` is empty) or `index (label)`. `index` is the FINAL
/// 1-based value — callers pass the tree-display position directly (no
/// internal `+1`); a 0-based source index must be incremented at the call
/// site.
public func sectionDisplayLabel(index: Int, label: String) -> String {
    label.isEmpty ? "\(index)" : "\(index) (\(label))"
}
