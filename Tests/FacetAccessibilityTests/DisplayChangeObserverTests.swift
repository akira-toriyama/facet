import XCTest
@testable import FacetAccessibility

/// `DisplayChangeObserver` is mostly NSNotificationCenter
/// plumbing — the test surface that matters is the debounce:
/// many `schedule()` calls in a burst must produce exactly one
/// `onChange()` fire after the burst settles. The actual
/// `NSApplication.didChangeScreenParameters` notification is
/// reproducible in tests (notification observers fire on any
/// `post(name:)` to the same center), so the lifecycle path
/// is testable end-to-end too.
@MainActor
final class DisplayChangeObserverTests: XCTestCase {

    func testDebounceCoalescesBurstIntoSingleFire() {
        // Three `schedule()` calls in the same run-loop tick
        // should collapse into one `onChange` fire after the
        // debounce interval.
        var fireCount = 0
        let interval: TimeInterval = 0.1
        let observer = DisplayChangeObserver(
            onChange: { fireCount += 1 },
            debounceInterval: interval)

        observer.schedule()
        observer.schedule()
        observer.schedule()

        // Before the interval: zero fires.
        XCTAssertEqual(fireCount, 0)

        // Wait long enough for the debounce timer (200 ms ought
        // to comfortably exceed the 100 ms interval).
        let exp = expectation(description: "debounce fires once")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(fireCount, 1,
                       "burst of 3 schedule() calls must "
                       + "produce exactly 1 fire")
    }

    func testStopCancelsPendingFire() {
        // schedule() then stop() before the timer fires → no
        // fire at all. Otherwise observer.deinit could miss a
        // queued fire and surprise consumers.
        var fireCount = 0
        let observer = DisplayChangeObserver(
            onChange: { fireCount += 1 },
            debounceInterval: 0.1)

        observer.schedule()
        observer.stop()

        let exp = expectation(description: "no fire after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(fireCount, 0,
                       "stop() must cancel pending fire")
    }
}
