// Shared window-thumb painter for the overview surfaces (grid + rail).
// Draws one rounded mini-rect: fill → clipped capture image (or, when
// `iconFallback`, the app icon) → 0.5pt stroke → mark badge.
//
// Was a near-identical pair — grid's `drawWindowThumb(_:at:fill:stroke:)`
// (explicit FLIP rect + app-icon fallback) and rail's
// `drawThumb(_:fill:stroke:)` (capture-only, `w.rect`). Unified via the
// `at:` rect (rail passes `w.rect`) and the `iconFallback:` flag (grid
// `true`, rail `false`).

import AppKit
import FacetCore

@MainActor
public func drawMiniThumb(_ w: MiniWindowHit, at r: CGRect,
                          fill: NSColor, stroke: NSColor,
                          thumbnails: [WindowID: NSImage],
                          iconFallback: Bool,
                          pal: ResolvedPalette) {
    let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
    fill.setFill(); path.fill()
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    if let img = thumbnails[w.id] {
        // The overview views are flipped (Y-down); the respect-flipped
        // overload paints right-side-up.
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: true, hints: nil)
    } else if iconFallback {
        // No ScreenCaptureKit thumbnail cached yet — fall back to the app
        // icon (grid only; the rail shows just the subtle fill until its
        // image lands).
        let iconSide = max(12, min(min(r.width, r.height) - 8, 48))
        if iconSide >= 12, let icon = AppIcons.icon(forPID: w.pid) {
            let iconRect = NSRect(x: r.midX - iconSide / 2,
                                  y: r.midY - iconSide / 2,
                                  width: iconSide, height: iconSide)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver,
                      fraction: 0.95, respectFlipped: true, hints: nil)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    // Stroke on top so the border isn't covered by the image.
    stroke.setStroke(); path.lineWidth = 0.5; path.stroke()
    // Mark badge — same corner pill / dot in both overviews.
    if let mark = w.mark { drawMiniMarkBadge(mark, in: r, pal: pal) }
}
