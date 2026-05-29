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

/// One window's tween: interpolate its frame from `from` to `to`.
/// Workspace-switch slides keep the size constant (so `resizes` is false
/// and the adapter skips setSize — pure translation); layout / retile
/// transitions change size too, and `resizes` flips on.
public struct WindowSlide: Sendable {
    public let id: WindowID
    public let from: CGRect
    public let to: CGRect

    public init(id: WindowID, from: CGRect, to: CGRect) {
        self.id = id
        self.from = from
        self.to = to
    }

    /// Frame at eased progress `e ∈ [0, 1]` (caller passes the curve
    /// output, not raw `t`).
    public func frame(atEased e: Double) -> CGRect {
        let f = CGFloat(e)
        return CGRect(x: from.minX + (to.minX - from.minX) * f,
                      y: from.minY + (to.minY - from.minY) * f,
                      width: from.width + (to.width - from.width) * f,
                      height: from.height + (to.height - from.height) * f)
    }

    /// True when the size changes across the tween — the adapter only
    /// issues a per-frame setSize (heavier than setPosition) when so.
    public var resizes: Bool { from.size != to.size }
}
