import AppKit
import XCTest
@testable import FacetViewTree
import FacetCore

/// Unit tests for the pure keyboard-nav helpers in `KbNav.swift`. These
/// were factored out of `SidebarView` precisely so the index math could
/// be exercised without an NSView / the main actor — this target finally
/// does so (tests-03 Option B: a FacetViewTree test target, mirroring
/// FacetViewGridTests, since `TreeRow` is a view-layer type and stays put).
final class KbNavTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private func hdr(_ ws: Int) -> TreeRow {
        TreeRow(rect: .zero, kind: .header(workspaceIndex: ws))
    }
    private func win(ws: Int, id: Int) -> TreeRow {
        TreeRow(rect: .zero,
                kind: .window(workspaceIndex: ws, pid: 1000,
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
        XCTAssertEqual(kbKeyAt(1, in: rows), .hdr(workspaceIndex: 1))
        XCTAssertEqual(kbKeyAt(2, in: rows), .win(wid(10)))
        XCTAssertNil(kbKeyAt(0, in: rows))     // search → nil
        XCTAssertNil(kbKeyAt(99, in: rows))    // out of bounds → nil
    }

    func testIndexOfFindsLogicalSelection() {
        let rows = sampleRows()
        XCTAssertEqual(kbIndexOf(.win(wid(11)), in: rows), 3)
        XCTAssertEqual(kbIndexOf(.hdr(workspaceIndex: 2), in: rows), 4)
        XCTAssertNil(kbIndexOf(.win(wid(404)), in: rows))   // absent
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
                       .hdr(workspaceIndex: 2))
        // WS2 back → WS1's first window.
        XCTAssertEqual(kbJumpTarget(rows: rows, fromWS: 2, dir: -1),
                       .win(wid(10)))
        // Clamp at the low end (already first WS) → WS1's first window.
        XCTAssertEqual(kbJumpTarget(rows: rows, fromWS: 1, dir: -1),
                       .win(wid(10)))
        // Missing fromWS → position 0; dir -1 clamps to 0 → WS1's first window.
        XCTAssertEqual(kbJumpTarget(rows: rows, fromWS: nil, dir: -1),
                       .win(wid(10)))
        // No headers at all → nil.
        XCTAssertNil(kbJumpTarget(rows: [searchRow()], fromWS: nil, dir: 1))
    }
}
