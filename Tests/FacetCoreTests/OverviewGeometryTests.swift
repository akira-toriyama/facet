import XCTest
@testable import FacetCore

final class OverviewGeometryTests: XCTestCase {
    // Forward from the whole-WS slot (-1) walks 0,1,…,n-1 then wraps to -1.
    func testForwardWrap() {
        let n = 3
        XCTAssertEqual(cycleSlotIndex(current: -1, windowCount: n, forward: true), 0)
        XCTAssertEqual(cycleSlotIndex(current: 0, windowCount: n, forward: true), 1)
        XCTAssertEqual(cycleSlotIndex(current: 1, windowCount: n, forward: true), 2)
        XCTAssertEqual(cycleSlotIndex(current: 2, windowCount: n, forward: true), -1) // wrap
    }

    // Backward from -1 wraps to the last window, then walks back to -1.
    func testBackwardWrap() {
        let n = 3
        XCTAssertEqual(cycleSlotIndex(current: -1, windowCount: n, forward: false), 2) // wrap
        XCTAssertEqual(cycleSlotIndex(current: 2, windowCount: n, forward: false), 1)
        XCTAssertEqual(cycleSlotIndex(current: 0, windowCount: n, forward: false), -1)
    }

    // Zero windows = only the whole-WS slot; cycling stays at -1.
    func testNoWindows() {
        XCTAssertEqual(cycleSlotIndex(current: -1, windowCount: 0, forward: true), -1)
        XCTAssertEqual(cycleSlotIndex(current: -1, windowCount: 0, forward: false), -1)
    }

    // A stale out-of-range cursor is clamped before cycling.
    func testStaleCursorClamped() {
        // current=99 with n=2 clamps to 1, forward → wraps to -1.
        XCTAssertEqual(cycleSlotIndex(current: 99, windowCount: 2, forward: true), -1)
        // current=-50 clamps to -1, backward → wraps to last window (1).
        XCTAssertEqual(cycleSlotIndex(current: -50, windowCount: 2, forward: false), 1)
    }
}
