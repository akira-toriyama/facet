import XCTest
import FacetCore
import FacetView
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
            sec("section:0:dev", "dev", .matched, [w], src: nil),   // same window, lens
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

    /// The four kind words each answer ONE question — "what IS this section"
    /// (t-mqqw). `lens ·` is gone (a DESKTOP type had been leaking onto a
    /// section), and an isolate desktop's non-matching bucket says `holding ·`,
    /// not `unassigned ·` — those windows ARE assigned to workspaces, they just
    /// failed the `match`. `unassigned ·` survives only on a workspace desktop,
    /// where it is honest.
    func testHeaderLabelsPerKind() {
        let rows = buildTreeRows(sections: [
            sec("section:0:dev", "dev", .matched, [], src: nil),
            sec("holding:1", "held", .holding, [win(8, "Y", "")], src: nil),
            sec("unassigned:0", "spare", .unassigned, [win(9, "X", "")], src: nil),
        ], query: "")
        XCTAssertEqual(rows[0].primary, "matched · dev")
        XCTAssertEqual(rows[1].primary, "holding · held")
        XCTAssertEqual(rows[3].primary, "unassigned · spare")
    }
}

// MARK: - Task 4: badges + tag overflow

extension BuildTreeRowsTests {
    // Same init-order note as `win` — omit the defaulted `bundleId` (it sits
    // between isMaster and mark), pass the rest in declaration order.
    fileprivate func rich(_ id: Int, master: Bool = false, floating: Bool = false,
                          sticky: Bool = false, onscreen: Bool = true, mark: String? = nil,
                          scratch: String? = nil, tags: [String] = []) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: "A", title: "",
               isFocused: false, isFloating: floating, frame: nil,
               isOnscreen: onscreen, isMaster: master, mark: mark, isSticky: sticky,
               scratchpad: scratch, tags: tags)
    }
    fileprivate func badges(_ w: Window) -> [TreeBadge] {
        buildTreeRows(sections: [sec("ws:0", "1", .workspace, [w], src: 0)], query: "")[1].badges
    }

    func testStatusBadges() {
        XCTAssertEqual(badges(rich(1, master: true)), [TreeBadge(.master)])
        XCTAssertEqual(badges(rich(1, floating: true)), [TreeBadge(.float)])
        XCTAssertEqual(badges(rich(1, sticky: true)), [TreeBadge(.sticky)])
        XCTAssertEqual(badges(rich(1, onscreen: false)), [TreeBadge(.hidden)])
        // t-c6fm: an isolate-parked window shows as a NORMAL row — no badge (the
        // tree is an inventory, not a screen mirror; park is screen-only). Since
        // t-pvay that is STRUCTURAL, not a choice: `Window` carries no park flag,
        // so the tree cannot badge one even by accident. Nothing left to assert.
        XCTAssertEqual(badges(rich(1, mark: "a")), [TreeBadge(.mark, "a")])
        XCTAssertEqual(badges(rich(1, scratch: "shelf")), [TreeBadge(.scratchpad, "shelf")])
    }

    func testTagBadgesCapWithOverflow() {
        let b = badges(rich(1, tags: ["red", "green", "blue", "amber"]))
        // status badges (none) + 3 tag chips + a "+1" overflow badge
        XCTAssertEqual(b, [
            TreeBadge(.tag, "red"), TreeBadge(.tag, "green"), TreeBadge(.tag, "blue"),
            TreeBadge(.overflow, "+1"),
        ])
    }

    func testStatusBeforeTags() {
        let b = badges(rich(1, master: true, tags: ["x"]))
        XCTAssertEqual(b, [TreeBadge(.master), TreeBadge(.tag, "x")])
    }
}

// MARK: - Task 9: layout-mode subtitle (workspace headers only)

extension BuildTreeRowsTests {
    func testWorkspaceHeaderCarriesLayoutSubtitle() {
        let rows = buildTreeRows(
            sections: [sec("ws:0", "1", .workspace, [], src: 0)],
            query: "",
            layoutMode: { _ in "bsp" })
        guard case .header(.workspace, "bsp") = rows[0].kind else { return XCTFail() }
    }

    func testMatchedHeaderIgnoresLayoutSubtitle() {
        let rows = buildTreeRows(
            sections: [sec("section:0:dev", "dev", .matched, [win(1, "A", "")], src: nil)],
            query: "", layoutMode: { _ in "bsp" })
        guard case .header(.matched, nil) = rows[0].kind else { return XCTFail() }
    }

    func testUnassignedHeaderIgnoresLayoutSubtitle() {
        let rows = buildTreeRows(
            sections: [sec("unassigned:0", "spare", .unassigned, [win(9, "X", "")], src: nil)],
            query: "", layoutMode: { _ in "bsp" })
        guard case .header(.unassigned, nil) = rows[0].kind else { return XCTFail() }
    }
}

// MARK: - Task 6: TreeViewModel memoization (success-criterion 5)

@MainActor
extension BuildTreeRowsTests {
    func testPaletteMutationDoesNotRebuildItems() {
        let vm = TreeViewModel(palette: resolve(.terminal))      // any preset
        vm.apply(sections: [sec("ws:0", "1", .workspace, [win(1, "Safari", "GitHub")], src: 0)])
        let afterApply = vm.rowsRebuildCount             // == 1
        vm.palette = resolve(.dracula)                    // 30 Hz animator only touches palette
        XCTAssertEqual(vm.rowsRebuildCount, afterApply)  // listItems NOT rebuilt
    }
}
