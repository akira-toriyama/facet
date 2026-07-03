import Testing
@testable import FacetCore

/// `SectionOrder` — the session-only, display-only reorder applied to the
/// PROJECTED section list (never the config input). Stable-partition +
/// insert-between are pure; CI-only (CLT can't run `swift test`). The
/// algorithm was bench-verified standalone before porting; these lock it.
struct SectionOrderTests {

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

    @Test func nilOverrideIsIdentity() {
        let s = base.map(sec)
        #expect(ids(SectionOrder.apply(nil, to: s)) == base)
    }

    @Test func emptyOverrideIsIdentity() {
        let s = base.map(sec)
        #expect(ids(SectionOrder.apply([], to: s)) == base)
    }

    @Test func fullOverrideIsExactPermutation() {
        let s = base.map(sec)
        let order = ["section:3:Code", "ws:0", "ws:1", "section:1:Web"]
        #expect(ids(SectionOrder.apply(order, to: s)) == order)
    }

    /// Known ids first in override order; unknown ids (e.g. a workspace added
    /// after the override was captured) keep their projection order, appended.
    @Test func partialOverrideAppendsNewcomersInProjectionOrder() {
        let s = base.map(sec)
        #expect(ids(SectionOrder.apply(["ws:1", "ws:0"], to: s)) ==
                       ["ws:1", "ws:0", "section:1:Web", "section:3:Code"])
    }

    /// A stale id (section removed mid-session) is ignored — no crash, no
    /// phantom row.
    @Test func staleIdInOverrideIsIgnored() {
        let s = base.map(sec)
        #expect(ids(SectionOrder.apply(["ws:9", "ws:1", "ws:0"], to: s)) ==
                       ["ws:1", "ws:0", "section:1:Web", "section:3:Code"])
    }

    /// Totality: output is always a permutation of input (same multiset),
    /// never dropping / duplicating a section.
    @Test func outputIsAlwaysAPermutation() {
        let s = base.map(sec)
        for order: [String]? in [nil, [], ["section:1:Web"],
                                 ["ws:9"], ["ws:1", "ws:1"], base.reversed()] {
            #expect(ids(SectionOrder.apply(order, to: s)).sorted() ==
                           base.sorted(), "override \(order ?? []) must stay total")
        }
    }

    // MARK: - applyWorkspaces (degrade path, keyed by ws:<index>)

    @Test func applyWorkspacesKeyedByWireIndex() {
        let w = [ws(0), ws(1), ws(2)]
        let r = SectionOrder.applyWorkspaces(["ws:2", "ws:0", "ws:1"], to: w)
        #expect(r.map(\.index) == [2, 0, 1])
    }

    @Test func applyWorkspacesNilIsIdentity() {
        let w = [ws(5), ws(2)]
        #expect(SectionOrder.applyWorkspaces(nil, to: w).map(\.index) == [5, 2])
    }

    // MARK: - reorder (insert-between with self-shift)

    private let cur = ["A", "B", "C", "D"]

    @Test func moveDownShiftsBoundary() {
        // A (idx 0) → boundary 3 (after C, before D): from < boundary → shift
        #expect(SectionOrder.reorder(cur, move: "A", toBoundary: 3) ==
                       ["B", "C", "A", "D"])
    }

    @Test func moveUpNoShift() {
        // D (idx 3) → boundary 1 (after A): from > boundary → no shift
        #expect(SectionOrder.reorder(cur, move: "D", toBoundary: 1) ==
                       ["A", "D", "B", "C"])
    }

    @Test func moveToOwnBoundariesIsIdentity() {
        #expect(SectionOrder.reorder(cur, move: "A", toBoundary: 0) == cur)
        #expect(SectionOrder.reorder(cur, move: "A", toBoundary: 1) == cur)
    }

    @Test func moveToFrontAndEnd() {
        #expect(SectionOrder.reorder(cur, move: "B", toBoundary: 0) ==
                       ["B", "A", "C", "D"])
        #expect(SectionOrder.reorder(cur, move: "C", toBoundary: 4) ==
                       ["A", "B", "D", "C"])
    }

    @Test func absentIdIsIdentity() {
        #expect(SectionOrder.reorder(cur, move: "Z", toBoundary: 2) == cur)
    }

    @Test func boundaryPastEndClampsToTail() {
        #expect(SectionOrder.reorder(cur, move: "A", toBoundary: 99) ==
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

    @Test func keyboardReorderLandsAtTargetOrdinal() {
        let n = cur.count
        for g in 0..<n {
            for tgt in 0..<n where tgt != g {
                let out = SectionOrder.reorder(
                    cur, move: cur[g], toBoundary: kbBoundary(g: g, tgt: tgt))
                #expect(out.firstIndex(of: cur[g]) == tgt,
                    "lift \(g) aim \(tgt): \(cur[g]) should land at index \(tgt), got \(out)")
                #expect(out.sorted() == cur.sorted(),    // totality
                               "lift \(g) aim \(tgt) must stay a permutation")
            }
        }
    }

    @Test func keyboardReorderAdjacentMoves() {
        // Aim one slot down: A(0) → tgt 1 lands A at index 1 (past B).
        #expect(
            SectionOrder.reorder(cur, move: "A", toBoundary: kbBoundary(g: 0, tgt: 1)) ==
            ["B", "A", "C", "D"])
        // Aim one slot up: D(3) → tgt 2 lands D at index 2.
        #expect(
            SectionOrder.reorder(cur, move: "D", toBoundary: kbBoundary(g: 3, tgt: 2)) ==
            ["A", "B", "D", "C"])
    }
}
