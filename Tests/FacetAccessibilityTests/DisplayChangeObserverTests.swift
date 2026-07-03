import Testing
@testable import FacetAccessibility

/// `DisplayChangeObserver` is mostly NSNotificationCenter
/// plumbing — the test surface that matters is the debounce:
/// many `schedule()` calls in a burst must produce exactly one
/// `onChange()` fire after the burst settles. The actual
/// `NSApplication.didChangeScreenParameters` notification is
/// reproducible in tests (notification observers fire on any
/// `post(name:)` to the same center), so the lifecycle path
/// is testable end-to-end too.
///
/// `@MainActor` keeps `fireCount` touched only on the main actor — by the
/// test body and by the `@MainActor` `onChange` callback — so there is no
/// race even though the debounce work item lands asynchronously.
@MainActor
struct DisplayChangeObserverTests {

    @Test func debounceCoalescesBurstIntoSingleFire() async {
        // Three `schedule()` calls in the same run-loop tick should
        // collapse into one `onChange` fire after the debounce interval.
        var fireCount = 0
        let observer = DisplayChangeObserver(
            onChange: { fireCount += 1 },
            debounceInterval: 0.05)

        observer.schedule()
        observer.schedule()
        observer.schedule()

        // Synchronously, nothing has fired yet (work items queued).
        #expect(fireCount == 0)

        // Wait (bounded) for the coalesced fire. `await` frees the main actor
        // so the queued debounce work item can run — a real happens-before,
        // not a race against an unrelated wall-clock timer. A healthy run
        // settles in ~0.05s; the 2s cap mirrors the original XCTest timeout
        // for a stalled runner. The 50ms settle tail then lets a spurious 2nd
        // fire (a leaked or duplicate work item) surface in `fireCount`, which
        // the final assert catches.
        var waited = 0.0
        while fireCount == 0 && waited < 2.0 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 0.010
        }
        try? await Task.sleep(for: .milliseconds(50))
        observer.stop()     // cancel any still-pending work item

        #expect(fireCount == 1,
                "burst of 3 schedule() calls must produce exactly 1 fire")
    }

    @Test func stopCancelsPendingFire() async {
        // schedule() then stop() before the timer fires → no fire at
        // all. Otherwise observer.deinit could miss a queued fire and
        // surprise consumers.
        //
        // Proving a *non*-event needs a bounded wall-clock window: wait past
        // the debounce interval and assert nothing fired.
        var fireCount = 0
        let observer = DisplayChangeObserver(
            onChange: { fireCount += 1 },
            debounceInterval: 0.1)

        observer.schedule()
        observer.stop()

        try? await Task.sleep(for: .milliseconds(500))

        #expect(fireCount == 0,
                "stop() must cancel pending fire")
    }
}
