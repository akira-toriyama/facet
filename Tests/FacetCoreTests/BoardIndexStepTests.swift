import Testing
@testable import FacetCore

/// `boardIndexStep` (t-wrd2 / W2.4) — the wheel / arrow board cursor step. A
/// notch / swipe / arrow moves the active board by ±1, CLAMPED at the ends (a
/// tab bar is not an infinite carousel — wheeling past the last board stays
/// put, predictable, unlike the rail's circular wrap). Pure; CI-only.
struct BoardIndexStepTests {

    @Test func stepForwardAdvancesOne() {
        #expect(boardIndexStep(current: 0, by: 1, count: 3) == 1)
        #expect(boardIndexStep(current: 1, by: 1, count: 3) == 2)
    }

    @Test func stepBackwardRetreatsOne() {
        #expect(boardIndexStep(current: 2, by: -1, count: 3) == 1)
        #expect(boardIndexStep(current: 1, by: -1, count: 3) == 0)
    }

    @Test func clampsAtUpperEnd() {
        #expect(boardIndexStep(current: 2, by: 1, count: 3) == 2)
    }

    @Test func clampsAtLowerEnd() {
        #expect(boardIndexStep(current: 0, by: -1, count: 3) == 0)
    }

    @Test func multiStepClamps() {
        #expect(boardIndexStep(current: 0, by: 5, count: 3) == 2)
        #expect(boardIndexStep(current: 2, by: -9, count: 3) == 0)
    }

    @Test func singleBoardStaysAtZero() {
        #expect(boardIndexStep(current: 0, by: 1, count: 1) == 0)
    }

    /// Defensive: a zero / negative count never produces a negative index.
    @Test func emptyCountStaysAtZero() {
        #expect(boardIndexStep(current: 0, by: 1, count: 0) == 0)
    }
}
