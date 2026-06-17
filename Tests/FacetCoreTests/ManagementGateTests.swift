import XCTest
@testable import FacetCore

/// The opt-in management gate (`isMacDesktopManaged`) + the section-model
/// gate (`isSectionModelActive`) — the section/lens model's PR2. A
/// section-only config (the model's intended shape — workspaces auto-named,
/// user writes only sections) must be recognised as managed; the all-empty
/// default must stay byte-identical. CI-only (CLT can't run `swift test`).
final class ManagementGateTests: XCTestCase {

    private func ws() -> [Int: WorkspaceConfig] { [1: WorkspaceConfig(name: "Dev")] }
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

    // MARK: - legacy [desktop.N] opt-in (unchanged)

    func testWorkspaceConfigOnlyIsOptIn() {
        var c = FacetConfig()
        c.macDesktopWorkspaceConfigs = [1: ws()]
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 1))
        XCTAssertFalse(c.isMacDesktopManaged(ordinal: 2))   // opt-in: only 1
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: nil))  // nil always managed
        XCTAssertFalse(c.isSectionModelActive(ordinal: 1))  // no section model
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

    /// A desktop with ONLY lens sections (no workspace section) is MANAGED
    /// (opt-in fires on any section), but the section MODEL is not active
    /// (no workspace substrate from sections → falls back to default slots).
    func testLensOnlySectionManagedButModelInactive() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [lensSection()]]
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 1))
        XCTAssertFalse(c.isSectionModelActive(ordinal: 1))
    }

    // MARK: - coexistence ([desktop.N] + sections)

    func testCoexistenceManagedAndSectionModelActive() {
        var c = FacetConfig()
        c.macDesktopWorkspaceConfigs = [1: ws()]
        c.macDesktopSectionConfigs = [1: [wsSection()]]
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 1))
        XCTAssertTrue(c.isSectionModelActive(ordinal: 1),
                      "sections authoritative when both present")
    }

    // MARK: - tag mode disables the section gates

    func testTagModeDisablesSectionGates() {
        var c = FacetConfig()
        c.grouping = "tag"
        c.macDesktopSectionConfigs = [1: [wsSection()]]
        // effectiveMacDesktopSectionConfigs clamps to empty in tag mode →
        // the section signal vanishes from both gates.
        XCTAssertFalse(c.isSectionModelActive(ordinal: 1))
        // Section-only + tag mode + no [desktop.N] → both effective maps
        // empty → managed everywhere (byte-identical to a section-less
        // config; sections are silently inert in tag mode + loud-logged at
        // load()).
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 1))
        XCTAssertTrue(c.isMacDesktopManaged(ordinal: 9))
    }
}
