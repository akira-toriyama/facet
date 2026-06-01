import XCTest
@testable import FacetCore

/// Pure tests for the window-order ops behind swap / insert (枠C).
/// `nil` means "no change" (the caller's change-detection signal).
final class WindowOrderTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private func order() -> [WindowID] {
        [wid(1), wid(2), wid(3), wid(4)]
    }

    // MARK: - swap

    func testSwapExchangesPositions() {
        XCTAssertEqual(WindowOrder.swapped(order(), wid(1), wid(4)),
                       [wid(4), wid(2), wid(3), wid(1)])
    }

    func testSwapSameWindowIsNil() {
        XCTAssertNil(WindowOrder.swapped(order(), wid(2), wid(2)))
    }

    func testSwapAbsentWindowIsNil() {
        XCTAssertNil(WindowOrder.swapped(order(), wid(2), wid(9)))
    }

    // MARK: - insert

    func testInsertRightPlacesAfterTarget() {
        // Move wid(1) to just after wid(3).
        XCTAssertEqual(
            WindowOrder.inserted(order(), moving: wid(1),
                                 beside: wid(3), edge: .right),
            [wid(2), wid(3), wid(1), wid(4)])
    }

    func testInsertLeftPlacesBeforeTarget() {
        XCTAssertEqual(
            WindowOrder.inserted(order(), moving: wid(4),
                                 beside: wid(2), edge: .left),
            [wid(1), wid(4), wid(2), wid(3)])
    }

    func testInsertTopActsLikeBefore() {
        XCTAssertEqual(
            WindowOrder.inserted(order(), moving: wid(4),
                                 beside: wid(2), edge: .top),
            [wid(1), wid(4), wid(2), wid(3)])
    }

    func testInsertBottomActsLikeAfter() {
        XCTAssertEqual(
            WindowOrder.inserted(order(), moving: wid(1),
                                 beside: wid(3), edge: .bottom),
            [wid(2), wid(3), wid(1), wid(4)])
    }

    func testInsertNoPositionalChangeIsNil() {
        // wid(2) after wid(1) — already its position.
        XCTAssertNil(
            WindowOrder.inserted(order(), moving: wid(2),
                                 beside: wid(1), edge: .right))
    }

    func testInsertSameWindowIsNil() {
        XCTAssertNil(
            WindowOrder.inserted(order(), moving: wid(2),
                                 beside: wid(2), edge: .left))
    }

    func testInsertAbsentWindowIsNil() {
        XCTAssertNil(
            WindowOrder.inserted(order(), moving: wid(9),
                                 beside: wid(2), edge: .left))
    }
}
