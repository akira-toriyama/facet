// AX-driven event subscription per running app.
//
// Wires `kAXFocusedWindowChanged` / `kAXWindowCreated` /
// `kAXUIElementDestroyed` for every running NSRunningApplication
// and folds NSWorkspace's `didLaunch` / `didTerminate` for app
// lifecycle so the observer set stays in sync. Every interesting
// event fires the single `onChange` callback — adapters wire
// that to their reconcile / BackendEvent.refreshNeeded path.
//
// Why this matters for facet
//
// The Controller's 2 s pollTimer keeps refresh honest in the
// worst case, but a 2 s lag between "user opened a window" and
// "facet sees it" is noticeable in workspace ops (move the new
// window before the snapshot includes it → guard fails → user
// retries). AX events close that gap to the system's own
// latency (typically <50 ms).
//
// Lifecycle: `start()` once at adapter init, `stop()` if you
// ever need to tear it down (we don't today — facet holds it
// for the lifetime of the process).
//
// Pattern lifted from focusfx's FocusWatcher
// (https://github.com/akira-toriyama/focusfx). Same recipe:
// NSWorkspace notification + per-pid AXObserver + main-runloop
// hookup.

import AppKit
import ApplicationServices
import Foundation

/// Per-app AX event observer. Calls `onChange()` whenever the
/// observed set sees a focus change, window creation, window
/// destruction, or a relevant NSWorkspace app launch / terminate.
///
/// `init` is non-isolated so adapter constructors (which are
/// also non-isolated) can build one. Everything that mutates
/// state — `start` / `stop` / internal `attach` / `detach` /
/// `fire` — is MainActor-only; the AX runloop source is added
/// to the main runloop so callbacks land there too.
public final class WindowEventObserver: @unchecked Sendable {

    public typealias Callback = @MainActor () -> Void

    private let onChange: Callback
    private var observers: [pid_t: AXObserver] = [:]
    private var launchToken: NSObjectProtocol?
    private var terminateToken: NSObjectProtocol?
    /// A drag fires a burst of `kAXWindowMoved`; coalesce them to a
    /// single `onChange` after this much stillness (= drag finished)
    /// so re-tile doesn't run mid-drag and fight the cursor. resize /
    /// focus / create / destroy fire immediately (the Controller's own
    /// 50 ms debounce coalesces those).
    private var moveDebounceTimer: Timer?
    private let moveDebounce: TimeInterval = 0.2

    public init(onChange: @escaping Callback) {
        self.onChange = onChange
    }

    /// Attach AX observers to every currently-running app and
    /// subscribe to NSWorkspace launch / terminate so newcomers
    /// get observed too.
    @MainActor
    public func start() {
        for app in NSWorkspace.shared.runningApplications {
            attach(pid: app.processIdentifier)
        }
        let nc = NSWorkspace.shared.notificationCenter
        // Notification is non-Sendable under Swift 6 strict
        // concurrency. Extract the pid synchronously on the
        // dispatched main queue (we're guaranteed to run there
        // by `queue: .main`), then hop into MainActor isolation
        // with just the Sendable Int32.
        launchToken = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.attach(pid: pid)
                self?.onChange()
            }
        }
        terminateToken = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.detach(pid: pid)
                self?.onChange()
            }
        }
    }

    @MainActor
    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let t = launchToken { nc.removeObserver(t) }
        if let t = terminateToken { nc.removeObserver(t) }
        launchToken = nil
        terminateToken = nil
        for pid in observers.keys { detach(pid: pid) }
    }

    /// Public so the C-style AX callback can route in. Do not call
    /// directly from adapter code. `notification` lets us treat window
    /// moves specially: a drag fires a burst of `kAXWindowMoved`, so
    /// those coalesce to a single fire after `moveDebounce` of
    /// stillness (drag finished). Everything else fires immediately.
    @MainActor
    fileprivate func fire(_ notification: String) {
        guard notification == kAXWindowMovedNotification as String else {
            onChange()
            return
        }
        moveDebounceTimer?.invalidate()
        moveDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: moveDebounce, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange() }
        }
    }

    @MainActor
    private func attach(pid: pid_t) {
        guard observers[pid] == nil, pid > 0 else { return }
        var observer: AXObserver?
        let err = AXObserverCreate(
            pid, axObserverCallback, &observer)
        guard err == .success, let obs = observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let context = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(self).toOpaque())
        for note in [
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowResizedNotification,
            kAXWindowMovedNotification,
        ] as [String] {
            AXObserverAddNotification(
                obs, app, note as CFString, context)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode)
        observers[pid] = obs
    }

    @MainActor
    private func detach(pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .defaultMode)
    }
}

/// AX callback bridge. Runs on the main runloop (we added the
/// observer's source there). Forwards into the Swift object via
/// the refcon pointer captured in `attach`.
private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let obs = Unmanaged<WindowEventObserver>
        .fromOpaque(refcon).takeUnretainedValue()
    let note = notification as String
    MainActor.assumeIsolated { obs.fire(note) }
}
