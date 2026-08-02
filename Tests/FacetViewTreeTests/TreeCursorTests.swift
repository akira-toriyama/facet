// t-tsxg Task 10/11 — the SwiftUI tree's keyboard cursor + focus fill.
//
// `TreeViewModel.moveCursor`/`jumpSection` mirror the pure `KbNav` math the
// AppKit tree navigated with (`kbMoveTarget`/`kbJumpTarget` parity: anchor at
// the top when there is no cursor, clamp at the ends, jump lands on a group's
// first window else its header). `apply()` derives `selection` (the fill) from
// the projection's focused window scoped to the active section, unless the
// 0.85 s optimistic claim (`setOptimistic`) still holds — cursor ≠ selection,
// the facet tree invariant.

import XCTest
import FacetCore
import FacetView
@testable import FacetViewTree

@MainActor
final class TreeCursorTests: XCTestCase {

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

    // MARK: - moveCursor (kbMoveTarget parity)

    func testMoveAnchorsAtTopWithoutACursor() {
        let m = vm(ladder)
        m.moveCursor(1)
        XCTAssertEqual(m.highlight, .window(group: 0, WindowID(serverID: 1)),
                       "no cursor anchors at position 0, so +1 lands on row 1")
    }

    func testMoveWalksEveryRowAndClampsAtTheEnds() {
        let m = vm(ladder)
        m.seedCursor()                                     // row 0 (header ws:0)
        XCTAssertEqual(m.highlight, .header("ws:0"))
        m.moveCursor(-1)
        XCTAssertEqual(m.highlight, .header("ws:0"), "clamped at the top")
        for _ in 0..<10 { m.moveCursor(1) }                // way past the end
        XCTAssertEqual(m.highlight, .window(group: 2, WindowID(serverID: 3)),
                       "clamped at the bottom")
    }

    // MARK: - jumpSection (kbJumpTarget parity)

    func testJumpLandsOnNextGroupsFirstWindowElseHeader() {
        let m = vm(ladder)
        m.seedCursor()                                     // header ws:0 (group 0)
        m.jumpSection(1)
        XCTAssertEqual(m.highlight, .header("ws:1"),
                       "an empty group's target is its header")
        m.jumpSection(1)
        XCTAssertEqual(m.highlight, .window(group: 2, WindowID(serverID: 3)),
                       "a populated group's target is its FIRST window")
        m.jumpSection(1)
        XCTAssertEqual(m.highlight, .window(group: 2, WindowID(serverID: 3)),
                       "clamped at the last group")
        m.jumpSection(-1)
        XCTAssertEqual(m.highlight, .header("ws:1"))
    }

    // MARK: - seedCursor

    func testSeedPrefersTheSelectionAndKeepsAValidCursor() {
        let focused = [sec("ws:0", "1", .workspace,
                           [win(1, "Safari", "GitHub"),
                            win(2, "Terminal", "zsh", focused: true)], src: 0)]
        let m = vm(focused, active: 0)
        m.seedCursor()
        XCTAssertEqual(m.highlight, .window(group: 0, WindowID(serverID: 2)),
                       "the focused (selected) row seeds the cursor")
        m.moveCursor(-1)                                   // one row up → w1
        m.seedCursor()
        XCTAssertEqual(m.highlight, .window(group: 0, WindowID(serverID: 1)),
                       "a still-valid cursor survives re-entry")
    }

    // MARK: - focus fill (selection) derivation

    func testFocusFillScopedToTheActiveWorkspaceSection() {
        let sections = [
            sec("ws:0", "1", .workspace, [win(1, "Safari", "G", focused: true)], src: 0),
            sec("ws:1", "2", .workspace, [win(2, "Mail", "I", focused: true)], src: 1),
        ]
        let m = vm(sections, active: 1)
        XCTAssertEqual(m.selection, [.window(group: 1, WindowID(serverID: 2))],
                       "only the ACTIVE workspace's focused window fills")
    }

    func testIsolateSectionsKeepTheFocusFill() {
        let m = vm([sec("section:0:dev", "dev", .matched,
                        [win(1, "Safari", "G", focused: true)], src: nil)],
                   active: nil)
        XCTAssertEqual(m.selection, [.window(group: 0, WindowID(serverID: 1))],
                       "a sourceless (isolate) section keeps its focused fill")
    }

    // MARK: - optimistic hold (Task 11)

    func testOptimisticClaimWinsOverTheProjectionWhileHeld() {
        let m = vm(ladder, active: 0)
        let claim = TreeItemID.window(group: 2, WindowID(serverID: 3))
        m.setOptimistic(claim)
        XCTAssertEqual(m.selection, [claim], "the claim fills immediately")
        // A re-projection with a DIFFERENT focused window arrives inside the
        // 0.85 s hold — the claim must win (the backend focus-assert race).
        var racing = ladder
        racing[0] = sec("ws:0", "1", .workspace,
                        [win(1, "Safari", "GitHub", focused: true),
                         win(2, "Terminal", "zsh")], src: 0)
        m.apply(sections: racing, activeWorkspaceIndex: 0)
        XCTAssertEqual(m.selection, [claim],
                       "the optimistic hold beats the stale projection")
    }

