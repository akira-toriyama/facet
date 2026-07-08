// Pure geometry for the workspace rail (`--view rail`).
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

// MARK: - Responsive sizing (orientation- & display-size-aware)

/// The rail's spacing scaled to the display, so the strip's float off
/// the docked edge, its gap to the hero and the hero's outer inset stay
/// proportional in any orientation or on any display size. Each is a
/// fraction of the **short** screen edge — orientation-stable, since the
/// short edge stays the short edge whichever way the display is turned
/// (the old rail used fixed points, which read cramped on large screens
/// and let the strip dominate a portrait display). Pure / testable.
public func railScaledPads(screen: CGSize,
                           edgeFloatFrac: CGFloat,
                           heroGapFrac: CGFloat,
                           outerFrac: CGFloat)
    -> (edgeFloat: CGFloat, heroGap: CGFloat, outer: CGFloat) {
    let s = min(screen.width, screen.height)
    return ((s * edgeFloatFrac).rounded(),
            (s * heroGapFrac).rounded(),
            (s * outerFrac).rounded())
}

// MARK: - Board switcher band (t-wrd2 rail slice)

/// One laid-out board tab in the rail's board band, in the rail view's FLIPPED
/// (y-down) drawing space. `boardIndex` is the 0-based board this tab stands for
/// (preserved so a click / wheel maps back, like `BoardTabFrame`).
public struct RailBoardCellFrame: Equatable, Sendable {
    public let boardIndex: Int
    public let rect: CGRect
    public init(boardIndex: Int, rect: CGRect) {
        self.boardIndex = boardIndex
        self.rect = rect
    }
}

/// Carve the board band's sliver `t` off the TOP of `bounds` so the strip + hero
/// lay out in the remainder. The band is a horizontal row pinned to the screen
/// TOP on every edge (a bottom dock keeps its strip at the bottom — the band just
/// reserves height from the top of the hero; left/right keep their side strip).
/// `t == 0` returns `bounds` unchanged (the < 2-board degrade ⇒ byte-identical
/// rail). Pure / testable.
public func railInset(_ bounds: CGRect, by t: CGFloat) -> CGRect {
    let t = max(0, t)
    return CGRect(x: bounds.minX, y: bounds.minY + t,
                  width: bounds.width, height: max(0, bounds.height - t))
}

/// The board band's rect + each board tab's rect — a horizontal tab row pinned to
/// the screen TOP (every edge). `thickness` is the band's height (the same sliver
/// `railInset` reserved off the top). Tabs lay out via `boardTabLayout` (intrinsic
/// when they fit, uniform shrink on overflow). `boardCount < 2` or
/// `thickness <= 0` ⇒ an empty band + no cells (the visibility gate). Pure /
/// testable.
public func railBoardBand(in bounds: CGRect, boardCount: Int,
                          thickness: CGFloat, tabWidths: [CGFloat],
                          gap: CGFloat, innerPad: CGFloat)
    -> (bandRect: CGRect, cells: [RailBoardCellFrame]) {
    guard boardCount >= 2, thickness > 0 else { return (.zero, []) }
    let bandRect = CGRect(x: bounds.minX, y: bounds.minY,
                          width: bounds.width, height: thickness)
    let laid = boardTabLayout(widths: tabWidths,
                              available: bandRect.width - innerPad * 2, gap: gap)
    let cells = laid.map {
        RailBoardCellFrame(boardIndex: $0.boardIndex,
            rect: CGRect(x: bandRect.minX + innerPad + $0.x, y: bandRect.minY,
                         width: $0.width, height: bandRect.height))
    }
    return (bandRect, cells)
}

/// Convert a raw scroll-wheel `deltaY` into an integer step count for a board /
/// section switcher — the shared "precise vs notched" accumulation math the tree
/// `BoardBand`, the rail `RailBoardBand`, and the `RailView` carousel previously
/// each copied verbatim (t-9amp / R1). Pure / total; lives here so it's
/// unit-testable. (Relocated from `BoardGeometry.swift` — it is shared by the
/// surviving `RailView` carousel, so it outlives the board bands.)
///
/// - PRECISE (trackpad / Magic Mouse): `deltaY` points accumulate into `accum`
///   (inout); every whole `threshold` of travel yields one ±1 step and is drained
///   from `accum`, so a sub-threshold remainder carries to the next call.
///   `gestureBegan` (`NSEvent.phase` `.began`) resets `accum` first so a stale
///   leftover can't bias a fresh, unrelated gesture. All drains in one call share
///   a sign (|accum| shrinks monotonically toward 0), so the NET return equals the
///   per-drain sequence — a caller wanting per-step emission just loops
///   `abs(result)` times with `result.signum()`, one wanting a single clamped
///   apply hands the net straight to `boardIndexStep`.
/// - NOTCHED (classic wheel): one detent = exactly ±1, no accumulation.
///
/// Sign: a NEGATIVE `deltaY` (content scrolled DOWN, natural-scroll sign already
/// baked into the value) → +1 ("next"); positive → -1 ("prev"). `deltaY == 0`
/// → 0. A non-positive `threshold` returns 0 (defensive — it would otherwise
/// never drain; the real call sites pass a positive constant).
public func wheelSteps(deltaY: CGFloat, accum: inout CGFloat,
                       threshold: CGFloat, precise: Bool,
                       gestureBegan: Bool) -> Int {
    guard deltaY != 0 else { return 0 }
    guard precise else { return deltaY < 0 ? 1 : -1 }
    guard threshold > 0 else { return 0 }
    if gestureBegan { accum = 0 }
    accum += deltaY
    var step = 0
    while abs(accum) >= threshold {
        let d = accum < 0 ? 1 : -1            // down → next, up → prev
        accum += CGFloat(d) * threshold
        step += d
    }
    return step
}
