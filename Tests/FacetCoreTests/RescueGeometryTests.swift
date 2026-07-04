import CoreGraphics
import Testing
@testable import FacetCore

/// Pure tests for `RescueGeometry` — the geometry behind the window-rescue
/// feature (un-stranding windows parked at a display's bottom-right anchor
/// sliver after facet quits / crashes). No NSScreen, no AX, no AppKit:
/// every assertion runs against synthetic `CGRect` / `CGPoint` values.
/// Multi-display detection is covered here even though the dev box is
/// single-display, so the rescue fires correctly before it has to in
/// production.
struct RescueGeometryTests {

    /// Single laptop display, 1920×1080 at origin → anchor (1919, 1079).
    private static let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// External 4K-ish display to the right of the primary →
    /// anchor (5759, 2159).
    private static let external = CGRect(x: 1920, y: 0, width: 3840, height: 2160)

    // MARK: - isCornerParked
    //
    // CRITICAL: parkAnchor REQUESTS (maxX-1, maxY-1), but macOS CLAMPS
    // the window back on-screen so ~41px of title bar stays visible — so
    // the ACTUAL top-left lands at roughly (maxX-1, maxY-41) for a normal
    // window, NOT (maxX-1, maxY-1). Detection must match the clamped
    // position, not the requested one. (Found live: a parked window on a
    // 5120×2160 display reported origin (5119, 2119) = (maxX-1, maxY-41).)

    @Test("isCornerParked: parked slivers detected, off-corner windows rejected", arguments: [
        // The realistic case: macOS clamps Y up by ~41px (title bar) →
        // (maxX-1, maxY-41).
        (origin: CGPoint(x: 1919, y: 1039), displayBounds: primary, expected: true),
        // A short window needs no clamp → lands at the requested
        // (maxX-1, maxY-1). Still detected.
        (origin: CGPoint(x: 1919, y: 1079), displayBounds: primary, expected: true),
        // Exact frame reported live for a stranded Chrome window that
        // `--rescue` failed to detect before this fix — (maxX-1, maxY-41).
        (origin: CGPoint(x: 5119, y: 2119),
         displayBounds: CGRect(x: 0, y: 0, width: 5120, height: 2160), expected: true),
        // A normally-placed window is nowhere near the corner.
        (origin: CGPoint(x: 100, y: 100), displayBounds: primary, expected: false),
        // Low on the screen but far from the right edge → not parked.
        (origin: CGPoint(x: 200, y: 1039), displayBounds: primary, expected: false),
        // Top-left 200px in from the bottom-right corner: a real,
        // mostly-on-screen window, not a parked sliver.
        (origin: CGPoint(x: 1720, y: 880), displayBounds: primary, expected: false),
        // A window parked at the EXTERNAL display's corner is detected
        // against the external bounds. Clamped origin = (maxX-1, maxY-41).
        (origin: CGPoint(x: 5759, y: 2119), displayBounds: external, expected: true),
        // …and that same origin is NOT a corner of the primary display.
        (origin: CGPoint(x: 5759, y: 2119), displayBounds: primary, expected: false),
        // 70px above the bottom edge exceeds the clamp band → a window
        // that low+right but not a corner sliver isn't rescued.
        (origin: CGPoint(x: 1919, y: 1080 - 70), displayBounds: primary, expected: false),
    ])
    func isCornerParked(origin: CGPoint, displayBounds: CGRect, expected: Bool) {
        #expect(
            RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: displayBounds) == expected)
    }

    // MARK: - rescueTarget

    // visibleFrame top-left (Quartz coords) is below the 25px menu bar; the
    // target nudges in by the inset (default 24px, or a custom value) so the
    // title bar is grabbable and clear of the menu bar.
    @Test("rescueTarget offsets visibleFrame origin by inset (default 24, or custom)", arguments: [
        (visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1030),
         inset: nil, expected: CGPoint(x: 24, y: 49)),
        (visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1030),
         inset: 40, expected: CGPoint(x: 40, y: 65)),
    ] as [(visibleFrame: CGRect, inset: CGFloat?, expected: CGPoint)])
    func rescueTarget(visibleFrame: CGRect, inset: CGFloat?, expected: CGPoint) {
        let target: CGPoint
        if let inset {
            target = RescueGeometry.rescueTarget(visibleFrame: visibleFrame, inset: inset)
        } else {
            target = RescueGeometry.rescueTarget(visibleFrame: visibleFrame)
        }
        #expect(target == expected)
    }

    @Test func rescueTargetLandsInsideVisibleFrame() {
        // On an external display offset in x, the target must stay inside
        // that display's visible frame (not snap back to the origin).
        let visible = CGRect(x: 1920, y: 0, width: 3840, height: 2160)
        let target = RescueGeometry.rescueTarget(visibleFrame: visible)
        #expect(visible.contains(target))
        #expect(target == CGPoint(x: 1944, y: 24))
    }
}
