import CoreGraphics

/// Pure animation math for the workspace-switch slide (枠 E, Phase 1).
/// No AppKit / AX / timer here — FacetCore stays pure. The adapter owns
/// the clock + the per-frame AX writes; this only turns a normalized
/// progress `t ∈ [0, 1]` into eased interpolated origins.
public enum SlideCurve {
    /// Ease-out cubic: fast start, gentle settle. Matches the "ぬるっと"
    /// feel of scrollable WMs without a spring's overshoot.
    public static func easeOutCubic(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        let inv = 1 - c
        return 1 - inv * inv * inv
    }
}

/// One window's slide: interpolate its origin from `from` to `to`.
/// Size is held constant (set once off-screen before the slide), so the
/// visible motion is pure translation — cheap and smooth over AX.
public struct WindowSlide: Sendable {
    public let id: WindowID
    public let from: CGPoint
    public let to: CGPoint

    public init(id: WindowID, from: CGPoint, to: CGPoint) {
        self.id = id
        self.from = from
        self.to = to
    }

    /// Origin at eased progress `e ∈ [0, 1]` (caller passes the curve
    /// output, not raw `t`).
    public func origin(atEased e: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * e,
                y: from.y + (to.y - from.y) * e)
    }
}
