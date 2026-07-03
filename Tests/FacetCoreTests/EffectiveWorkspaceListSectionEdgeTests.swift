import Testing
@testable import FacetCore

/// `FacetConfig.effectiveWorkspaceList` — the SECTION-INACTIVE edges
/// complementing `EffectiveWorkspaceListNamingTests` (section-active naming). The
/// section model engages ONLY when a desktop carries ≥1 `type = "workspace"`
/// section (`isSectionModelActive`); a config that has sections but NONE of
/// the workspace kind — lens-only, unassigned-only, or an empty array — must
/// DEGRADE to the default unnamed slots. These are the load-bearing
/// "sections present, model still off" branches.
/// Pure; CI-only (CLT can't run `swift test`).
struct EffectiveWorkspaceListSectionEdgeTests {

    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }

    // MARK: - sections present, but no workspace section → legacy default

    @Test func lensOnlySectionsDoNotActivateModel() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            lens("Web", "tag~=web"),
            lens("Mail", "app=Mail"),
        ]]
        // No workspace section → model off → default unnamed slots (NOT an
        // empty list).
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == FacetConfig.defaultWorkspaceCount)
        #expect(list.allSatisfy { $0.config.name.isEmpty })
        #expect(list.allSatisfy { $0.config.layout == nil })
    }

    @Test func unassignedOnlySectionsDoNotActivateModel() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [DesktopSection(type: .workspace,
                                                         label: "Other",
                                                         unassigned: true)]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == FacetConfig.defaultWorkspaceCount)
        #expect(list.allSatisfy { $0.config.name.isEmpty })
    }

    @Test func emptySectionArrayDegradesToDefault() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: []]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        #expect(list.count == FacetConfig.defaultWorkspaceCount)
        #expect(list.allSatisfy { $0.config.name.isEmpty })
    }

    // MARK: - nil ordinal never activates the section model

    @Test func nilOrdinalIgnoresSectionsAndUsesDefault() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [DesktopSection(type: .workspace)]]
        // The section model is a per-ordinal opt-in; an unresolvable ordinal
        // falls back to default slots.
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: nil)
        #expect(list.count == FacetConfig.defaultWorkspaceCount)
        #expect(list.allSatisfy { $0.config.name.isEmpty })
    }
}
