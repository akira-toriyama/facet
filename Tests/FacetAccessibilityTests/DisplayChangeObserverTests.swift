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
        // Three `schedule()` calls in the same run-loop tick should
        // collapse into one `onChange` fire after the debounce interval.
        //
        // The expectation is fulfilled BY the production callback, so
        // `wait` returns only once `onChange` actually ran — a real
        // happens-before, not a race against an unrelated wall-clock
        // timer. CRITICAL: `fulfill()` is gated on `live`, which we drop
        // the instant `wait` returns. Calling `fulfill()` after its
        // waiter has finished is an XCTest API violation that aborts the
        // whole process (SIGABRT) — and a debounce work item can land
        // late (a stalled runner pushes the fire past the timeout) or a
        // buggy `cancel()` can leak a 2nd fire. The guard turns both into
        // a harmless `fireCount` bump that the final assert catches,
        // never an abort. `observer.stop()` then cancels anything still
        // pending. All of `live` / `fireCount` are touched only on the
        // main actor (the test + the @MainActor callback), so no race.
        var fireCount = 0
        var live = true
        let fired = expectation(description: "debounce fires")
        let observer = DisplayChangeObserver(
            onChange: { fireCount += 1; if live { fired.fulfill() } },
            debounceInterval: 0.05)

        observer.schedule()
        observer.schedule()
        observer.schedule()

        // Synchronously, nothing has fired yet (work items queued).
        XCTAssertEqual(fireCount, 0)

        wait(for: [fired], timeout: 2.0)
        live = false        // no fulfill() may run after the wait returns
        observer.stop()     // cancel any still-pending work item

        XCTAssertEqual(fireCount, 1,
                       "burst of 3 schedule() calls must "
                       + "produce exactly 1 fire")
    }

    func testStopCancelsPendingFire() {
        // schedule() then stop() before the timer fires → no fire at
        // all. Otherwise observer.deinit could miss a queued fire and
        // surprise consumers.
        //
        // Proving a *non*-event needs a bounded wall-clock window; an
        // inverted expectation makes it exact (passes iff `onChange`
        // does NOT fire within the window). `fulfill()` is again gated
        // on `live` so a fire that somehow lands after the wait can't
        // abort the process — it just bumps `fireCount`, which the
        // assert catches.
        var fireCount = 0
        var live = true
        let exp = expectation(description: "no fire after stop")
        exp.isInverted = true
        let observer = DisplayChangeObserver(
            onChange: { fireCount += 1; if live { exp.fulfill() } },
            debounceInterval: 0.1)

        observer.schedule()
        observer.stop()

        wait(for: [exp], timeout: 0.5)
        live = false

        XCTAssertEqual(fireCount, 0,
                       "stop() must cancel pending fire")
    }
}
