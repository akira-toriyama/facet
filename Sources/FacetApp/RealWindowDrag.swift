// Real-window mouse DnD (枠C PR-2): drag a tiled window onto another to
// swap with it / insert beside it. PR-2 is the working interaction — no
// live prediction overlay yet (that's PR-3, the 演出).
//
// Detection is a global, OBSERVE-ONLY NSEvent monitor on the left mouse
// button — facet never intercepts, so the OS still moves the window the
// user is dragging. Detecting the grab from the MOUSE (not from AX
// window-moved events) is deliberate: facet's own programmatic moves
// carry no mouse-down, so they're excluded for free — no feedback loop.
//
// On mouse-up the drop is resolved against the active workspace's live
// tile frames by the pure `RealWindowDrop` (FacetCore) and committed via
// the backend's swapWindows / insertWindow verbs (枠C PR-1). The commit
// re-tiles through the existing reflow + SlideAnimation, so the dragged
// window settles into its new slot.

import AppKit
import FacetCore

@MainActor
final class RealWindowDragMonitor {
    /// The active workspace's non-floating tiled windows with their live
    /// Quartz (top-left origin) frames — the same coordinate space the
    /// cursor is flipped into below and that `RealWindowDrop` expects.
    private let tiles: () -> [(id: WindowID, frame: CGRect)]
    /// Commit a resolved drop (called on the main actor; the closure is
    /// responsible for hopping the backend call off-main).
    private let commit: (RealWindowDrop.Decision) -> Void
    /// Live drag tick (armed drags only): the dragged window + the
    /// current cursor in Quartz coords — drives the PR-3 prediction
    /// overlay. Called frequently; the handler throttles.
    private let onMove: (WindowID, CGPoint) -> Void
    /// Drag gesture ended (mouse-up) — tear the overlay down.
    private let onEnd: () -> Void

    private var monitor: Any?
    private var dragged: WindowID?
    private var liftQuartz: CGPoint = .zero
    private var dragging = false

    /// True from the moment the press lands on a tiled window until
    /// mouse-up — i.e. the *whole* gesture, not just after the drag
    /// threshold. The Controller gates its refresh on this so facet's
    /// per-refresh re-tile can't fight the drag (snap the window back),
    /// including the brief pre-threshold window where the OS has already
    /// started moving the window but we haven't armed yet. Also freezes
    /// `lastWorkspaces` at the pre-drag layout, keeping the drop
    /// hit-test's reference frames stable. A plain click gates it for
    /// only the few ms between mouse-down and -up — harmless.
    var inProgress: Bool { dragged != nil }
    /// Pointer travel before a mouse-down becomes a drag (matches the
    /// tree's `dragThreshold`); below it the gesture stays a click.
    private let threshold: CGFloat = 6

    init(tiles: @escaping () -> [(id: WindowID, frame: CGRect)],
         commit: @escaping (RealWindowDrop.Decision) -> Void,
         onMove: @escaping (WindowID, CGPoint) -> Void = { _, _ in },
         onEnd: @escaping () -> Void = {}) {
        self.tiles = tiles
        self.commit = commit
        self.onMove = onMove
        self.onEnd = onEnd
    }

    func start() {
        guard monitor == nil else { return }
        // Global monitors fire for OTHER apps' windows (what we want);
        // facet's own panel goes through local monitors, so dragging the
        // panel never trips this. Observe-only — the return value is
        // ignored and the event still reaches its target.
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        reset()
    }

