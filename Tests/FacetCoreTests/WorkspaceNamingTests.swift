import XCTest
@testable import FacetCore

/// `WorkspaceNaming` (the emoji auto-name pool) + the section-aware
/// `effectiveWorkspaceList` seed. CI-only (CLT can't run `swift test`).
final class WorkspaceNamingTests: XCTestCase {

    // MARK: - pure naming

    func testFirstNamesAreThePoolInOrder() {
        XCTAssertEqual(WorkspaceNaming.name(forIndex: 0), WorkspaceNaming.pool[0])
        XCTAssertEqual(WorkspaceNaming.name(forIndex: 1), WorkspaceNaming.pool[1])
        let last = WorkspaceNaming.pool.count - 1
        XCTAssertEqual(WorkspaceNaming.name(forIndex: last),
                       WorkspaceNaming.pool[last])
    }

    func testWrapPastPoolAddsNumericSuffix() {
        let n = WorkspaceNaming.pool.count
        // First wrap → pool[0] + "2".
        XCTAssertEqual(WorkspaceNaming.name(forIndex: n),
                       "\(WorkspaceNaming.pool[0])2")
        XCTAssertEqual(WorkspaceNaming.name(forIndex: n + 1),
                       "\(WorkspaceNaming.pool[1])2")
        // Second wrap → "3".
        XCTAssertEqual(WorkspaceNaming.name(forIndex: 2 * n),
                       "\(WorkspaceNaming.pool[0])3")
    }

    func testNegativeIndexClampsToFirst() {
        XCTAssertEqual(WorkspaceNaming.name(forIndex: -5), WorkspaceNaming.pool[0])
    }

    func testDeterministicAndAlwaysNonEmpty() {
        for i in [0, 3, 17, 40, 99, 500] {
            XCTAssertEqual(WorkspaceNaming.name(forIndex: i),
                           WorkspaceNaming.name(forIndex: i))
            XCTAssertFalse(WorkspaceNaming.name(forIndex: i).isEmpty)
        }
    }

    // MARK: - section-aware effectiveWorkspaceList

    /// A section-managed desktop seeds one slot per `type=workspace` section,
    /// auto-named by index, layout carried; lens/unassigned sections do NOT
    /// seed a workspace.
    func testSectionWorkspaceListAutoNamesByIndex() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            DesktopSection(type: .workspace, layout: "bsp"),
            DesktopSection(type: .lens, label: "Web", match: "tag~=web"),
            DesktopSection(type: .workspace),
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.count, 2)                       // 2 workspace sections
        XCTAssertEqual(list[0].index, 1)
        XCTAssertEqual(list[0].config.name, WorkspaceNaming.name(forIndex: 0))
        XCTAssertEqual(list[0].config.layout, "bsp")        // layout seed carried
        XCTAssertEqual(list[1].index, 2)
        XCTAssertEqual(list[1].config.name, WorkspaceNaming.name(forIndex: 1))
        XCTAssertNil(list[1].config.layout)
    }

    /// Section model wins over a coexisting `[desktop.N]` named seed for the
    /// same desktop (precedence; loud-logged at load).
    func testSectionModelWinsOverDesktopNameSeed() {
        var c = FacetConfig()
        c.macDesktopWorkspaceConfigs = [1: [1: WorkspaceConfig(name: "Dev", layout: "stack")]]
        c.macDesktopSectionConfigs = [1: [DesktopSection(type: .workspace)]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].config.name, WorkspaceNaming.name(forIndex: 0))  // emoji, not "Dev"
        XCTAssertNil(list[0].config.layout)                                     // section's, not "stack"
    }

    /// DEGRADE byte-identical: a section-less config (or one with only
    /// `[desktop.N]` seeds) takes the existing path — emoji naming never
    /// engages.
    func testDegradeUsesExistingPathUnchanged() {
        // section-less → default unnamed slots
        let bare = FacetConfig().effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertTrue(bare.allSatisfy { $0.config.name.isEmpty })
        XCTAssertFalse(bare.isEmpty)
        // [desktop.N]-named → those names, untouched
        var named = FacetConfig()
        named.macDesktopWorkspaceConfigs = [1: [1: WorkspaceConfig(name: "Dev")]]
        let list = named.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.map(\.config.name), ["Dev"])
    }
}
