// Phase δ observer: fires a single callback after the OS
// finishes a display reconfiguration (resolution change,
// arrangement, hot-plug, lid open/close, sleep wake).
//
// Why a debounced wrapper around `NSApplication.didChangeScreenParametersNotification`:
//
//   A single reconfig event tends to fire that notification
//   2–3 times in quick succession (mid-transition states get
//   reported separately from the final stable layout). If the
//   handler does AX setPosition / setSize per notification, it
//   chases a moving target — and on slow apps each AX call has
//   a non-trivial timeout. Coalescing to one fire 0.5 s after
//   the *last* notification means the handler runs once, on
//   the final stable layout.
//
// API mirrors `WindowEventObserver` deliberately: same
// `init(onChange:)` / `start()` / `stop()` shape so the two
// observers compose the same way inside their owners
// (NativeAdapter / Controller).
//
// Pattern: hand the handler a Sendable `@MainActor` closure;
// observer starts a `NotificationCenter` subscription on
// `NSApp.notificationCenter`, holds a `DispatchWorkItem` as
// the pending-fire token, and cancel/reschedules on every
// new notification.

import AppKit
import Foundation

public final class DisplayChangeObserver: @unchecked Sendable {

    public typealias Callback = @MainActor () -> Void

    /// Debounce window between the last received notification
    /// and the callback fire. 0.5 s coalesces typical reconfig
    /// bursts (2–3 events in <200 ms) without being so long
    /// that the layout feels stuck mid-transition.
    public static let debounceInterval: TimeInterval = 0.5

    private let onChange: Callback
    private let interval: TimeInterval
    private var token: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    public init(onChange: @escaping Callback,
                debounceInterval: TimeInterval = debounceInterval) {
        self.onChange = onChange
        self.interval = debounceInterval
    }

    /// Subscribe to `NSApplication.didChangeScreenParametersNotification`
    /// on the main queue. Each notification cancels any
    /// outstanding pending fire and schedules a fresh one
    /// `interval` seconds out.
    @MainActor
    public func start() {
        // Idempotent — calling start() twice without stop()
        // would otherwise stack subscriptions.
        guard token == nil else { return }
        let nc = NotificationCenter.default
        token = nc.addObserver(
            forName:
                NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedule()
            }
        }
    }

    @MainActor
    public func stop() {
        if let t = token {
            NotificationCenter.default.removeObserver(t)
            token = nil
        }
        pending?.cancel()
        pending = nil
    }

    /// Public for testability: lets the test harness simulate a
    /// burst of notifications without registering with the real
    /// `NotificationCenter`. Production code only reaches here
    /// via `start()`'s observer block.
    @MainActor
    public func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval,
                                      execute: work)
    }
}
