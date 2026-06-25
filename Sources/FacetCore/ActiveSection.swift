/// The single active-section concept (EX-1): exactly one section is active
/// at a time — a `type="lens"` section (cross-workspace union) when one is
/// set, else the active workspace (the always-present spatial slot). The
/// catalog enforces the XOR invariant structurally (every workspace switch
/// nulls the active lens, EX-0.4); this enum names it so all three layers
/// share one vocabulary instead of "`activeIndex: Int` + `activeSectionLens:
/// String?`". See docs/glossary.md `### active section`.
public enum ActiveSection: Equatable, Sendable {
    /// The active workspace, by **1-based** index — matches
    /// `WorkspaceCatalog.activeIndex` and the user-facing `facet workspace
    /// --focus N` ordinal. The adapter converts to `switchWorkspace`'s
    /// 0-based convention at the seam; the `[Workspace]` snapshot's
    /// `index` is also 0-based, so a `+1` is needed when deriving from it.
    case workspace(Int)
    /// The active `type="lens"` section, keyed by its **stable section id**
    /// (`"section:<declOrder>:<label>"` — `ProjectedSection.id`). A0 moved the
    /// lens identity off the raw `label` (which becomes optional / non-unique in
    /// the section-label campaign) onto the declOrder-embedded id; the label is
    /// now display-only (derive it with `lensLabel`). The id↔label map is 1:1
    /// while labels are unique + non-empty, so this stays behaviour-preserving.
    case lens(String)

    /// The active lens's stable section id, else `nil`. The raw `.lens` payload
    /// — the identity used for routing / highlight matching.
    public var lensID: String? {
        if case .lens(let id) = self { return id }
        return nil
    }

    /// The active lens's display **label**, parsed out of its stable id, else
    /// `nil`. Lets display-only readers (`currentSectionLens()`, the tree
    /// `activeLens` highlight) keep showing a label while identity is keyed on
    /// the id. `nil` if no lens is active OR the id is malformed (cannot happen
    /// for an id minted by `FilterProjection`).
    public var lensLabel: String? {
        guard case .lens(let id) = self else { return nil }
        return ApplyResolver.parseSectionID(id)?.label
    }
}

/// EX-2b: the stable `ProjectedSection.id` of the **lit** section — the
/// single-highlight authority shared by the overview surfaces. Matches the
/// `overviewCellSources` XOR exactly:
///   • an active lens lights its lens cell (id `"section:<order>:<label>"`);
///   • otherwise the workspace section whose source index is `activeIndex`;
///   • degrade (no section model ⇒ empty `sections`) ⇒ `"ws:<activeIndex>"`.
/// `nil` when nothing is lit (no active index, or an active lens with no
/// matching section). Pure — used by the Controller's persistent-rail
/// re-centre to follow the active section across reconciles.
public func activeSectionID(activeLens: String?, activeIndex: Int?,
                            sections: [ProjectedSection]) -> String? {
    if let lens = activeLens {
        return sections.first { $0.sectionType == .lens && $0.label == lens }?.id
    }
    guard let idx = activeIndex else { return nil }
    if sections.isEmpty { return "ws:\(idx)" }
    return sections.first {
        $0.sectionType == .workspace && $0.sourceWorkspaceIndex == idx
    }?.id
}
