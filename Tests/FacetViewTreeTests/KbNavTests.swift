import AppKit
import Testing
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
struct KbNavTests {

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

    @Test func selectableIndicesSkipSearch() {
        // The search row (index 0) is not selectable; headers + windows are.
        #expect(kbSelectableIndices(rows: sampleRows()) == [1, 2, 3, 4])
    }

    @Test func keyAtMapsKindToSelection() {
        let rows = sampleRows()
        #expect(kbKeyAt(1, in: rows) == .hdr(group: 1))
        #expect(kbKeyAt(2, in: rows) == .win(group: 1, wid(10)))
        #expect(kbKeyAt(0, in: rows) == nil)     // search → nil
        #expect(kbKeyAt(99, in: rows) == nil)    // out of bounds → nil
    }

    @Test func indexOfFindsLogicalSelection() {
        let rows = sampleRows()
        #expect(kbIndexOf(.win(group: 1, wid(11)), in: rows) == 3)
        #expect(kbIndexOf(.hdr(group: 2), in: rows) == 4)
        #expect(kbIndexOf(.win(group: 1, wid(404)), in: rows) == nil)   // absent
    }

    @Test func wsOrderListsHeadersInOrder() {
        #expect(kbWsOrder(rows: sampleRows()) == [1, 2])
        #expect(kbWsOrder(rows: [searchRow()]) == [])
    }

    @Test func moveTargetStepsAndClamps() {
        let sel = [1, 2, 3, 4]
        #expect(kbMoveTarget(selectable: sel, current: 2, delta: 1) == 3)
        #expect(kbMoveTarget(selectable: sel, current: 2, delta: -1) == 1)
        #expect(kbMoveTarget(selectable: sel, current: 1, delta: -1) == 1) // clamp low
        #expect(kbMoveTarget(selectable: sel, current: 4, delta: 1) == 4)  // clamp high
        #expect(kbMoveTarget(selectable: sel, current: nil, delta: 1) == 2) // nil → pos 0 +1
        #expect(kbMoveTarget(selectable: [], current: nil, delta: 1) == nil)
    }

    @Test func jumpTargetPrefersFirstWindowElseHeader() {
        let rows = sampleRows()
        // WS1 forward → WS2 is empty → its header.
        #expect(kbJumpTarget(rows: rows, fromWS: 1, dir: 1) == .hdr(group: 2))
        // WS2 back → WS1's first window.
        #expect(kbJumpTarget(rows: rows, fromWS: 2, dir: -1) == .win(group: 1, wid(10)))
        // Clamp at the low end (already first WS) → WS1's first window.
        #expect(kbJumpTarget(rows: rows, fromWS: 1, dir: -1) == .win(group: 1, wid(10)))
        // Missing fromWS → position 0; dir -1 clamps to 0 → WS1's first window.
        #expect(kbJumpTarget(rows: rows, fromWS: nil, dir: -1) == .win(group: 1, wid(10)))
        // No headers at all → nil.
        #expect(kbJumpTarget(rows: [searchRow()], fromWS: nil, dir: 1) == nil)
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

    @Test func multiMatchIndexOfDisambiguatesByGroup() {
        let rows = multiMatchRows()
        // Same window id, two different rows — the group decides which.
        #expect(kbIndexOf(.win(group: 0, wid(10)), in: rows) == 1)
        #expect(kbIndexOf(.win(group: 1, wid(10)), in: rows) == 4)
        // A group/id pair that doesn't co-occur is absent (window 11 is not
        // in the lens group).
        #expect(kbIndexOf(.win(group: 1, wid(11)), in: rows) == nil)
    }

    @Test func multiMatchKeyAtCarriesGroup() {
        let rows = multiMatchRows()
        #expect(kbKeyAt(1, in: rows) == .win(group: 0, wid(10)))
        #expect(kbKeyAt(4, in: rows) == .win(group: 1, wid(10)))
        #expect(kbKeyAt(3, in: rows) == .hdr(group: 1))
    }

    @Test func multiMatchWsOrderAndJumpUseGroupOrdinals() {
        let rows = multiMatchRows()
        #expect(kbWsOrder(rows: rows) == [0, 1])
        // Jump from group 0 forward → group 1's first window (the lens copy
        // of window 10), keyed by group 1 — NOT a teleport back to group 0.
        #expect(kbJumpTarget(rows: rows, fromWS: 0, dir: 1) == .win(group: 1, wid(10)))
    }
}
