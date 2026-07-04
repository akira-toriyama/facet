import Testing
@testable import FacetCore

/// `boardIndexStep` (t-wrd2 / W2.4) — the wheel / arrow board cursor step. A
/// notch / swipe / arrow moves the active board by ±1, CLAMPED at the ends (a
/// tab bar is not an infinite carousel — wheeling past the last board stays
/// put, predictable, unlike the rail's circular wrap). Pure; CI-only.
struct BoardIndexStepTests {

    @Test("step by ±1, clamped at both ends", arguments: [
        (current: 0, by: 1, count: 3, expected: 1),   // forward advances one
        (current: 1, by: 1, count: 3, expected: 2),   // forward advances one
        (current: 2, by: -1, count: 3, expected: 1),  // backward retreats one
        (current: 1, by: -1, count: 3, expected: 0),  // backward retreats one
        (current: 2, by: 1, count: 3, expected: 2),   // clamps at upper end
        (current: 0, by: -1, count: 3, expected: 0),  // clamps at lower end
        (current: 0, by: 5, count: 3, expected: 2),   // multi-step clamps
        (current: 2, by: -9, count: 3, expected: 0),  // multi-step clamps
        (current: 0, by: 1, count: 1, expected: 0),   // single board stays at zero
        (current: 0, by: 1, count: 0, expected: 0),   // defensive: zero / negative count never negative
    ])
    func step(current: Int, by: Int, count: Int, expected: Int) {
        #expect(boardIndexStep(current: current, by: by, count: count) == expected)
    }
}
