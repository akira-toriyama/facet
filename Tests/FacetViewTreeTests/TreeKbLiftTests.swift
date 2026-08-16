// The keyboard lift's aim ladder (t-eedb HIGH: "aims from the top of the whole
// tree and steps one drop-candidate per press instead of one workspace").
//
// A WINDOW lift aims a COARSE per-section ladder — one `.onto(section header)`
// per workspace-backed section — because the commit is section-granular
// (window order inside a workspace is backend-derived): sill's fine per-row
// run made consecutive presses resolve to the SAME destination, so most
// presses appeared to change nothing. The aim also SEEDS on the lifted row's
// own section (old `kbDropWS = liftSourceWS()` parity), not candidate 0. A
// HEADER (chunk) lift keeps sill's gap ladder — that one was already coarse.
//
// Aim is observed through `commitDrag()` (public API): lift → step → commit
// hands back exactly the target the indicator showed.

import XCTest
import FacetCore
import FacetView
import ListCore
import FacetViewTree

@MainActor
final class TreeKbLiftTests: XCTestCase {

    private func win(_ id: Int, _ app: String, _ title: String,
                     focused: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: focused, isFloating: false, frame: nil)
    }
    private func sec(_ id: String, _ label: String, _ type: ProjectedSectionType,
                     _ wins: [Window], src: Int?) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: wins,
                         sourceWorkspaceIndex: src, sectionType: type)
    }
    private func vm(_ sections: [ProjectedSection],
                    active: Int? = nil) -> TreeViewModel {
        let m = TreeViewModel(palette: resolve(.terminal))
        m.apply(sections: sections, activeWorkspaceIndex: active)
        return m
    }

    /// ws0: [w1, w2] · ws1: [] (empty) · ws2: [w3]
    private var ladder: [ProjectedSection] {
        [sec("ws:0", "1", .workspace, [win(1, "Safari", "GitHub"),
                                       win(2, "Terminal", "zsh")], src: 0),
         sec("ws:1", "2", .workspace, [], src: 1),
         sec("ws:2", "3", .workspace, [win(3, "Mail", "Inbox")], src: 2)]
    }

    /// Lift `source`, press ↓ `presses` times, commit — the returned placement
    /// is the aim the indicator was showing.
    private func aimAfter(_ m: TreeViewModel, lift source: TreeItemID,
                          presses: Int) -> ListCore.DropPlacement<TreeItemID>? {
        m.parkCursor(on: source)
        m.liftCursor()
        for _ in 0..<presses { m.aimDrag(1) }
        return m.commitDrag()?.1.placement
    }

    func testWindowLiftSeedsAimOnItsOwnSection() {
        let m = vm(ladder)
        let aim = aimAfter(m, lift: .window(group: 2, WindowID(serverID: 3)),
                           presses: 0)
        XCTAssertEqual(aim, .onto(id: .header("ws:2")),
                       "the aim starts on the lifted row's OWN section, "
                       + "not the top of the tree")
    }

    func testOnePressStepsOneSectionRegardlessOfRowCount() {
        // ws:0 has 2 windows — the fine ladder needed several presses to
        // leave it; the coarse ladder crosses it in one.
        let m = vm(ladder)
        let aim = aimAfter(m, lift: .window(group: 0, WindowID(serverID: 1)),
                           presses: 1)
        XCTAssertEqual(aim, .onto(id: .header("ws:1")),
                       "one ↓ = the NEXT section, however many rows the "
                       + "current one has")
    }

    func testAimClampsAtTheLastWorkspaceSection() {
        let m = vm(ladder)
        let aim = aimAfter(m, lift: .window(group: 0, WindowID(serverID: 1)),
                           presses: 9)
        XCTAssertEqual(aim, .onto(id: .header("ws:2")), "clamped at the end")
    }

    func testNonWorkspaceSectionsAreNotDestinations() {
        // An isolate desktop's matched/holding sections carry no
        // sourceWorkspaceIndex and were never keyboard-aim destinations.
        var secs = ladder
        secs.append(sec("m", "matched", .matched, [win(9, "Notes", "memo")], src: nil))
        let m = vm(secs)
        let aim = aimAfter(m, lift: .window(group: 2, WindowID(serverID: 3)),
                           presses: 5)
        XCTAssertEqual(aim, .onto(id: .header("ws:2")),
                       "the ladder ends at the last WORKSPACE section — "
                       + "matched is not a destination")
    }

    func testCommitCarriesTheLiftedSource() {
        let m = vm(ladder)
        m.parkCursor(on: .window(group: 0, WindowID(serverID: 2)))
        m.liftCursor()
        m.aimDrag(1)
        let commit = m.commitDrag()
        XCTAssertEqual(commit?.0.sourceID, .window(group: 0, WindowID(serverID: 2)))
        XCTAssertFalse(m.isKbDragging, "commit clears the lift")
    }

    func testHeaderLiftKeepsTheGapLadder() {
        let m = vm(ladder)
        m.parkCursor(on: .header("ws:0"))
        m.liftCursor()
        guard let placement = m.commitDrag()?.1.placement else {
            return XCTFail("header lift did not aim")
        }
        if case .onto = placement {
            XCTFail("a header (chunk) lift aims at section GAPS (.between), "
                    + "not .onto — the chunk ladder was already coarse and stays")
        }
    }
}
