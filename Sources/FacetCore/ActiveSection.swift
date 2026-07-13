/// The active-section concept: the active workspace (the always-present
/// spatial slot). Since the section-lens ACTIVATE concept was retired (t-ec9s),
/// a workspace is the only thing that is ever "active" — the enum stays a
/// single-case value so the `activateSection` throughline keeps one vocabulary.
/// See docs/glossary.md `### active section`.
public enum ActiveSection: Equatable, Sendable {
    /// The active workspace, by **1-based** index — matches
    /// `WorkspaceCatalog.activeIndex` and the user-facing `facet workspace
    /// --focus N` ordinal. The adapter converts to `switchWorkspace`'s
    /// 0-based convention at the seam; the `[Workspace]` snapshot's
    /// `index` is also 0-based, so a `+1` is needed when deriving from it.
    case workspace(Int)
}

/// EX-2b: the stable `ProjectedSection.id` of the **lit** section — the
/// single-highlight authority shared by the overview surfaces. Matches the
/// `overviewCellSources` highlight rule exactly:
///   • the workspace section whose source index is `activeIndex`;
///   • degrade (no section model ⇒ empty `sections`) ⇒ `"ws:<activeIndex>"`.
/// `nil` when nothing is lit (no active index, or no workspace section carries
/// it). Pure — used by the Controller's persistent-rail re-centre to follow the
/// active section across reconciles.
///
/// §A: the lit section is identified by its **stable section id**
/// (`ProjectedSection.id`), not the display label — a non-unique / empty
/// label can't re-centre the wrong section.
public func activeSectionID(activeIndex: Int?,
                            sections: [ProjectedSection]) -> String? {
    guard let idx = activeIndex else { return nil }
    if sections.isEmpty { return "ws:\(idx)" }
    return sections.first {
        $0.sectionType == .workspace && $0.sourceWorkspaceIndex == idx
    }?.id
}
