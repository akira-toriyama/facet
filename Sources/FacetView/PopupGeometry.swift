// On-screen placement maths for the themed "card" popups (PopupMenu).
// They open at a click anchor and must flip / clamp into the visible
// frame with the same 4pt margin; extracted here so callers can't drift
// on that margin or the flip-up rule.

import AppKit

/// Top-left origin for a popup of `size` anchored at `anchor` (the click
/// point = the panel's intended TOP). Flips UP to `anchor` when the
/// default down-placement would fall below the screen, and clamps to the
/// visible frame with a 4pt margin. `anchor` doubles as the flip-up target.
@MainActor
func placePopupOrigin(anchor: NSPoint, size: NSSize) -> NSPoint {
    var origin = NSPoint(x: anchor.x, y: anchor.y - size.height)
    if let vis = NSScreen.main?.visibleFrame {
        origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - size.width - 4)
        if origin.y < vis.minY + 4 { origin.y = anchor.y }   // flip up
        origin.y = min(origin.y, vis.maxY - size.height - 4)
    }
    return origin
}

/// Y origin for a popup being RESIZED while its TOP edge stays pinned at
/// `top`: `top - height`, clamped on-screen with a 4pt margin. No flip-up
/// (a resize never relocates the anchor) — keep this separate from
/// `placePopupOrigin` so the resize path can't grow a flip branch.
@MainActor
func clampTopPinnedY(top: CGFloat, height: CGFloat) -> CGFloat {
    var y = top - height
    if let vis = NSScreen.main?.visibleFrame {
        y = max(y, vis.minY + 4)
        y = min(y, vis.maxY - height - 4)
    }
    return y
}
