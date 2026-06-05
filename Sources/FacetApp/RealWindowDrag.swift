// Real-window mouse gestures (枠C): drag a tiled window onto another to
// swap / insert it (機能1), or drag a window's edge to resize it with the
// neighbour following along (機能2). Both ride ONE global mouse monitor —
// the gesture self-classifies from what the grabbed window does: its size
// changing ⇒ a resize, its position-only change ⇒ a move/drop.
//
// Detection is a global, OBSERVE-ONLY NSEvent monitor on the left mouse
// button — facet never intercepts, so the OS still moves / resizes the
// window the user is dragging. Reading the grab from the MOUSE (not from
// AX window-moved/resized events) is deliberate: facet's own programmatic
// frame writes carry no mouse-down, so they're excluded for free — no
// feedback loop.
//
// The monitor itself stays a tiny gesture state machine (down → threshold
// → drag → up); ALL geometry / AX / decision logic lives in the
// Controller, which polls the grabbed window's live frame through the
// backend and classifies. On mouse-up the gesture is resolved
// authoritatively in `resolveLiveDragEnd` (off-main): a size change ⇒
// resize settle, otherwise ⇒ the pure `RealWindowDrop` (FacetCore)
// resolves the swap / insert. Resolving on release (not optimistically
// mid-drag) keeps a fast edge-resize that ends over a neighbour from
// being mis-committed as a swap.

import AppKit
import FacetCore

@MainActor
final class RealWindowDragMonitor {
    /// The active workspace's non-floating tiled windows with their live
    /// Quartz (top-left origin) frames — the same coordinate space the
    /// cursor is flipped into below and that `RealWindowDrop` expects.
    private let tiles: () -> [(id: WindowID, frame: CGRect)]
    /// Live drag tick (armed drags only): the dragged window, the current
    /// cursor in Quartz coords, and the window's frame AT GRAB time. The
    /// Controller self-classifies (live size vs grab ⇒ resize, else move)
    /// and drives either the resize-follow or the move prediction. Called
    /// frequently; the Controller throttles.
    private let onMove: (WindowID, CGPoint, CGRect) -> Void
    /// Mouse-up on an armed drag: hand the gesture to the Controller to
    /// resolve authoritatively off-main (resize settle vs swap / insert
    /// drop). Replaces in-monitor drop resolution so a fast resize that
    /// ends over a neighbour can't be mis-committed as a swap.
    private let resolveEnd: (WindowID, CGPoint, CGRect) -> Void
    /// Drag gesture ended (mouse-up) — tear the overlay down.
    private let onEnd: () -> Void

    private var monitor: Any?
    private var dragged: WindowID?
    /// The dragged window's frame at grab time — the baseline the
    /// Controller's self-classification compares the live frame against:
    /// `.size` decides resize-vs-move, `.origin` confirms a real move
    /// before committing a drop.
    private var grabFrame: CGRect = .zero
    private var liftQuartz: CGPoint = .zero
    private var dragging = false

    /// True from the moment the press lands on a tiled window until
    /// mouse-up — i.e. the *whole* gesture, not just after the drag
    /// threshold. The Controller gates its refresh on this so facet's
    /// per-refresh re-tile can't fight the drag (snap the window back),
    /// including the brief pre-threshold window where the OS has already
    /// started moving / resizing the window but we haven't armed yet.
    /// Also freezes `lastWorkspaces` at the pre-drag layout, keeping the
    /// drop hit-test's reference frames stable. A plain click gates it for
    /// only the few ms between mouse-down and -up — harmless.
    var inProgress: Bool { dragged != nil }
    /// Pointer travel before a mouse-down becomes a drag (matches the
    /// tree's `dragThreshold`); below it the gesture stays a click.
    private let threshold: CGFloat = 6

