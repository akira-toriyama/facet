// Two focus-retry strategies, used by the Controller after every
// workspace switch / window move. Both run on `cliQueue` (off-main)
// and self-reschedule via `cliQueue.asyncAfter` until they either
// succeed or hit the attempt cap.
//
// Why two:
//   - `withRetry`  — bounded short retry (~14 attempts ≈ 420 ms).
//                    Same-workspace clicks; no race with the WM
//                    deciding focus, so just try a few times then
//                    give up if AX is being uncooperative.
//   - `assert`     — persistent until the backend confirms (~50
//                    attempts ≈ 1.5 s). Cross-workspace clicks: the
//                    WM applies its OWN default focus shortly after
//                    a switch, so a bounded retry would lose to the
//                    WM's late assertion. This one keeps re-asserting
//                    AX focus and stops only when the backend agrees
//                    the target window is focused.
//
// Shared with FacetAdapterNative via this module (extracted out
// of FacetAdapterRift at M5).

import Foundation
import FacetCore

public enum Focus {

    /// Public so callers can pass an explicit `left:` overriding the
    /// default attempt cap. Not expected to need tuning in practice.
    public static let retryAttempts = 14
    public static let assertAttempts = 50      // ~1.5 s cap; usually stops sooner
    static let interval: TimeInterval = 0.03

    /// Bounded short retry. Stops on first success. For
    /// same-workspace clicks where no WM default-focus race exists.
    public static func withRetry(_ window: Window,
                                 left: Int = retryAttempts) {
        if AX.focus(window) || left <= 0 { return }
        cliQueue.asyncAfter(deadline: .now() + interval) {
            withRetry(window, left: left - 1)
        }
    }

    /// Synchronous twin of `assert` for callers that must run follow-up
    /// work *after* focus is confirmed — e.g. window-ops that act on the
    /// FOCUSED window (`Controller.runWindowOps`): the ops can't run until
    /// the target actually holds focus, and the async `assert` returns
    /// immediately (self-reschedules), so it can't gate a synchronous
    /// sequence. Blocks the CURRENT thread, re-asserting AX focus each
    /// pass until the backend agrees (closed loop on ground truth) or the
    /// cap (~1.5 s) is hit — deterministically beating the WM's
    /// post-switch default focus, where a single focus + fixed sleep loses.
    ///
    /// MUST be called off-main (it sleeps): today only `runWindowOps` on
    /// `cliQueue`. Returns whether focus was confirmed before the cap.
    @discardableResult
    public static func assertBlocking(_ window: Window,
                                      backend: any WindowBackend,
                                      attempts: Int = assertAttempts) -> Bool {
        var left = attempts
        while left > 0 {
            AX.focus(window)
            if backend.focusedWindow() == window.id { return true }
            usleep(useconds_t(interval * 1_000_000))
            left -= 1
        }
        return false
    }

    /// Persistent assertion. Keeps re-asserting AX focus until the
    /// backend's *own* focused-window state agrees (closed loop on
    /// ground truth), or we hit the attempt cap. Deterministically
    /// beats the WM's post-switch default focus instead of racing a
    /// fixed timer. Cross-workspace clicks / DnD moves.
    public static func assert(_ window: Window,
                              backend: any WindowBackend,
                              left: Int = assertAttempts) {
        AX.focus(window)
        // Confirm against backend truth every few attempts (bounds
        // query cost). The "% 3 == 2" cadence × 50-attempt cap means
        // ~17 ground-truth checks per assertion, plenty.
        if (assertAttempts - left) % 3 == 2,
           backend.focusedWindow() == window.id {
            return
        }
        if left <= 0 { return }
        cliQueue.asyncAfter(deadline: .now() + interval) {
            assert(window, backend: backend, left: left - 1)
        }
    }
}
