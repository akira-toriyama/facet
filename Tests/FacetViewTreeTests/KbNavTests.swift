import AppKit
import XCTest
@testable import FacetViewTree
import FacetCore

/// Unit tests for the pure keyboard-nav helpers in `KbNav.swift`. These
/// were factored out of `SidebarView` precisely so the index math could
/// be exercised without an NSView / the main actor — this target finally
/// does so (tests-03 Option B: a FacetViewTree test target, mirroring
/// FacetViewGridTests, since `TreeRow` is a view-layer type and stays put).
///
/// Rows are keyed by a `group` ordinal (PR5 — the section/lens model can
/// show the same window in several sections). In the by-workspace degrade
/// `group == workspaceIndex == ws.index`, which the first block exercises;
/// the multi-match block exercises the section case where one window id
/// appears under two different groups.
final class KbNavTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    /// By-workspace degrade row: group == workspaceIndex == ws.
    private func hdr(_ ws: Int) -> TreeRow {
        TreeRow(rect: .zero, kind: .header(group: ws, workspaceIndex: ws))
    }
    private func win(ws: Int, id: Int) -> TreeRow {
        TreeRow(rect: .zero,
                kind: .window(group: ws, workspaceIndex: ws, pid: 1000,
                              windowID: wid(id), title: "w\(id)"))
    }
    private func searchRow() -> TreeRow { TreeRow(rect: .zero, kind: .search) }

    /// Representative tree: a search bar, WS1 (header + two windows),
    /// then an empty WS2 (header only).
    private func sampleRows() -> [TreeRow] {
        [searchRow(), hdr(1), win(ws: 1, id: 10), win(ws: 1, id: 11), hdr(2)]
    }

    func testSelectableIndicesSkipSearch() {
        // The search row (index 0) is not selectable; headers + windows are.
        XCTAssertEqual(kbSelectableIndices(rows: sampleRows()), [1, 2, 3, 4])
    }

    func testKeyAtMapsKindToSelection() {
        let rows = sampleRows()
        XCTAssertEqual(kbKeyAt(1, in: rows), .hdr(group: 1))
        XCTAssertEqual(kbKeyAt(2, in: rows), .win(group: 1, wid(10)))
        XCTAssertNil(kbKeyAt(0, in: rows))     // search → nil
        XCTAssertNil(kbKeyAt(99, in: rows))    // out of bounds → nil
    }

    func testIndexOfFindsLogicalSelection() {
        let rows = sampleRows()
        XCTAssertEqual(kbIndexOf(.win(group: 1, wid(11)), in: rows), 3)
        XCTAssertEqual(kbIndexOf(.hdr(group: 2), in: rows), 4)
        XCTAssertNil(kbIndexOf(.win(group: 1, wid(404)), in: rows))   // absent
    }

    func testWsOrderListsHeadersInOrder() {
        XCTAssertEqual(kbWsOrder(rows: sampleRows()), [1, 2])
        XCTAssertEqual(kbWsOrder(rows: [searchRow()]), [])
    }

    func testMoveTargetStepsAndClamps() {
        let sel = [1, 2, 3, 4]
        XCTAssertEqual(kbMoveTarget(selectable: sel, current: 2, delta: 1), 3)
        XCTAssertEqual(kbMoveTarget(selectable: sel, current: 2, delta: -1), 1)
        XCTAssertEqual(kbMoveTarget(selectable: sel, current: 1, delta: -1), 1) // clamp low
        XCTAssertEqual(kbMoveTarget(selectable: sel, current: 4, delta: 1), 4)  // clamp high
        XCTAssertEqual(kbMoveTarget(selectable: sel, current: nil, delta: 1), 2) // nil → pos 0 +1
        XCTAssertNil(kbMoveTarget(selectable: [], current: nil, delta: 1))
    }

    func testJumpTargetPrefersFirstWindowElseHeader() {
        let rows = sampleRows()
        // WS1 forward → WS2 is empty → its header.
        XCTAssertEqual(kbJumpTarget(rows: rows, fromWS: 1, dir: 1),
                       .hdr(group: 2))
        // WS2 back → WS1's first window.
        XCTAssertEqual(kbJumpTarget(rows: rows, fromWS: 2, dir: -1),
                       .win(group: 1, wid(10)))
        // Clamp at the low end (already first WS) → WS1's first window.
        XCTAssertEqual(kbJumpTarget(rows: rows, fromWS: 1, dir: -1),
                       .win(group: 1, wid(10)))
        // Missing fromWS → position 0; dir -1 clamps to 0 → WS1's first window.
        XCTAssertEqual(kbJumpTarget(rows: rows, fromWS: nil, dir: -1),
                       .win(group: 1, wid(10)))
        // No headers at all → nil.
        XCTAssertNil(kbJumpTarget(rows: [searchRow()], fromWS: nil, dir: 1))
    }

    // MARK: - Section model: multi-match (same window id under two groups)

    /// A section-style tree where window 10 lives both in group 0 (its
    /// workspace section) and group 1 (a lens section it matches). The
    /// `group` ordinal — not the window id — is what disambiguates the two
    /// rows. `workspaceIndex` is the window's REAL workspace (5 here) in both
    /// rows, so a click focuses the right window regardless of which copy.
    private func secWin(group: Int, realWS: Int, id: Int) -> TreeRow {
        TreeRow(rect: .zero,
                kind: .window(group: group, workspaceIndex: realWS, pid: 1000,
                              windowID: wid(id), title: "w\(id)"))
    }
    private func secHdr(group: Int, workspaceIndex: Int?) -> TreeRow {
        TreeRow(rect: .zero,
                kind: .header(group: group, workspaceIndex: workspaceIndex))
    }
    private func multiMatchRows() -> [TreeRow] {
        [
            secHdr(group: 0, workspaceIndex: 5),   // workspace section
            secWin(group: 0, realWS: 5, id: 10),
            secWin(group: 0, realWS: 5, id: 11),
            secHdr(group: 1, workspaceIndex: nil), // lens section
            secWin(group: 1, realWS: 5, id: 10),   // window 10 again (matches lens)
        ]
    }

    func testMultiMatchIndexOfDisambiguatesByGroup() {
        let rows = multiMatchRows()
        // Same window id, two different rows — the group decides which.
        XCTAssertEqual(kbIndexOf(.win(group: 0, wid(10)), in: rows), 1)
        XCTAssertEqual(kbIndexOf(.win(group: 1, wid(10)), in: rows), 4)
        // A group/id pair that doesn't co-occur is absent (window 11 is not
        // in the lens group).
        XCTAssertNil(kbIndexOf(.win(group: 1, wid(11)), in: rows))
    }

    func testMultiMatchKeyAtCarriesGroup() {
        let rows = multiMatchRows()
        XCTAssertEqual(kbKeyAt(1, in: rows), .win(group: 0, wid(10)))
        XCTAssertEqual(kbKeyAt(4, in: rows), .win(group: 1, wid(10)))
        XCTAssertEqual(kbKeyAt(3, in: rows), .hdr(group: 1))
    }

    func testMultiMatchWsOrderAndJumpUseGroupOrdinals() {
        let rows = multiMatchRows()
        XCTAssertEqual(kbWsOrder(rows: rows), [0, 1])
        // Jump from group 0 forward → group 1's first window (the lens copy
        // of window 10), keyed by group 1 — NOT a teleport back to group 0.
        XCTAssertEqual(kbJumpTarget(rows: rows, fromWS: 0, dir: 1),
                       .win(group: 1, wid(10)))
    }
}
