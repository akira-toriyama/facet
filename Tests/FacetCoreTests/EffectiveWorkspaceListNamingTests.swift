import XCTest
@testable import FacetCore

/// The section-aware `effectiveWorkspaceList` naming seed (§A / §B). A
/// `type="workspace"` section's name is its optional `label`; an empty label
/// leaves the slot UNNAMED (`name == ""`) — displayed by its 1-based index,
/// since §B retired the emoji auto-name pool (`WorkspaceNaming`). CI-only (CLT
/// can't run XCTest). Section-INACTIVE degrade paths live in
/// `EffectiveWorkspaceListSectionEdgeTests`.
final class EffectiveWorkspaceListNamingTests: XCTestCase {

    /// One slot per `type=workspace` section, in order; an unnamed (empty-label)
    /// workspace's `config.name` is EMPTY (the view renders its 1-based index).
    /// lens / unassigned sections do NOT seed a workspace.
    func testSectionWorkspaceListUnnamedSlotsAreEmpty() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            DesktopSection(type: .workspace, layout: "bsp"),
            DesktopSection(type: .lens, label: "Web", match: "tag~=web"),
            DesktopSection(type: .workspace),
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.count, 2)                   // 2 workspace sections
        XCTAssertEqual(list[0].index, 1)
        XCTAssertTrue(list[0].config.name.isEmpty)      // unnamed → empty (§B)
        XCTAssertEqual(list[0].config.layout, "bsp")    // layout seed carried
        XCTAssertEqual(list[1].index, 2)
        XCTAssertTrue(list[1].config.name.isEmpty)
        XCTAssertNil(list[1].config.layout)
    }

    /// §A: a non-empty workspace `label` names the workspace from config; an
    /// empty label stays unnamed (empty name, §B).
    func testSectionWorkspaceListUsesLabelWhenSet() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            DesktopSection(type: .workspace, label: "Dev", layout: "bsp"),
            DesktopSection(type: .workspace),   // no label → unnamed
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].config.name, "Dev")      // named from config
        XCTAssertEqual(list[0].config.layout, "bsp")
        XCTAssertTrue(list[1].config.name.isEmpty)      // empty → unnamed (§B)
    }
}
