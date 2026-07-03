import Testing
@testable import FacetCore

/// The opt-in management gate (`isMacDesktopManaged`) + the section-model
/// gate (`isSectionModelActive`) — the section/lens model's PR2. A
/// section-only config (the model's intended shape — workspaces auto-named,
/// user writes only sections) must be recognised as managed; the all-empty
/// default must stay byte-identical. CI-only (CLT can't run `swift test`).
struct ManagementGateTests {

    private func wsSection() -> DesktopSection { DesktopSection(type: .workspace) }
    private func lensSection() -> DesktopSection {
        DesktopSection(type: .lens, label: "Web", match: "tag~=web")
    }

    // MARK: - default (byte-identical degrade)

    @Test func sectionlessConfigManagedEverywhere() {
        let c = FacetConfig()  // no [desktop.N], no [[desktop.N.section]]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(c.isMacDesktopManaged(ordinal: 7))
        #expect(c.isMacDesktopManaged(ordinal: nil))
        #expect(!c.isSectionModelActive(ordinal: 1))
        #expect(!c.isSectionModelActive(ordinal: nil))
    }

    // MARK: - section-only opt-in (the BLOCKER fix)

    @Test func sectionOnlyConfigIsOptIn() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [wsSection(), lensSection()]]
        #expect(c.isMacDesktopManaged(ordinal: 1),
                "a desktop with sections is managed")
        #expect(!c.isMacDesktopManaged(ordinal: 2),
                "section presence makes facet opt-in (desktop 2 untouched)")
        #expect(c.isMacDesktopManaged(ordinal: nil))
        #expect(c.isSectionModelActive(ordinal: 1),
                "a type=workspace section activates the model")
        #expect(!c.isSectionModelActive(ordinal: 2))
        #expect(!c.isSectionModelActive(ordinal: nil),
                "section model is a per-ordinal opt-in")
    }

    /// The opt-in gate keys on per-ordinal MEMBERSHIP, not a `min..max` range
    /// or a count: two NON-contiguous configured ordinals (1 and 3) leave the
    /// gap (2) and the tail (4) unmanaged. Guards against a future
    /// range-based regression (`isMacDesktopManaged` does `sections[ordinal]
    /// != nil`).
    @Test func optInKeysOnPerOrdinalMembership() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [wsSection()], 3: [wsSection()]]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isMacDesktopManaged(ordinal: 2),
                "the gap between configured ordinals is hands-off")
        #expect(c.isMacDesktopManaged(ordinal: 3))
        #expect(!c.isMacDesktopManaged(ordinal: 4),
                "past the highest configured ordinal is hands-off")
        #expect(c.isMacDesktopManaged(ordinal: nil))
    }

    /// A desktop with ONLY lens sections (no workspace section) is MANAGED
    /// (opt-in fires on any section), but the section MODEL is not active
    /// (no workspace substrate from sections → falls back to default slots).
    @Test func lensOnlySectionManagedButModelInactive() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [lensSection()]]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isSectionModelActive(ordinal: 1))
    }

    // MARK: - board model (t-wrd2 / W2.5): a tab config activates the gate

    private func wsBoard() -> DesktopTab {
        DesktopTab(type: .workspace, label: "Spaces", sections: [wsSection()])
    }
    private func lensBoard() -> DesktopTab {
        DesktopTab(type: .lens, label: "Views", sections: [lensSection()])
    }

    /// A tab-only config (no flat `[[desktop.N.section]]`) with a workspace
    /// board ACTIVATES the section model. This is the keystone of the visible
    /// board switch (W2.5): until the gate is board-aware, a tab-only config is
    /// `gate=false`, so the projection degrades to default slots and a
    /// `facet board --focus` is invisible.
    @Test func workspaceBoardActivatesModel() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [wsBoard(), lensBoard()]]
        #expect(c.isSectionModelActive(ordinal: 1),
                "a workspace board activates the model on a tab-only config")
        #expect(!c.isSectionModelActive(ordinal: 2),
                "the board model is a per-ordinal opt-in")
        #expect(!c.isSectionModelActive(ordinal: nil))
    }

    /// The gate is board-INDEPENDENT — a config property, not the current
    /// selection. A workspace board ANYWHERE in the tab list activates the
    /// model, even when it isn't board 0 (the selected board may be a lens
    /// board, yet the substrate still exists).
    @Test func workspaceBoardActivatesRegardlessOfOrder() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [lensBoard(), wsBoard()]]
        #expect(c.isSectionModelActive(ordinal: 1))
    }

    /// A tab config with ONLY lens boards (no workspace substrate) does NOT
    /// activate the model — mirrors the flat lens-only rule.
    @Test func lensOnlyBoardsDoNotActivateModel() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [lensBoard()]]
        #expect(!c.isSectionModelActive(ordinal: 1))
    }

    // MARK: - M1: the opt-in MANAGEMENT gate must see tab configs too

    /// A tab-only config (no flat `[[desktop.N.section]]`) opts facet in just
    /// like a section config: the configured ordinal is managed, the rest are
    /// hands-off. Before M1, `isMacDesktopManaged` read only the flat dict, so
    /// an empty flat dict made it return `true` for EVERY ordinal — facet would
    /// adopt + default-slot-seed every unconfigured desktop.
    @Test func tabOnlyConfigIsOptIn() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [wsBoard(), lensBoard()]]
        #expect(c.isMacDesktopManaged(ordinal: 1),
                "a desktop with boards is managed")
        #expect(!c.isMacDesktopManaged(ordinal: 2),
                "tab presence makes facet opt-in (desktop 2 untouched)")
        #expect(c.isMacDesktopManaged(ordinal: nil))
    }

    /// Opt-in keys on the UNION of section + tab ordinals: flat on desktop 1,
    /// tabs on desktop 3 → both managed, the gap (2) and tail (4) hands-off.
    @Test func managedKeysOnUnionOfSectionAndTabOrdinals() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [wsSection()]]
        c.macDesktopTabConfigs = [3: [wsBoard()]]
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isMacDesktopManaged(ordinal: 2))
        #expect(c.isMacDesktopManaged(ordinal: 3))
        #expect(!c.isMacDesktopManaged(ordinal: 4))
    }
}
