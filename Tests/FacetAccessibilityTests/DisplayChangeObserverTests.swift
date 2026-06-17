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
        //
        // The expectation is fulfilled BY the production callback,
        // so `wait` returns only once `onChange` actually ran — a
        // real happens-before, not a race between two independent
        // wall-clock timers (the old shape asserted `fireCount` after
        // an unrelated 0.2 s timer, which flaked on loaded CI runners
        // when the debounce fire slipped past that timer / the 1 s
        // timeout). The generous timeout only guards a stalled run
        // loop; it never participates in the assertion.
        var fireCount = 0
        let fired = expectation(description: "debounce fires")
        fired.assertForOverFulfill = true   // a 2nd fire → over-fulfill → failure
        let observer = DisplayChangeObserver(
            onChange: { fireCount += 1; fired.fulfill() },
            debounceInterval: 0.05)

        observer.schedule()
        observer.schedule()
        observer.schedule()

        // Synchronously, nothing has fired yet (work items queued).
        XCTAssertEqual(fireCount, 0)

        wait(for: [fired], timeout: 2.0)

        // Drain a few more run-loop turns so any erroneous *sibling*
        // fires surface: a broken `cancel()` would leave the other two
        // work items queued at the same deadline, already past-due once
        // the first fired. The inverted expectation never fulfills, so
        // this is a pure 0.1 s run-loop drain — a leaked fire would trip
        // `assertForOverFulfill` and bump `fireCount`. (A drain, not an
        // assertion gate: on an over-loaded host it can only miss a
        // regression, never raise a false failure.)
        let drain = expectation(description: "drain for stray fires")
        drain.isInverted = true
        wait(for: [drain], timeout: 0.1)

        XCTAssertEqual(fireCount, 1,
                       "burst of 3 schedule() calls must "
                       + "produce exactly 1 fire")
    }

    func testStopCancelsPendingFire() {
        // schedule() then stop() before the timer fires → no
        // fire at all. Otherwise observer.deinit could miss a
        // queued fire and surprise consumers.
        //
        // Proving a *non*-event needs a bounded wall-clock window, but
        // an inverted expectation makes it exact: the test passes iff
        // `onChange` does NOT fire within the window, and a leaked fire
        // fails immediately rather than being asserted against a second
        // racing timer. The window only needs to comfortably exceed the
        // 0.1 s debounce interval.
        var fireCount = 0
        let exp = expectation(description: "no fire after stop")
        exp.isInverted = true
        let observer = DisplayChangeObserver(
            onChange: { fireCount += 1; exp.fulfill() },
            debounceInterval: 0.1)

        observer.schedule()
        observer.stop()

        wait(for: [exp], timeout: 0.5)

        XCTAssertEqual(fireCount, 0,
                       "stop() must cancel pending fire")
    }
}
