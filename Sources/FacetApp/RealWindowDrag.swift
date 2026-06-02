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
         commit: @escaping (RealWindowDrop.Decision) -> Void) {
        self.tiles = tiles
        self.commit = commit
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
            guard dragged != nil, !dragging else { return }
            let p = Self.quartzMouse()
            if hypot(p.x - liftQuartz.x, p.y - liftQuartz.y) > threshold {
                dragging = true
            }
        case .leftMouseUp:
            defer { reset() }
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
    /// Wire up the real-window DnD monitor: read the active workspace's
    /// tile frames from `lastWorkspaces`, commit drops off-main via the
    /// backend's swap / insert verbs.
    func installRealWindowDrag() {
        realWindowDrag = RealWindowDragMonitor(
            tiles: { [weak self] in
                guard let self,
                      let ws = self.lastWorkspaces.first(where: { $0.isActive })
                else { return [] }
                return ws.windows.compactMap { w in
                    guard !w.isFloating, let f = w.frame else { return nil }
                    return (id: w.id, frame: f)
                }
            },
            commit: { [weak self] decision in
                guard let self else { return }
                let bk = self.backend
                cliQueue.async {
                    switch decision.zone {
                    case .center:
                        bk.swapWindows(decision.dragged, decision.target)
                    case .edge(let edge):
                        bk.insertWindow(decision.dragged,
                                        beside: decision.target, edge: edge)
                    }
                }
            })
        realWindowDrag?.start()
    }
}