    init(tiles: @escaping () -> [(id: WindowID, frame: CGRect)],
         onMove: @escaping (WindowID, CGPoint, CGRect) -> Void = { _, _, _ in },
         resolveEnd: @escaping (WindowID, CGPoint, CGRect) -> Void = { _, _, _ in },
         onEnd: @escaping () -> Void = {}) {
        self.tiles = tiles
        self.onMove = onMove
        self.resolveEnd = resolveEnd
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

    private func reset() { dragged = nil; dragging = false; grabFrame = .zero }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            // Remember which tiled window (if any) the press landed on and
            // its grab-time frame; a press on no tile is not a gesture we
            // manage.
            liftQuartz = Self.quartzMouse()
            let t = tiles()
            dragged = RealWindowDrop.window(t, at: liftQuartz)
            grabFrame = dragged.flatMap { id in
                t.first { $0.id == id }?.frame } ?? .zero
            dragging = false
            Log.debug("rwdrag grab "
                + "\(dragged.map { String($0.serverID) } ?? "none") "
                + "at=(\(Int(liftQuartz.x)),\(Int(liftQuartz.y)))")
        case .leftMouseDragged:
            guard let id = dragged else { return }
            let p = Self.quartzMouse()
            if !dragging,
               hypot(p.x - liftQuartz.x, p.y - liftQuartz.y) > threshold {
                dragging = true
            }
            if dragging { onMove(id, p, grabFrame) }   // Controller classifies
        case .leftMouseUp:
            defer { reset() }
            onEnd()                              // tear the overlay down
            // A press without a drag is a click — leave it alone. An armed
            // drag is resolved by the Controller (resize settle, or a drop
            // that resolves to nil → facet's normal reflow re-tiles back).
            guard let id = dragged, dragging else { return }
            resolveEnd(id, Self.quartzMouse(), grabFrame)
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

/// Live resize-follow tuning (枠C 機能2). Calibrated against the FOLLOW
/// peers (AeroSpace 5px dead-zone, yabai 15fps): a per-tick dead-zone kills
/// AX-poll sub-pixel jitter (else the neighbour shimmers), the throttle
/// caps neighbour AX writes, and the classify threshold tells a real resize
/// from a title-bar move. A plain (non-isolated) namespace so the off-main
/// `cliQueue` tick can read it without crossing the `@MainActor` boundary.
private enum ResizeTuning {
    static let throttle: TimeInterval = 1.0 / 30.0   // ~30fps neighbour writes
    static let deadZone: CGFloat = 4                 // per-tick jitter floor
    static let classify: CGFloat = 4                 // size Δ ⇒ resize, not move
    /// Min origin travel before mouse-up commits a swap / insert — a
    /// "did the window move at all" floor, not a distance gate. Kept WELL
    /// BELOW the 6px (Euclidean) drag-arm threshold so every armed drag
    /// that lands on a target still commits (a 6px diagonal arms at ~5px
    /// per axis, so a 6px per-axis floor would wrongly drop it). Its sole
    /// job is to reject the static "edge-drag a min-size window that can't
    /// shrink, release over a neighbour" case — there neither size nor
    /// origin moves (origin Δ ≈ 0), so a 3px floor (absorbing AX jitter)
    /// rejects it while passing any real move.
    static let moveCommit: CGFloat = 3
}

extension Controller {
    /// Wire up the real-window gesture monitor: tile frames come from
    /// `lastWorkspaces`, the drag tick self-classifies (resize follow vs
    /// move prediction), and mouse-up resolves off-main.
    func installRealWindowDrag() {
        realWindowDrag = RealWindowDragMonitor(
            tiles: { [weak self] in self?.activeTiles() ?? [] },
            onMove: { [weak self] dragged, cursor, grabFrame in
                self?.liveDragTick(dragged: dragged, cursor: cursor,
                                   grabFrame: grabFrame)
            },
            resolveEnd: { [weak self] dragged, cursor, grabFrame in
                self?.resolveLiveDragEnd(dragged: dragged, cursor: cursor,
                                         grabFrame: grabFrame)
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

    /// One live drag tick. Throttled to ~30fps behind an in-flight gate.
    /// Polls the dragged window's live frame off-main and self-classifies:
    /// size grew / shrank vs the grab size ⇒ a real-window resize (follow
    /// it, NEIGHBOURS only — the OS owns the dragged window's frame);
    /// otherwise it's a 機能1 move (drive the drop-prediction overlay). A
    /// per-tick dead-zone drops sub-pixel AX-poll jitter so the neighbour
    /// doesn't shimmer.
    private func liveDragTick(dragged: WindowID, cursor: CGPoint,
                              grabFrame: CGRect) {
        if liveResizeInFlight { return }
        if Date().timeIntervalSince(liveResizeLastAt) < ResizeTuning.throttle {
            return
        }
        liveResizeLastAt = Date()
        liveResizeInFlight = true
        let bk = backend
        let lastFrame = liveResizeLastFrame
        // Captured on main; the in-flight gate serialises ticks so these
        // reflect the prior tick's committed result.
        let prevResized = liveResizePrevResized
        let alreadyResize = liveGestureIsResize
        cliQueue.async { [weak self] in
            guard let live = bk.windowFrame(dragged) else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.liveResizeInFlight = false }
                }
                return
            }
            let resized =
                abs(live.width  - grabFrame.width)  > ResizeTuning.classify ||
                abs(live.height - grabFrame.height) > ResizeTuning.classify
            // Treat the gesture as a resize once it's latched, or once TWO
            // consecutive ticks see the size changed — so a single-frame OS
            // size blip during a move can't latch resize / write a ratio.
            let isResize = alreadyResize || (resized && prevResized)
            // Per-tick dead-zone: skip the neighbour write when the frame
            // barely moved since the last applied follow (AX poll jitter).
            let movedEnough = lastFrame.map { f in
                abs(live.minX   - f.minX)   > ResizeTuning.deadZone ||
                abs(live.minY   - f.minY)   > ResizeTuning.deadZone ||
                abs(live.width  - f.width)  > ResizeTuning.deadZone ||
                abs(live.height - f.height) > ResizeTuning.deadZone
            } ?? true
            if isResize, movedEnough {
                bk.resizeWindow(dragged, to: live, reflowDragged: false)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.liveResizeInFlight = false
                    self.liveResizePrevResized = resized
                    if isResize {
                        // Latch: once a resize, stay one for the gesture —
                        // never flash the move overlay even if a later tick
                        // momentarily reads back the grab size.
                        self.liveGestureIsResize = true
                        if movedEnough { self.liveResizeLastFrame = live }
                        self.dndOverlay.hide()
                    } else if !resized, !self.liveGestureIsResize {
                        // Only paint the move overlay on a clean non-resize
                        // tick. A resized-but-unconfirmed tick (the 1st of a
                        // genuine resize, or a 1-frame blip in a move) waits
                        // — no overlay flash, no ratio write.
                        self.updateDropPrediction(dragged: dragged,
                                                  cursor: cursor)
                    }
                }
            }
        }
    }

    /// Mouse-up: resolve the gesture authoritatively. Polls the dragged
    /// window's live frame once off-main; a size change vs grab ⇒ resize
    /// (settle: full reflow snaps it onto its slot), otherwise it's a 機能1
    /// move ⇒ resolve + commit the swap / insert. `tiles` is captured on
    /// main first (lastWorkspaces is frozen during the drag); the AX read
    /// + apply then run off-main.
    private func resolveLiveDragEnd(dragged: WindowID, cursor: CGPoint,
                                    grabFrame: CGRect) {
        let tiles = activeTiles()
        let bk = backend
        cliQueue.async { [weak self] in
            let live = bk.windowFrame(dragged)
            let resized = live.map {
                abs($0.width  - grabFrame.width)  > ResizeTuning.classify ||
                abs($0.height - grabFrame.height) > ResizeTuning.classify
            } ?? false
            if resized, let live {
                // Settle: full reflow (incl. the dragged window) snaps it
                // onto its freshly-computed slot, ≈ where the user left it.
                bk.resizeWindow(dragged, to: live, reflowDragged: true)
                Log.debug("rwdrag resize settle dragged=\(dragged.serverID)")
            } else {
                // 機能1 move. Only commit a drop when the window genuinely
                // moved (origin travelled) — or when its frame couldn't be
                // read (preserve feature-1 robustness). Rejects the at-min
                // edge-drag false positive (neither size nor origin moved).
                let moved = live.map {
                    abs($0.minX - grabFrame.minX) > ResizeTuning.moveCommit ||
                    abs($0.minY - grabFrame.minY) > ResizeTuning.moveCommit
                } ?? true
                if moved, let decision = RealWindowDrop.drop(tiles,
                                                             dragged: dragged,
                                                             at: cursor) {
                    switch decision.zone {
                    case .center:
                        bk.swapWindows(decision.dragged, decision.target)
                    case .edge(let edge):
                        bk.insertWindow(decision.dragged, beside: decision.target,
                                        edge: edge)
                    }
                    Log.debug("rwdrag commit \(decision.zone) "
                        + "dragged=\(dragged.serverID) "
                        + "target=\(decision.target.serverID)")
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.endLiveDrag() }
            }
        }
    }

    /// Clear the live-drag follow state once a gesture fully resolves.
    private func endLiveDrag() {
        liveGestureIsResize = false
        liveResizeLastFrame = nil
        liveResizeInFlight = false
        liveResizePrevResized = false
    }

    /// Drag tick (move gesture): resolve the drop under the cursor and
    /// (throttled) ask the backend for the resulting layout, then paint
    /// the overlay. No target under the cursor → hide it.
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
