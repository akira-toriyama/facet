import Testing
@testable import FacetCore

/// `FacetConfig.effectiveWorkspaceList` — the SECTION-INACTIVE edges
/// complementing `EffectiveWorkspaceListNamingTests` (section-active naming). The
/// section model engages ONLY when a desktop carries ≥1 spatial (non-`unassigned`)
/// section (`isSectionModelActive`); a config that has sections but NONE that seed
/// a workspace cell — an `unassigned`-only receptacle or an empty array — must
/// DEGRADE to the default unnamed slots. These are the load-bearing
/// "sections present, model still off" branches.
/// (The retired section-lens edge — lens-only sections degrading — is gone: every
/// `[[desktop.N.section]]` is now a workspace cell, t-ec9s.)
/// Pure; CI-only (CLT can't run `swift test`).
struct EffectiveWorkspaceListSectionEdgeTests {

    // MARK: - sections present, but no workspace cell → legacy default

    @Test func unassignedOnlySectionsDoNotActivateModel() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [DesktopSection(label: "Other",
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
        c.macDesktopSectionConfigs = [1: [DesktopSection()]]
        // The section model is a per-ordinal opt-in; an unresolvable ordinal
        // falls back to default slots.
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: nil)
        #expect(list.count == FacetConfig.defaultWorkspaceCount)
        #expect(list.allSatisfy { $0.config.name.isEmpty })
    }
}
