import Testing
@testable import FacetCore

/// Pure tests for the window-order ops behind swap / insert (枠C).
/// `nil` means "no change" (the caller's change-detection signal).
struct WindowOrderTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private func order() -> [WindowID] {
        [wid(1), wid(2), wid(3), wid(4)]
    }

    // MARK: - swap

    @Test func swapExchangesPositions() {
        #expect(WindowOrder.swapped(order(), wid(1), wid(4)) ==
                       [wid(4), wid(2), wid(3), wid(1)])
    }

    @Test func swapSameWindowIsNil() {
        #expect(WindowOrder.swapped(order(), wid(2), wid(2)) == nil)
    }

    @Test func swapAbsentWindowIsNil() {
        #expect(WindowOrder.swapped(order(), wid(2), wid(9)) == nil)
    }

    // MARK: - insert

    @Test func insertRightPlacesAfterTarget() {
        // Move wid(1) to just after wid(3).
        #expect(
            WindowOrder.inserted(order(), moving: wid(1),
                                 beside: wid(3), edge: .right) ==
            [wid(2), wid(3), wid(1), wid(4)])
    }

    @Test func insertLeftPlacesBeforeTarget() {
        #expect(
            WindowOrder.inserted(order(), moving: wid(4),
                                 beside: wid(2), edge: .left) ==
            [wid(1), wid(4), wid(2), wid(3)])
    }

    @Test func insertTopActsLikeBefore() {
        #expect(
            WindowOrder.inserted(order(), moving: wid(4),
                                 beside: wid(2), edge: .top) ==
            [wid(1), wid(4), wid(2), wid(3)])
    }

    @Test func insertBottomActsLikeAfter() {
        #expect(
            WindowOrder.inserted(order(), moving: wid(1),
                                 beside: wid(3), edge: .bottom) ==
            [wid(2), wid(3), wid(1), wid(4)])
    }

    @Test func insertNoPositionalChangeIsNil() {
        // wid(2) after wid(1) — already its position.
        #expect(
            WindowOrder.inserted(order(), moving: wid(2),
                                 beside: wid(1), edge: .right) == nil)
    }

    @Test func insertSameWindowIsNil() {
        #expect(
            WindowOrder.inserted(order(), moving: wid(2),
                                 beside: wid(2), edge: .left) == nil)
    }

    @Test func insertAbsentWindowIsNil() {
        #expect(
            WindowOrder.inserted(order(), moving: wid(9),
                                 beside: wid(2), edge: .left) == nil)
    }
}