    func testOptimisticClaimOnAVanishedRowClearsTheFill() {
        let m = vm(ladder, active: 0)
        m.setOptimistic(.window(group: 2, WindowID(serverID: 99)))
        m.apply(sections: ladder, activeWorkspaceIndex: 0)
        XCTAssertEqual(m.selection, [],
                       "a claim whose row vanished mid-hold shows no fill")
    }

    // MARK: - keyboard drag (facet-2 — host-driven lift/aim/commit)

    func testLiftWindowRowAimsAndCommits() {
        let m = vm(ladder)
        m.seedCursor(); m.moveCursor(1)                    // w1 (group 0)
        let w1 = TreeItemID.window(group: 0, WindowID(serverID: 1))
        XCTAssertEqual(m.highlight, w1)
        m.liftCursor()
        XCTAssertTrue(m.isKbDragging)
        m.aimDrag(1); m.aimDrag(1)
        guard let (ctx, target) = m.commitDrag() else { return XCTFail("no commit") }
        XCTAssertEqual(ctx.sourceID, w1)
        XCTAssertEqual(ctx.memberIDs, [w1], "a window lifts alone")
        XCTAssertNotNil(target)
        XCTAssertFalse(m.isKbDragging, "commit clears the lift")
    }

    func testLiftHeaderChunksItsWholeSection() {
        let m = vm(ladder)
        m.seedCursor()                                     // header ws:0
        m.liftCursor()
        XCTAssertTrue(m.isKbDragging)
        guard let (ctx, target) = m.commitDrag() else { return XCTFail("no commit") }
        XCTAssertEqual(ctx.sourceID, .header("ws:0"))
        XCTAssertEqual(ctx.memberIDs,
                       [.header("ws:0"),
                        .window(group: 0, WindowID(serverID: 1)),
                        .window(group: 0, WindowID(serverID: 2))],
                       "a header lifts its whole section chunk")
        // Chunk candidates are section gaps only — the first is a BETWEEN.
        guard case .between = target.placement else {
            return XCTFail("chunk aims at gaps, got \(target.placement)")
        }
    }

    func testLiftSurvivesAReapplyAndCancelsWhenTheSourceVanishes() {
        let m = vm(ladder)
        m.seedCursor(); m.moveCursor(1)                    // w1
        m.liftCursor()
        m.apply(sections: ladder, activeWorkspaceIndex: nil)   // the 2 s refresh
        XCTAssertTrue(m.isKbDragging, "a reconcile must not drop the user's lift")
        var gone = ladder
        gone[0] = sec("ws:0", "1", .workspace,
                      [win(2, "Terminal", "zsh")], src: 0)     // w1 closed
        m.apply(sections: gone, activeWorkspaceIndex: nil)
        XCTAssertFalse(m.isKbDragging, "a vanished source cancels the lift")
    }

    func testDragPreviewCarriesLiveSelectionAndHighlight() {
        let focused = [sec("ws:0", "1", .workspace,
                           [win(1, "Safari", "G", focused: true),
                            win(2, "Terminal", "z")], src: 0)]
        let m = vm(focused, active: 0)
        m.seedCursor()                                     // the focused row
        XCTAssertNil(m.dragPreview, "no preview while idle — live bindings drive")
        m.liftCursor()
        guard let p = m.dragPreview else { return XCTFail("lift renders via preview") }
        XCTAssertEqual(p.selection, m.selection,
                       "the preview must carry the live fill (it OVERRIDES bindings)")
        XCTAssertEqual(p.highlight, m.highlight)
        XCTAssertEqual(p.dragSource, m.highlight)
        XCTAssertNotNil(p.dropTarget)
    }

    // MARK: - renderedSections (the query-safe ordinal source)

    func testRenderedSectionsAlignWithEmittedGroupOrdinals() {
        let m = vm(ladder)
        m.setQuery("mail")                                 // only ws2's window matches
        XCTAssertEqual(m.renderedSections.map(\.id), ["ws:2"],
                       "zero-match sections drop from the rendered array too")
        XCTAssertEqual(m.rows.map(\.id),
                       [.header("ws:2"), .window(group: 0, WindowID(serverID: 3))],
                       "…so group 0 correctly indexes ws:2 in renderedSections")
        m.setQuery("")
        XCTAssertEqual(m.renderedSections.count, 3, "empty query restores all")
    }

    // MARK: - rowTop (the m-menu anchor)

    func testRowTopIsMonotonicFromZeroAndNilOffLadder() {
        let m = vm(ladder)
        XCTAssertEqual(m.rowTop(of: .header("ws:0")), 0)
        let tops = m.rows.compactMap { m.rowTop(of: $0.id) }
        XCTAssertEqual(tops.count, m.rows.count)
        XCTAssertEqual(tops, tops.sorted(), "offsets grow down the ladder")
        XCTAssertEqual(Set(tops).count, tops.count, "each row has its own offset")
        XCTAssertNil(m.rowTop(of: .window(group: 9, WindowID(serverID: 9))))
    }
}
