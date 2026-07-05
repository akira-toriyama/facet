import Testing
@testable import FacetCore

/// `boardTabLayout` (t-wrd2 / W2.4) — the pure left→right frame layout for the
/// tree board tab bar. Text is measured view-side and passed in as intrinsic
/// widths; this lays the tabs out. When they all fit at intrinsic width that is
/// the layout (the v1 2-3 board case); on overflow every tab shrinks to a
/// uniform width that fits (labels tail-truncate in the view) — a safe fallback
/// while the rail-carousel ROTATE refinement is deferred (it only matters once
/// the additive many-board feature lands). Each frame carries its 0-based board
/// index so a click / wheel maps back to the right board. Pure; CI-only.
struct BoardTabLayoutTests {

    @Test func emptyWidthsReturnsNoFrames() {
        #expect(boardTabLayout(widths: [], available: 300, gap: 6) == [])
    }

    @Test func fittingTabsKeepIntrinsicWidthsLeftToRight() {
        let f = boardTabLayout(widths: [80, 60], available: 300, gap: 6)
        #expect(f == [
            BoardTabFrame(boardIndex: 0, x: 0,  width: 80),
            BoardTabFrame(boardIndex: 1, x: 86, width: 60),   // 80 + gap 6
        ])
    }

    @Test func threeFittingTabsAccumulateWithGaps() {
        let f = boardTabLayout(widths: [50, 50, 50], available: 300, gap: 10)
        #expect(f.map(\.x) == [0, 60, 120])
        #expect(f.map(\.width) == [50, 50, 50])
        #expect(f.map(\.boardIndex) == [0, 1, 2])
    }

    /// Exactly-fits boundary (sum + gaps == available) still takes the
    /// intrinsic path (no shrink).
    @Test func exactFitUsesIntrinsic() {
        // 147 + 147 + gap 6 = 300
        let f = boardTabLayout(widths: [147, 147], available: 300, gap: 6)
        #expect(f.map(\.width) == [147, 147])
        #expect(f.map(\.x) == [0, 153])
    }

    /// Overflow: tabs shrink to a UNIFORM width that fits, gaps preserved, and
    /// the run spans exactly `available`.
    @Test func overflowShrinksToUniformFit() {
        // intrinsic 200+200 + gap 6 = 406 > 300 → uniform: (300-6)/2 = 147
        let f = boardTabLayout(widths: [200, 200], available: 300, gap: 6)
        #expect(f.map(\.width) == [147, 147])
        #expect(f.map(\.x) == [0, 153])
        #expect(f.last.map { $0.x + $0.width } == 300)   // spans available
    }

    @Test func singleTabFitsAtIntrinsic() {
        #expect(boardTabLayout(widths: [120], available: 300, gap: 6) ==
                       [BoardTabFrame(boardIndex: 0, x: 0, width: 120)])
    }

    /// A single tab that OVERFLOWS shrinks to `available`, not its intrinsic
    /// width — the n==1 overflow branch the `singleTabFitsAtIntrinsic` case
    /// doesn't reach. The doc comment "a single tab fills its intrinsic width"
    /// invites a refactor that special-cases n==1; this pins that width 400
    /// still becomes 300 so such a change can't slip through undetected.
    @Test func singleTabOverflowShrinksToAvailable() {
        // intrinsic 400 > available 300 → overflow: cellW = max(0,(300-0)/1) = 300.
        #expect(boardTabLayout(widths: [400], available: 300, gap: 6) ==
                       [BoardTabFrame(boardIndex: 0, x: 0, width: 300)])
    }

    /// N4 (board review follow-up): an EXTREME overflow where the gaps alone
    /// exceed `available` clamps each width to 0 (never negative) — pins the
    /// `max(0, …)` so a future refactor can't emit negative widths unnoticed.
    @Test func extremeOverflowClampsWidthToZero() {
        // gaps 6*2 = 12 > available 5 → (5-12)/3 < 0 → clamped to 0.
        let f = boardTabLayout(widths: [100, 100, 100], available: 5, gap: 6)
        #expect(f.map(\.width) == [0, 0, 0])
        #expect(f.allSatisfy { $0.width >= 0 && $0.x >= 0 },
                      "no negative width or x")
    }
}
