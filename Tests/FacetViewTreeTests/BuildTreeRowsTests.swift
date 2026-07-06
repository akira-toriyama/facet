import XCTest
import FacetCore
@testable import FacetViewTree

final class BuildTreeRowsTests: XCTestCase {
    func testCompositeIDDistinguishesSameWindowInTwoGroups() {
        let wid = WindowID(serverID: 42)
        let a = TreeItemID.window(group: 0, wid)
        let b = TreeItemID.window(group: 1, wid)
        XCTAssertNotEqual(a, b)                       // same window, two sections
        XCTAssertEqual(a, .window(group: 0, wid))     // stable
        XCTAssertNotEqual(TreeItemID.header("ws:0"), .header("ws:1"))
    }
}

// MARK: - Task 3: buildTreeRows (headers + window rows)

extension BuildTreeRowsTests {
    // NOTE: `Window.init` order is id/pid/appName/title/isFocused/isFloating/frame,
    // then defaulted isOnscreen/isMaster/bundleId/mark/isSticky/scratchpad/tags —
    // pass only the non-defaulted head (the plan's helper mis-ordered bundleId).
    fileprivate func win(_ id: Int, _ app: String, _ title: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: false, frame: nil)
    }
    fileprivate func sec(_ id: String, _ label: String, _ type: ProjectedSectionType,
                         _ wins: [Window], src: Int?) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: wins,
                         sourceWorkspaceIndex: src, sectionType: type)
    }

    func testHeaderThenWindowRows() {
        let rows = buildTreeRows(
            sections: [sec("ws:0", "1", .workspace, [win(1, "Safari", "GitHub")], src: 0)],
            query: "")
        XCTAssertEqual(rows.count, 2)
        guard case .header(.workspace, nil) = rows[0].kind else { return XCTFail() }
        XCTAssertEqual(rows[0].id, .header("ws:0"))
        XCTAssertEqual(rows[0].primary, "workspace · 1")
        guard case .window(pid: 1) = rows[1].kind else { return XCTFail() }
        XCTAssertEqual(rows[1].id, .window(group: 0, WindowID(serverID: 1)))
        XCTAssertEqual(rows[1].primary, "Safari")
        XCTAssertEqual(rows[1].secondary, "GitHub")
    }

    func testGroupOrdinalIncrementsPerSection() {
        let w = win(1, "Safari", "GitHub")
        let rows = buildTreeRows(sections: [
            sec("ws:0", "1", .workspace, [w], src: 0),
            sec("section:0:dev", "dev", .lens, [w], src: nil),   // same window, lens
        ], query: "")
        XCTAssertEqual(rows[1].id, .window(group: 0, WindowID(serverID: 1)))
        XCTAssertEqual(rows[3].id, .window(group: 1, WindowID(serverID: 1)))
    }

    func testFuzzyFilterDropsNonMatchesAndEmptySections() {
        let rows = buildTreeRows(sections: [
            sec("ws:0", "1", .workspace,
                [win(1, "Safari", "GitHub"), win(2, "Terminal", "zsh")], src: 0),
            sec("ws:1", "2", .workspace, [win(3, "Notes", "todo")], src: 1),
        ], query: "saf")
        // WS1 keeps only Safari; WS2 has no match → whole section dropped.
        XCTAssertEqual(rows.map(\.primary), ["workspace · 1", "Safari"])
    }

    func testHeaderLabelsPerKind() {
        let rows = buildTreeRows(sections: [
            sec("section:0:dev", "dev", .lens, [], src: nil),
            sec("unassigned:0", "spare", .unassigned, [win(9, "X", "")], src: nil),
        ], query: "")
        XCTAssertEqual(rows[0].primary, "lens · dev")
        XCTAssertEqual(rows[1].primary, "unassigned · spare")
    }
}
