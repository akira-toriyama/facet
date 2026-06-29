import XCTest
@testable import FacetCore

/// `boardIndexStep` (t-wrd2 / W2.4) — the wheel / arrow board cursor step. A
/// notch / swipe / arrow moves the active board by ±1, CLAMPED at the ends (a
/// tab bar is not an infinite carousel — wheeling past the last board stays
/// put, predictable, unlike the rail's circular wrap). Pure; CI-only.
final class BoardIndexStepTests: XCTestCase {

    func testStepForwardAdvancesOne() {
        XCTAssertEqual(boardIndexStep(current: 0, by: 1, count: 3), 1)
        XCTAssertEqual(boardIndexStep(current: 1, by: 1, count: 3), 2)
    }

    func testStepBackwardRetreatsOne() {
        XCTAssertEqual(boardIndexStep(current: 2, by: -1, count: 3), 1)
        XCTAssertEqual(boardIndexStep(current: 1, by: -1, count: 3), 0)
    }

    func testClampsAtUpperEnd() {
        XCTAssertEqual(boardIndexStep(current: 2, by: 1, count: 3), 2)
    }

    func testClampsAtLowerEnd() {
        XCTAssertEqual(boardIndexStep(current: 0, by: -1, count: 3), 0)
    }

    func testMultiStepClamps() {
        XCTAssertEqual(boardIndexStep(current: 0, by: 5, count: 3), 2)
        XCTAssertEqual(boardIndexStep(current: 2, by: -9, count: 3), 0)
    }

    func testSingleBoardStaysAtZero() {
        XCTAssertEqual(boardIndexStep(current: 0, by: 1, count: 1), 0)
    }

    /// Defensive: a zero / negative count never produces a negative index.
    func testEmptyCountStaysAtZero() {
        XCTAssertEqual(boardIndexStep(current: 0, by: 1, count: 0), 0)
    }
}
