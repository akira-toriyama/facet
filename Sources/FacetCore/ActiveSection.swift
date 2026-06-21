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
    /// The active `type="lens"` section, keyed by its config `label`.
    case lens(String)

    /// The lens label when a lens section is active, else `nil`. Lets
    /// lens-only readers (`currentSectionLens()`, the tree `activeLens`
    /// highlight) derive their value from the unified concept.
    public var lensLabel: String? {
        if case .lens(let label) = self { return label }
        return nil
    }
}