    private func reset() { dragged = nil; dragging = false }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            // Remember which tiled window (if any) the press landed on;
            // a press on no tile is not a window-drag we manage.
            liftQuartz = Self.quartzMouse()
            dragged = RealWindowDrop.window(tiles(), at: liftQuartz)
            dragging = false
        case .leftMouseDragged:
            guard let id = dragged else { return }
            let p = Self.quartzMouse()
            if !dragging,
               hypot(p.x - liftQuartz.x, p.y - liftQuartz.y) > threshold {
                dragging = true
            }
            if dragging { onMove(id, p) }        // feed the prediction overlay
        case .leftMouseUp:
            defer { reset() }
            onEnd()                              // tear the overlay down
            // A press without a drag is a click — leave it alone. A drag
            // onto empty space / the window's own slot resolves to nil;
            // facet's normal reflow then re-tiles it back into place.
            guard let id = dragged, dragging,
                  let decision = RealWindowDrop.drop(tiles(), dragged: id,
                                                     at: Self.quartzMouse())
            else { return }
            Log.debug("rwdrag commit \(decision.zone) "
                + "dragged=\(id.serverID) target=\(decision.target.serverID)")
            commit(decision)
        default:
            break
        }
    }

    /// Cursor in Quartz (top-left origin) screen coords, matching the
    /// backend's window frames. `NSEvent.mouseLocation` is AppKit
    /// (bottom-left); flip Y against the primary screen height (same
    /// convention as `Controller.cgFrameToAppKit`).
    static func quartzMouse() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }?
            .frame.height) ?? NSScreen.main?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryH - p.y)
    }
}

extension Controller {
    /// Wire up the real-window DnD monitor: tile frames come from
    /// `lastWorkspaces`, the drag tick drives the prediction overlay, and
    /// drops commit off-main via the backend's swap / insert verbs.
    func installRealWindowDrag() {
        realWindowDrag = RealWindowDragMonitor(
            tiles: { [weak self] in self?.activeTiles() ?? [] },
            commit: { [weak self] in self?.commitDrop($0) },
            onMove: { [weak self] dragged, cursor in
                self?.updateDropPrediction(dragged: dragged, cursor: cursor)
            },
            onEnd: { [weak self] in self?.dndOverlay.hide() })
        realWindowDrag?.start()
    }

    /// The active workspace's non-floating tiled windows + their live
    /// Quartz (top-left) frames — the hit-test / prediction reference set.
    private func activeTiles() -> [(id: WindowID, frame: CGRect)] {
        guard let ws = lastWorkspaces.first(where: { $0.isActive })
        else { return [] }
        return ws.windows.compactMap { w in
            guard !w.isFloating, let f = w.frame else { return nil }
            return (id: w.id, frame: f)
        }
    }

    private func commitDrop(_ decision: RealWindowDrop.Decision) {
        let bk = backend
        cliQueue.async {
            switch decision.zone {
            case .center:
                bk.swapWindows(decision.dragged, decision.target)
            case .edge(let edge):
                bk.insertWindow(decision.dragged, beside: decision.target,
                                edge: edge)
            }
        }
    }

    /// Drag tick: resolve the drop under the cursor and (throttled) ask
    /// the backend for the resulting layout, then paint the overlay. No
    /// target under the cursor → hide it.
    private func updateDropPrediction(dragged: WindowID, cursor: CGPoint) {
        let tiles = activeTiles()
        guard let decision = RealWindowDrop.drop(tiles, dragged: dragged,
                                                 at: cursor) else {
            dndOverlay.hide(); return
        }
        if dndPredictionInFlight { return }            // throttle to backend rate
        dndPredictionInFlight = true
        let bk = backend
        cliQueue.async { [weak self] in
            let prediction = bk.predictedDrop(dragged: decision.dragged,
                                              target: decision.target,
                                              zone: decision.zone)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.paintPrediction(decision, prediction)
                    self?.dndPredictionInFlight = false
                }
            }
        }
    }

    private func paintPrediction(_ decision: RealWindowDrop.Decision,
                                 _ prediction: DropPrediction) {
        // Spotlight the change: the windows the drop MOVES are lit (the
        // dragged one + whatever the swap / insert reshapes), the rest are
        // dimmed — so we hand the overlay the WHOLE predicted layout and
        // mark which ids moved.
        guard !prediction.moved.isEmpty else { dndOverlay.hide(); return }
        var appkit: [WindowID: NSRect] = [:]
        for (id, f) in prediction.frames {
            appkit[id] = Self.cgFrameToAppKit(f)
        }
        let union = appkit.values.reduce(NSRect.null) { $0.union($1) }
        guard !union.isNull, !union.isEmpty else { dndOverlay.hide(); return }
        dndOverlay.show(screen: union.insetBy(dx: -8, dy: -8),
                        frames: appkit, dragged: decision.dragged,
                        affected: prediction.moved.subtracting([decision.dragged]))
    }
}
