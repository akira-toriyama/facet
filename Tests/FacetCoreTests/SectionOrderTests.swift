import XCTest
@testable import FacetCore

/// `SectionOrder` — the session-only, display-only reorder applied to the
/// PROJECTED section list (never the config input). Stable-partition +
/// insert-between are pure; CI-only (CLT can't run `swift test`). The
/// algorithm was bench-verified standalone before porting; these lock it.
final class SectionOrderTests: XCTestCase {

    // MARK: - fixtures

    private func sec(_ id: String) -> ProjectedSection {
        ProjectedSection(id: id, label: id, windows: [], sourceWorkspaceIndex: nil)
    }
    private func ids(_ s: [ProjectedSection]) -> [String] { s.map(\.id) }

    private func ws(_ index: Int) -> Workspace {
        Workspace(index: index, name: "W\(index)", isActive: false,
                  layoutMode: "float", windows: [])
    }

    private let base = ["ws:0", "section:1:Web", "ws:1", "section:3:Code"]

    // MARK: - apply (stable-partition over ProjectedSection)

    func testNilOverrideIsIdentity() {
        let s = base.map(sec)
        XCTAssertEqual(ids(SectionOrder.apply(nil, to: s)), base)
    }

    func testEmptyOverrideIsIdentity() {
        let s = base.map(sec)
        XCTAssertEqual(ids(SectionOrder.apply([], to: s)), base)
    }

    func testFullOverrideIsExactPermutation() {
        let s = base.map(sec)
        let order = ["section:3:Code", "ws:0", "ws:1", "section:1:Web"]
        XCTAssertEqual(ids(SectionOrder.apply(order, to: s)), order)
    }

    /// Known ids first in override order; unknown ids (e.g. a workspace added
    /// after the override was captured) keep their projection order, appended.
    func testPartialOverrideAppendsNewcomersInProjectionOrder() {
        let s = base.map(sec)
        XCTAssertEqual(ids(SectionOrder.apply(["ws:1", "ws:0"], to: s)),
                       ["ws:1", "ws:0", "section:1:Web", "section:3:Code"])
    }

    /// A stale id (section removed mid-session) is ignored — no crash, no
    /// phantom row.
    func testStaleIdInOverrideIsIgnored() {
        let s = base.map(sec)
        XCTAssertEqual(ids(SectionOrder.apply(["ws:9", "ws:1", "ws:0"], to: s)),
                       ["ws:1", "ws:0", "section:1:Web", "section:3:Code"])
    }

    /// Totality: output is always a permutation of input (same multiset),
    /// never dropping / duplicating a section.
    func testOutputIsAlwaysAPermutation() {
        let s = base.map(sec)
        for order: [String]? in [nil, [], ["section:1:Web"],
                                 ["ws:9"], ["ws:1", "ws:1"], base.reversed()] {
            XCTAssertEqual(ids(SectionOrder.apply(order, to: s)).sorted(),
                           base.sorted(), "override \(order ?? []) must stay total")
        }
    }

    // MARK: - applyWorkspaces (degrade path, keyed by ws:<index>)

    func testApplyWorkspacesKeyedByWireIndex() {
        let w = [ws(0), ws(1), ws(2)]
        let r = SectionOrder.applyWorkspaces(["ws:2", "ws:0", "ws:1"], to: w)
        XCTAssertEqual(r.map(\.index), [2, 0, 1])
    }

    func testApplyWorkspacesNilIsIdentity() {
        let w = [ws(5), ws(2)]
        XCTAssertEqual(SectionOrder.applyWorkspaces(nil, to: w).map(\.index), [5, 2])
    }

    // MARK: - reorder (insert-between with self-shift)

    private let cur = ["A", "B", "C", "D"]

    func testMoveDownShiftsBoundary() {
        // A (idx 0) → boundary 3 (after C, before D): from < boundary → shift
        XCTAssertEqual(SectionOrder.reorder(cur, move: "A", toBoundary: 3),
                       ["B", "C", "A", "D"])
    }

    func testMoveUpNoShift() {
        // D (idx 3) → boundary 1 (after A): from > boundary → no shift
        XCTAssertEqual(SectionOrder.reorder(cur, move: "D", toBoundary: 1),
                       ["A", "D", "B", "C"])
    }

    func testMoveToOwnBoundariesIsIdentity() {
        XCTAssertEqual(SectionOrder.reorder(cur, move: "A", toBoundary: 0), cur)
        XCTAssertEqual(SectionOrder.reorder(cur, move: "A", toBoundary: 1), cur)
    }

    func testMoveToFrontAndEnd() {
        XCTAssertEqual(SectionOrder.reorder(cur, move: "B", toBoundary: 0),
                       ["B", "A", "C", "D"])
        XCTAssertEqual(SectionOrder.reorder(cur, move: "C", toBoundary: 4),
                       ["A", "B", "D", "C"])
    }

    func testAbsentIdIsIdentity() {
        XCTAssertEqual(SectionOrder.reorder(cur, move: "Z", toBoundary: 2), cur)
    }

    func testBoundaryPastEndClampsToTail() {
        XCTAssertEqual(SectionOrder.reorder(cur, move: "A", toBoundary: 99),
                       ["B", "C", "D", "A"])
    }

    // MARK: - keyboard header-reorder boundary contract
    //
    // `SidebarView.kbCommitLift` (.hdr, section mode) maps a lifted section
    // ordinal `g` + the aimed target ordinal `tgt` to a drop boundary via
    // `tgt < g ? tgt : tgt + 1`, then calls `reorder`. Contract: the lifted
    // section lands EXACTLY at `tgt` (aim a slot → land in it), mirroring the
    // mouse mode-4 drop. These lock that mapping — the @MainActor View code
    // can't run under `swift test`, so the contract it relies on is pinned here.

    /// The keyboard ordinal→boundary rule, mirrored from `kbCommitLift`.
    private func kbBoundary(g: Int, tgt: Int) -> Int { tgt < g ? tgt : tgt + 1 }

    func testKeyboardReorderLandsAtTargetOrdinal() {
        let n = cur.count
        for g in 0..<n {
            for tgt in 0..<n where tgt != g {
                let out = SectionOrder.reorder(
                    cur, move: cur[g], toBoundary: kbBoundary(g: g, tgt: tgt))
                XCTAssertEqual(out.firstIndex(of: cur[g]), tgt,
                    "lift \(g) aim \(tgt): \(cur[g]) should land at index \(tgt), got \(out)")
                XCTAssertEqual(out.sorted(), cur.sorted(),    // totality
                               "lift \(g) aim \(tgt) must stay a permutation")
            }
        }
    }

    func testKeyboardReorderAdjacentMoves() {
        // Aim one slot down: A(0) → tgt 1 lands A at index 1 (past B).
        XCTAssertEqual(
            SectionOrder.reorder(cur, move: "A", toBoundary: kbBoundary(g: 0, tgt: 1)),
            ["B", "A", "C", "D"])
        // Aim one slot up: D(3) → tgt 2 lands D at index 2.
        XCTAssertEqual(
            SectionOrder.reorder(cur, move: "D", toBoundary: kbBoundary(g: 3, tgt: 2)),
            ["A", "B", "D", "C"])
    }
}
