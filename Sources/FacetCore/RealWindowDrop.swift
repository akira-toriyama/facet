// Resolving a real-window drag (枠C) to a backend op, purely from
// geometry: which tiled window was grabbed, which one it was dropped
// onto, and the intent (swap vs insert-on-edge). Kept pure so the
// PR-2 commit and the PR-3 live-prediction overlay run the SAME
// resolution and can never disagree about what a drop will do.

import CoreGraphics

/// The outcome of a real-window drop, for the prediction overlay (枠C
/// PR-3): every tiled window's resulting frame, plus which of them the
/// drop actually relocates — so the overlay can highlight only those and
/// leave the untouched windows alone (a clean, screenshot-like look).
public struct DropPrediction: Sendable, Equatable {
    public let frames: [WindowID: CGRect]
    public let moved: Set<WindowID>
    public init(frames: [WindowID: CGRect], moved: Set<WindowID>) {
        self.frames = frames
        self.moved = moved
    }
    public static let none = DropPrediction(frames: [:], moved: [])
}

public enum RealWindowDrop {

    /// A resolved drop: swap `dragged` with `target`, or — when `zone`
    /// is an edge — insert `dragged` beside `target` on that edge.
    public struct Decision: Sendable, Equatable {
        public let dragged: WindowID
        public let target: WindowID
        public let zone: IntentZone
        public init(dragged: WindowID, target: WindowID, zone: IntentZone) {
            self.dragged = dragged
            self.target = target
            self.zone = zone
        }
    }

    /// The id of the tiled window whose frame contains `point` (the
    /// grab point), or `nil` when the point is over no tiled window —
    /// i.e. not the start of a window drag we manage. `windows` are the
    /// active workspace's non-floating tiled windows with their live
    /// on-screen frames; tile slots don't overlap, so at most one hits.
    public static func window(_ windows: [(id: WindowID, frame: CGRect)],
                              at point: CGPoint) -> WindowID? {
        windows.first { $0.frame.contains(point) }?.id
    }

    /// Resolve dropping `dragged` at `point`: find the tiled window
    /// (other than `dragged`) under the point and the intent zone within
    /// it. `nil` when the point is over nothing or over `dragged` itself
    /// — the caller then leaves the layout untouched and the window just
    /// re-tiles back to its slot.
    public static func drop(_ windows: [(id: WindowID, frame: CGRect)],
                            dragged: WindowID,
                            at point: CGPoint) -> Decision? {
        guard let target = windows.first(where: {
            $0.id != dragged && $0.frame.contains(point)
        }) else { return nil }
        return Decision(dragged: dragged, target: target.id,
                        zone: intentZone(at: point, in: target.frame))
    }
}
