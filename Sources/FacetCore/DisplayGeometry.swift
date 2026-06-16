// Pure geometry helpers used by Phase δ display-reconfigure
// handling. Three functions, all stateless, all unit-testable
// without NSScreen / AX / AppKit — they take rectangles in,
// answer geometric questions, return rectangles or points out.
//
// Why this lives in FacetCore, separate from `Displays`:
//
//   `Displays` (the NSScreen wrapper in FacetAccessibility) goes
//   to AppKit / CoreGraphics to ask "what does the OS think the
//   displays look like right now?" — inherently side-effectful and
//   not test-isolated, so it stays in the AX / OS module.
//   `DisplayGeometry` is pure CGRect maths over the `[CGRect]`
//   answer `Displays` returns — no AppKit, no AX — so it belongs in
//   FacetCore (CoreGraphics is allowed there). The split keeps the
//   testable half testable.
//
// Phase δ frozen decisions (memory: facet-phase-delta-decisions):
//
//   - `isVisible(_ rect:, in:)` — when the persisted panel rect
//     no longer intersects any current display, we snap it to a
//     fallback. This helper says "should we snap?".
//   - `nearestDisplay(to:, in:)` — the snap destination: which
//     display centre is closest to the persisted rect's centre?
//   - `orphanedPoints(among:, displays:)` — anchor-parked window
//     positions whose origin no longer lies on any visible
//     display. Used by NativeAdapter's rescue sweep on
//     reconfigure.
//
// Empty `displays` arrays are tolerated everywhere (return
// "everything is orphaned" / nil destinations) — no display
// will be passed when the OS is mid-reconfigure, so robustness
// here keeps the handler safe.

import CoreGraphics

public enum DisplayGeometry {

    /// True when `rect` overlaps *any* of the given displays by
    /// at least one pixel. Empty `displays` → always false (no
    /// display is visible, nothing is visible).
    public static func isVisible(_ rect: CGRect,
                                 in displays: [CGRect]) -> Bool {
        displays.contains { $0.intersects(rect) }
    }

    /// The display whose centre is closest to `rect`'s centre.
    /// Used for snap-back when a persisted rect goes off-screen
    /// (Phase δ Q4: nearest preserves user intent — they put
    /// the rect somewhere physical, snap to the physically
    /// closest display).
    ///
    /// Returns nil when `displays` is empty (caller decides the
    /// degenerate fallback — typically a no-op).
    public static func nearestDisplay(to rect: CGRect,
                                      in displays: [CGRect])
        -> CGRect?
    {
        guard !displays.isEmpty else { return nil }
        let probe = CGPoint(x: rect.midX, y: rect.midY)
        return displays.min { lhs, rhs in
            let lc = CGPoint(x: lhs.midX, y: lhs.midY)
            let rc = CGPoint(x: rhs.midX, y: rhs.midY)
            return hypot(lc.x - probe.x, lc.y - probe.y)
                < hypot(rc.x - probe.x, rc.y - probe.y)
        }
    }

    /// Points (anchor-park origins) that don't sit on any of the
    /// current displays. Used by NativeAdapter's reconfigure
    /// sweep to find anchor-parked windows whose host display
    /// went away.
    ///
    /// Containment is half-open at the lower edges (`CGRect.contains`
    /// semantics), so a point exactly at `display.maxX` /
    /// `display.maxY` (the very corner) counts as outside — which
    /// is fine because anchor parking uses `(maxX-1, maxY-1)`, a
    /// pixel inside the bounds.
    public static func orphanedPoints(among points: [CGPoint],
                                      displays: [CGRect])
        -> [CGPoint]
    {
        guard !displays.isEmpty else { return points }
        return points.filter { p in
            !displays.contains { $0.contains(p) }
        }
    }
}
