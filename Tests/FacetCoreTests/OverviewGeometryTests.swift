import Testing
@testable import FacetCore

struct OverviewGeometryTests {
    // Forward from the whole-WS slot (-1) walks 0,1,…,n-1 then wraps to -1.
    @Test func forwardWrap() {
        let n = 3
        #expect(cycleSlotIndex(current: -1, windowCount: n, forward: true) == 0)
        #expect(cycleSlotIndex(current: 0, windowCount: n, forward: true) == 1)
        #expect(cycleSlotIndex(current: 1, windowCount: n, forward: true) == 2)
        #expect(cycleSlotIndex(current: 2, windowCount: n, forward: true) == -1) // wrap
    }

    // Backward from -1 wraps to the last window, then walks back to -1.
    @Test func backwardWrap() {
        let n = 3
        #expect(cycleSlotIndex(current: -1, windowCount: n, forward: false) == 2) // wrap
        #expect(cycleSlotIndex(current: 2, windowCount: n, forward: false) == 1)
        #expect(cycleSlotIndex(current: 0, windowCount: n, forward: false) == -1)
    }

    // Zero windows = only the whole-WS slot; cycling stays at -1.
    @Test func noWindows() {
        #expect(cycleSlotIndex(current: -1, windowCount: 0, forward: true) == -1)
        #expect(cycleSlotIndex(current: -1, windowCount: 0, forward: false) == -1)
    }

    // A stale out-of-range cursor is clamped before cycling.
    @Test func staleCursorClamped() {
        // current=99 with n=2 clamps to 1, forward → wraps to -1.
        #expect(cycleSlotIndex(current: 99, windowCount: 2, forward: true) == -1)
        // current=-50 clamps to -1, backward → wraps to last window (1).
        #expect(cycleSlotIndex(current: -50, windowCount: 2, forward: false) == 1)
    }
}
