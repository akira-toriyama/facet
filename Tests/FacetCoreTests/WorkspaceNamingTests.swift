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

    // MARK: - display label (emoji + English word; identity stays bare emoji)

    func testWordsArrayMatchesPoolLength() {
        XCTAssertEqual(WorkspaceNaming.words.count, WorkspaceNaming.pool.count)
    }

    func testIdentityNamesAreSpaceFree() {
        // The identity name (what --focus / DNC / match see) must never carry
        // a space — that is the whole point of the identity/display split.
        for i in [0, 1, 39, 40, 81] {
            XCTAssertFalse(WorkspaceNaming.name(forIndex: i).contains(" "))
        }
    }

    func testDisplayLabelDecoratesPoolEmoji() {
        XCTAssertEqual(
            WorkspaceNaming.displayLabel(forName: WorkspaceNaming.pool[0]),
            "\(WorkspaceNaming.words[0]) \(WorkspaceNaming.pool[0])")
        let i = 20
        XCTAssertEqual(
            WorkspaceNaming.displayLabel(forName: WorkspaceNaming.pool[i]),
            "\(WorkspaceNaming.words[i]) \(WorkspaceNaming.pool[i])")
    }

    func testDisplayLabelKeepsWrapSuffix() {
        // Identity wrap "<emoji>2" → display "Word2 <emoji>" (emoji last).
        let wrapped = WorkspaceNaming.name(forIndex: WorkspaceNaming.pool.count)
        XCTAssertEqual(
            WorkspaceNaming.displayLabel(forName: wrapped),
            "\(WorkspaceNaming.words[0])2 \(WorkspaceNaming.pool[0])")
    }

    func testDisplayLabelPassesThroughNonPoolNames() {
        XCTAssertEqual(WorkspaceNaming.displayLabel(forName: ""), "")
        XCTAssertEqual(WorkspaceNaming.displayLabel(forName: "MyProj"), "MyProj")
        XCTAssertEqual(WorkspaceNaming.displayLabel(forName: "Proj2"), "Proj2")
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

    /// §A: a non-empty workspace `label` NAMES the workspace from config (the
    /// old always-auto-named rule reversed); an empty label still falls back to
    /// the emoji auto-name.
    func testSectionWorkspaceListUsesLabelWhenSet() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            DesktopSection(type: .workspace, label: "Dev", layout: "bsp"),
            DesktopSection(type: .workspace),   // no label → auto-name
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].config.name, "Dev")          // named from config
        XCTAssertEqual(list[0].config.layout, "bsp")
        XCTAssertEqual(list[1].config.name,                 // empty → fallback
                       WorkspaceNaming.name(forIndex: 1))
    }

    /// §A edge: an empty-label slot's emoji auto-name DODGES a pool emoji a
    /// sibling claimed as an explicit `label`, so the two workspaces never
    /// share an effective name (name→index resolution is first-match).
    func testEmptyLabelAutoNameDodgesExplicitPoolEmojiLabel() {
        let emoji0 = WorkspaceNaming.name(forIndex: 0)   // what slot 0 would auto-take
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [
            DesktopSection(type: .workspace),                  // empty → would be emoji0
            DesktopSection(type: .workspace, label: emoji0),   // explicitly claims emoji0
        ]]
        let list = c.effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[1].config.name, emoji0)            // explicit label wins
        XCTAssertNotEqual(list[0].config.name, emoji0)         // slot 0 dodged away
        XCTAssertEqual(Set(list.map { $0.config.name }).count, 2)   // names unique
    }

    /// DEGRADE: a section-less config (or a desktop without a `type=workspace`
    /// section) takes the default-slot path — emoji naming never engages.
    func testDegradeUsesDefaultSlotsWhenSectionModelInactive() {
        let bare = FacetConfig().effectiveWorkspaceList(forMacDesktopOrdinal: 1)
        XCTAssertTrue(bare.allSatisfy { $0.config.name.isEmpty })
        XCTAssertFalse(bare.isEmpty)
    }
}
