import XCTest
@testable import FacetCore

/// The opt-in management gate (`isMacDesktopManaged`) + the section-model
/// gate (`isSectionModelActive`) — the section/lens model's PR2. A
/// section-only config (the model's intended shape — workspaces auto-named,
/// user writes only sections) must be recognised as managed; the all-empty
/// default must stay byte-identical. CI-only (CLT can't run `swift test`).
final class ManagementGateTests: XCTestCase {

    private func wsSection() -> DesktopSection { DesktopSection(type: .workspace) }
    private func lensSection() -> DesktopSection {
        DesktopSection(type: .lens, label: "Web", match: "tag~=web")
    }

    // MARK: - default (byte-identical degrade)

    func testSectionlessConfigManagedEverywhere() {
        let c = FacetConfig()  // no [desktop.N], no [[desktop.N.section]]
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 1))
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 7))
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: nil))
        XCTAssertFalse(c.isSectionModelActive(ordinal: 1))
        XCTAssertFalse(c.isSectionModelActive(ordinal: nil))
    }

    // MARK: - section-only opt-in (the BLOCKER fix)

    func testSectionOnlyConfigIsOptIn() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [wsSection(), lensSection()]]
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 1),
                      "a desktop with sections is managed")
        XCTAssertFalse(c.isMacDesktopManaged(ordinal: 2),
                       "section presence makes facet opt-in (desktop 2 untouched)")
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: nil))
        XCTAssertTrue(c.isSectionModelActive(ordinal: 1),
                      "a type=workspace section activates the model")
        XCTAssertFalse(c.isSectionModelActive(ordinal: 2))
        XCTAssertFalse(c.isSectionModelActive(ordinal: nil),
                       "section model is a per-ordinal opt-in")
    }

    /// The opt-in gate keys on per-ordinal MEMBERSHIP, not a `min..max` range
    /// or a count: two NON-contiguous configured ordinals (1 and 3) leave the
    /// gap (2) and the tail (4) unmanaged. Guards against a future
    /// range-based regression (`isMacDesktopManaged` does `sections[ordinal]
    /// != nil`).
    func testOptInKeysOnPerOrdinalMembership() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [wsSection()], 3: [wsSection()]]
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 1))
        XCTAssertFalse(c.isMacDesktopManaged(ordinal: 2),
                       "the gap between configured ordinals is hands-off")
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 3))
        XCTAssertFalse(c.isMacDesktopManaged(ordinal: 4),
                       "past the highest configured ordinal is hands-off")
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: nil))
    }

    /// A desktop with ONLY lens sections (no workspace section) is MANAGED
    /// (opt-in fires on any section), but the section MODEL is not active
    /// (no workspace substrate from sections → falls back to default slots).
    func testLensOnlySectionManagedButModelInactive() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [lensSection()]]
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 1))
        XCTAssertFalse(c.isSectionModelActive(ordinal: 1))
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
    func testWorkspaceBoardActivatesModel() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [wsBoard(), lensBoard()]]
        XCTAssertTrue(c.isSectionModelActive(ordinal: 1),
                      "a workspace board activates the model on a tab-only config")
        XCTAssertFalse(c.isSectionModelActive(ordinal: 2),
                       "the board model is a per-ordinal opt-in")
        XCTAssertFalse(c.isSectionModelActive(ordinal: nil))
    }

    /// The gate is board-INDEPENDENT — a config property, not the current
    /// selection. A workspace board ANYWHERE in the tab list activates the
    /// model, even when it isn't board 0 (the selected board may be a lens
    /// board, yet the substrate still exists).
    func testWorkspaceBoardActivatesRegardlessOfOrder() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [lensBoard(), wsBoard()]]
        XCTAssertTrue(c.isSectionModelActive(ordinal: 1))
    }

    /// A tab config with ONLY lens boards (no workspace substrate) does NOT
    /// activate the model — mirrors the flat lens-only rule.
    func testLensOnlyBoardsDoNotActivateModel() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [lensBoard()]]
        XCTAssertFalse(c.isSectionModelActive(ordinal: 1))
    }
}
