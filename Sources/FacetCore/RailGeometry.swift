// Pure geometry for the workspace rail (`--view=rail`).
//
// The rail docks a STRIP of every-workspace mini-screens against one
// screen edge and fills the rest with a large HERO of the browsed
// workspace. M9-3 generalised the original fixed-bottom band to any of
// the four edges; this file holds the edge-neutral, AppKit-free maths so
// it stays unit-testable (the view layer applies the result through
// AppKit). All rects are in the rail view's FLIPPED (y-down) space, so
// `.bottom` sits at max-Y and `.top` at min-Y.

import CoreGraphics

/// Which way the rail's strip of mini-screens runs.
public enum RailAxis: Sendable, Equatable {
    /// Cells tile left→right; the browse keys are ←/→ (top / bottom edges).
    case horizontal
    /// Cells tile top→bottom; the browse keys are ↑/↓ (left / right edges).
    case vertical
}

/// Which screen edge the rail's strip docks against. The default is
/// `.bottom` (the original Mission-Control-style bottom bar).
public enum RailEdge: String, Sendable, CaseIterable {
    case top, bottom, left, right

    /// The strip runs across the screen for top/bottom, down it for
    /// left/right — this also picks which arrow keys browse it.
    public var axis: RailAxis {
        (self == .top || self == .bottom) ? .horizontal : .vertical
    }
}

/// Split the rail's `bounds` into a strip band docked against `edge`
/// and the hero area filling the rest. `thickness` is the strip's
/// cross-axis size (height for top/bottom, width for left/right),
/// clamped so it never exceeds the bounds. `outerPad` insets the hero
/// from the three outer edges and `heroGap` separates it from the
/// strip. Pure — same inputs → same output, unit-testable without a
/// display.
public func railBands(in bounds: CGRect, edge: RailEdge,
                      thickness: CGFloat, outerPad: CGFloat,
                      heroGap: CGFloat) -> (strip: CGRect, hero: CGRect) {
    let crossMax = edge.axis == .horizontal ? bounds.height : bounds.width
    let t = max(0, min(thickness, crossMax))
    func clampedHero(_ x: CGFloat, _ y: CGFloat,
                     _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
    }
    switch edge {
    case .bottom:
        let strip = CGRect(x: bounds.minX, y: bounds.maxY - t,
                           width: bounds.width, height: t)
        let top = bounds.minY + outerPad
        let hero = clampedHero(bounds.minX + outerPad, top,
                               bounds.width - outerPad * 2,
                               (bounds.maxY - t - heroGap) - top)
        return (strip, hero)
    case .top:
        let strip = CGRect(x: bounds.minX, y: bounds.minY,
                           width: bounds.width, height: t)
        let top = bounds.minY + t + heroGap
        let hero = clampedHero(bounds.minX + outerPad, top,
                               bounds.width - outerPad * 2,
                               (bounds.maxY - outerPad) - top)
        return (strip, hero)
    case .left:
        let strip = CGRect(x: bounds.minX, y: bounds.minY,
                           width: t, height: bounds.height)
        let left = bounds.minX + t + heroGap
        let hero = clampedHero(left, bounds.minY + outerPad,
                               (bounds.maxX - outerPad) - left,
                               bounds.height - outerPad * 2)
        return (strip, hero)
    case .right:
        let strip = CGRect(x: bounds.maxX - t, y: bounds.minY,
                           width: t, height: bounds.height)
        let left = bounds.minX + outerPad
        let hero = clampedHero(left, bounds.minY + outerPad,
                               (bounds.maxX - t - heroGap) - left,
                               bounds.height - outerPad * 2)
        return (strip, hero)
    }
}

/// Signed slot offsets for the active-centred carousel rail (2-b). For
/// a strip of `count` workspaces with the selected one at array position
/// `selectedPos`, returns — for every position `0..<count` — its offset
/// from the centre in slot units: `0` = centre (the selected workspace),
/// negative = before it, positive = after, wrapping circularly so the
/// selected sits at slot `floor(count/2)` and the rest fan out around it
/// (even counts bias the selected one slot right). The view multiplies
/// each offset by the slot size and pins the centre at the strip's
/// along-centre; cells far from the centre fall outside the viewport and
/// clip to a peek. Pure / testable.
///
/// Example (count 5, selected = ws5 at pos 4) → ws3 −2, ws4 −1, ws5 0,
/// ws1 +1, ws2 +2 ⇒ displayed `[ws3][ws4][ws5][ws1][ws2]`.
public func railCarouselOffsets(count: Int, selectedPos: Int) -> [Int] {
    guard count > 0 else { return [] }
    let p0 = ((selectedPos % count) + count) % count
    let centerSlot = count / 2
    return (0..<count).map { p in
        ((p - p0 + centerSlot + count) % count) - centerSlot
    }
}
