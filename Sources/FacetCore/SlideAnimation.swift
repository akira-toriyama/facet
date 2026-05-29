import CoreGraphics
import Foundation

/// Pure animation math for the window-move animation (枠 E). No AppKit /
/// AX / timer here — FacetCore stays pure. The adapter owns the clock +
/// the per-frame AX writes; these only turn a normalized progress
/// `t ∈ [0, 1]` into an eased value. All clamp `t` to [0, 1].
public enum SlideCurve {
    /// Ease-out cubic: fast start, gentle settle, no overshoot.
    public static func easeOutCubic(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        let inv = 1 - c
        return 1 - inv * inv * inv
    }

    /// Ease-out quint: snappier than cubic (steeper settle), no
    /// overshoot. The "キレ" feel.
    public static func easeOutQuint(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        let i = 1 - c
        return 1 - i * i * i * i * i
    }

    /// Ease-in-out cubic: eased at both ends. Paired with a longer
    /// duration it reads as the silky / luxurious feel.
    public static func easeInOutCubic(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        if c < 0.5 { return 4 * c * c * c }
        let p = -2 * c + 2
        return 1 - (p * p * p) / 2
    }

    /// Underdamped spring step response: overshoot then settle (the
    /// "弾む高級感"). `zeta` (damping, 0–1) sets the bounce — lower =
    /// bigger overshoot / more spring; `omega` the speed. Clamped so a
    /// runaway value can't diverge.
    public static func spring(_ t: Double, zeta: Double = 0.55,
                              omega: Double = 9.0) -> Double {
        let c = min(1, max(0, t))
        if c >= 1 { return 1 }
        let z = min(0.95, max(0.2, zeta))
        let wd = omega * (1 - z * z).squareRoot()
        return 1 - exp(-z * omega * c)
            * (cos(wd * c) + (z * omega / wd) * sin(wd * c))
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
