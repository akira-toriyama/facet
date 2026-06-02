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

    /// Native resize handles sit ON / a few px OUTSIDE a window's frame
    /// edge, so a plain `contains` test misses an edge grab. Match anything
    /// within this band (in points) of a tile's edge as still belonging to
    /// that tile — the peers do the same (winmux uses a 32px candidate
    /// band). Kept modest so a grab in a wide inner gap still resolves to
    /// the nearer window rather than reaching across it.
    public static let grabEdgeMargin: CGFloat = 8

    /// The id of the tiled window the grab `point` belongs to, or `nil`
    /// when it's over none — i.e. not the start of a window gesture we
    /// manage. An interior grab (title bar / body) matches by exact
    /// containment; an EDGE grab (the native resize handle, which straddles
    /// the frame border) matches the NEAREST window whose edge is within
    /// `grabEdgeMargin` — without this, edge-drag resizes intermittently
    /// fail to arm and facet's reflow fights the native resize. `windows`
    /// are the active workspace's non-floating tiled windows with their
    /// live on-screen frames.
    public static func window(_ windows: [(id: WindowID, frame: CGRect)],
                              at point: CGPoint,
                              edgeMargin: CGFloat = grabEdgeMargin) -> WindowID? {
        if let hit = windows.first(where: { $0.frame.contains(point) }) {
            return hit.id                              // interior grab
        }
        let m2 = edgeMargin * edgeMargin
        return windows
            .map { (id: $0.id, d2: Self.edgeDistanceSq($0.frame, point)) }
            .filter { $0.d2 <= m2 }
            .min { $0.d2 < $1.d2 }?
            .id                                        // nearest edge within band
    }

    /// Squared distance from `point` to the nearest edge of `frame`
    /// (0 when inside). Squared to skip the sqrt — only used for
    /// thresholding + nearest comparison, both monotonic.
    private static func edgeDistanceSq(_ frame: CGRect,
                                       _ p: CGPoint) -> CGFloat {
        let dx = max(0, max(frame.minX - p.x, p.x - frame.maxX))
        let dy = max(0, max(frame.minY - p.y, p.y - frame.maxY))
        return dx * dx + dy * dy
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
