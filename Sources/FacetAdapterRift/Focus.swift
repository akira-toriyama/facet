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
// MOVE-AT-M5: same as AXFocus.swift / AXTitles.swift — not really
// rift-specific; the native adapter will need identical helpers.
// Move alongside those when FacetAccessibility lands.

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
        // query cost). The "% 3 == 2" cadence is what ws-tabs ran
        // and the 50-attempt cap means ~17 ground-truth checks per
        // assertion, plenty.
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
