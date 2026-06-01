// Intent-zone geometry for real-window mouse DnD (枠C).
//
// When a tiled window is dragged over another, the cursor's position
// within the target window decides the drop intent: the central
// rectangle means "swap the two windows", and the four triangular
// wedges around it (split by the window's corner-to-corner diagonals)
// each mean "insert beside this window on that edge". yabai uses the
// same shape; the wedges kill the corner ambiguity a 4-rect split has.
//
// Pure CoreGraphics — no AppKit, no backend. The classifier is a
// function of (point, rect) only, so the same call drives both the
// live prediction overlay (PR-2) and the committed drop.

import CoreGraphics

/// Fraction of a tiled window's AREA taken by the central "swap" zone.
/// Outside it, four triangular wedges select an insert edge. ~0.4 per
/// the 枠C grill; tune on-device (a prediction overlay shows the
/// outcome, so precision here isn't critical).
public let intentZoneCenterFraction: CGFloat = 0.4

/// The drop intent for a drag hovering over a tiled window.
/// `.center` swaps with that window; `.edge(_)` inserts against that
/// side (the layout engine interprets the edge).
public enum IntentZone: Sendable, Equatable {
    case center
    case edge(InsertEdge)
}

/// Classify `point` within `rect` into an ``IntentZone``: a central
/// rectangle (swap) plus four triangular wedges (insert) divided by the
/// rect's corner-to-corner diagonals.
///
/// - The center rectangle is concentric and similar to `rect`, scaled
///   so its area is `centerFraction` of `rect` (each side = √fraction).
/// - Outside it, the dominant normalized axis picks the edge: `.left` /
///   `.right` (the minX / maxX side) when the horizontal offset
///   dominates, `.top` / `.bottom` (the minY / maxY side) otherwise.
///
/// Pure: works in whatever coordinate space the caller supplies — the
/// edges are named in `rect` terms (`.top` = minY side). A degenerate
/// `rect` returns `.center`.
public func intentZone(at point: CGPoint, in rect: CGRect,
                       centerFraction: CGFloat = intentZoneCenterFraction)
    -> IntentZone
{
    guard rect.width > 0, rect.height > 0 else { return .center }
    // Normalize to [-1, 1] on each axis (0 = center, ±1 = an edge).
    // Dividing by each half-extent maps the rect to a unit square, so
    // |px| vs |py| is the corner-diagonal test regardless of aspect.
    let px = (point.x - rect.midX) / (rect.width / 2)
    let py = (point.y - rect.midY) / (rect.height / 2)
    let s = max(0, min(1, centerFraction)).squareRoot()
    if abs(px) <= s && abs(py) <= s { return .center }
    if abs(px) >= abs(py) {
        return .edge(px >= 0 ? .right : .left)
    }
    return .edge(py >= 0 ? .bottom : .top)
}
