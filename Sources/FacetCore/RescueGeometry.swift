// Pure geometry behind the window-rescue feature — un-stranding
// windows that facet parked at a display's bottom-right anchor
// sliver `(maxX-1, maxY-1)` and then left there when it quit or
// crashed. Two stateless helpers, both unit-testable without
// NSScreen / AX / AppKit: they take rectangles / points in, answer
// a geometric question, return a bool / point out.
//
// Why this lives in FacetCore, separate from `Displays` (the
// NSScreen wrapper in FacetAccessibility): same split as
// `DisplayGeometry` — `Displays` asks the OS what the screens look
// like (side-effectful, not test-isolated, stays in the AX module);
// `RescueGeometry` is pure CGRect / CGPoint maths over those answers
// (no AppKit, no AX), so it belongs here where the testable half
// stays testable. Sibling of `DisplayGeometry.swift`.
//
// Used by all three rescue mechanisms (memory: facet-window-policy /
// facet-hide-fork-scope):
//   ① graceful restore-on-terminate uses EXACT recorded origins, so
//      it does NOT need these helpers.
//   ② auto-heal on desktop activation detects orphan slivers via
//      `isCornerParked` and moves them to `rescueTarget`.
//   ③ `facet --rescue` one-shot does the same detection + move.

import CoreGraphics

public enum RescueGeometry {

    /// Default px band for corner-park detection. `parkAnchor` REQUESTS
    /// `(maxX-1, maxY-1)`, but macOS CLAMPS the window back on-screen so
    /// ~41px of title bar stays visible — so the ACTUAL top-left lands a
    /// band inside the bottom-right corner (≈ `(maxX-1, maxY-41)` for a
    /// normal-height window; verified live: a parked window on a
    /// 5120×2160 display reported origin `(5119, 2119)`). The band covers
    /// that clamp; detecting against the *requested* point misses every
    /// real park.
    public static let cornerBand: CGFloat = 60

    /// True when `origin` (a window's top-left) sits within `band` px of
    /// the display's bottom-right corner `(maxX, maxY)` — i.e. the window
    /// is a parked sliver (almost entirely off-screen past the corner,
    /// only the clamped title-bar corner showing). Detection is by
    /// POSITION only: `parkAnchor` never resizes, so the window keeps its
    /// real size and only its near-corner origin betrays the park. No
    /// real window keeps its top-left this close to the bottom-right
    /// corner, so the band is safe against false positives.
    public static func isCornerParked(origin: CGPoint,
                                      displayBounds: CGRect,
                                      band: CGFloat = cornerBand)
        -> Bool
    {
        let dx = displayBounds.maxX - origin.x   // left edge → right edge
        let dy = displayBounds.maxY - origin.y   // top edge → bottom edge
        return dx >= 0 && dx <= band
            && dy >= 0 && dy <= band
    }

    /// Approximate on-screen rescue origin: the display's visible
    /// frame top-left nudged in by `inset` so the title bar is
    /// grabbable and clear of the menu bar. Approximate is fine — the
    /// goal is just to get the window back on-screen ("画面内であれば
    /// OK"); the exact pre-park position is only restored on graceful
    /// quit (mechanism ①), which has it in memory.
    public static func rescueTarget(visibleFrame: CGRect,
                                    inset: CGFloat = 24) -> CGPoint {
        CGPoint(x: visibleFrame.minX + inset,
                y: visibleFrame.minY + inset)
    }
}
