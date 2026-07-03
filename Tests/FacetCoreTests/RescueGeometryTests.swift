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
    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// External 4K-ish display to the right of the primary →
    /// anchor (5759, 2159).
    private let external = CGRect(x: 1920, y: 0, width: 3840, height: 2160)

    // MARK: - isCornerParked
    //
    // CRITICAL: parkAnchor REQUESTS (maxX-1, maxY-1), but macOS CLAMPS
    // the window back on-screen so ~41px of title bar stays visible — so
    // the ACTUAL top-left lands at roughly (maxX-1, maxY-41) for a normal
    // window, NOT (maxX-1, maxY-1). Detection must match the clamped
    // position, not the requested one. (Found live: a parked window on a
    // 5120×2160 display reported origin (5119, 2119) = (maxX-1, maxY-41).)

    @Test func isCornerParkedTrueAtTitleBarClampedOrigin() {
        // The realistic case: macOS clamps Y up by ~41px (title bar).
        let origin = CGPoint(x: 1919, y: 1039)   // (maxX-1, maxY-41)
        #expect(
            RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: primary))
    }

    @Test func isCornerParkedTrueAtExactRequestedAnchor() {
        // A short window needs no clamp → lands at the requested
        // (maxX-1, maxY-1). Still detected.
        let origin = CGPoint(x: 1919, y: 1079)
        #expect(
            RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: primary))
    }

    @Test func isCornerParkedDetectsLiveReproOn5120x2160() {
        // Exact frame reported live for a stranded Chrome window that
        // `--rescue` failed to detect before this fix.
        let display = CGRect(x: 0, y: 0, width: 5120, height: 2160)
        let origin = CGPoint(x: 5119, y: 2119)   // (maxX-1, maxY-41)
        #expect(
            RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: display))
    }

    @Test func isCornerParkedFalseForNormalWindow() {
        // A normally-placed window is nowhere near the corner.
        let origin = CGPoint(x: 100, y: 100)
        #expect(
            !RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: primary))
    }

    @Test func isCornerParkedFalseForWindowNearBottomButLeft() {
        // Low on the screen but far from the right edge → not parked.
        let origin = CGPoint(x: 200, y: 1039)
        #expect(
            !RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: primary))
    }

    @Test func isCornerParkedFalseWhenTopLeftWellInsideCorner() {
        // Top-left 200px in from the bottom-right corner: a real,
        // mostly-on-screen window, not a parked sliver.
        let origin = CGPoint(x: 1720, y: 880)
        #expect(
            !RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: primary))
    }

    @Test func isCornerParkedDetectsExternalDisplayCorner() {
        // A window parked at the EXTERNAL display's corner is detected
        // against the external bounds (the caller resolves which display
        // via Displays.containing). Clamped origin = (maxX-1, maxY-41).
        let origin = CGPoint(x: 5759, y: 2119)
        #expect(
            RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: external))
        // …and that same origin is NOT a corner of the primary display.
        #expect(
            !RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: primary))
    }

    @Test func isCornerParkedFalseJustOutsideClampBand() {
        // 70px above the bottom edge exceeds the clamp band → a window
        // that low+right but not a corner sliver isn't rescued.
        let origin = CGPoint(x: 1919, y: 1080 - 70)
        #expect(
            !RescueGeometry.isCornerParked(origin: origin,
                                          displayBounds: primary))
    }

    // MARK: - rescueTarget

    @Test func rescueTargetOffsetsVisibleFrameOrigin() {
        // visibleFrame top-left (Quartz coords) is below the 25px menu bar;
        // the target nudges in by the default 24px inset so the title bar
        // is grabbable and clear of the menu bar.
        let visible = CGRect(x: 0, y: 25, width: 1920, height: 1030)
        #expect(
            RescueGeometry.rescueTarget(visibleFrame: visible) ==
            CGPoint(x: 24, y: 49))
    }

    @Test func rescueTargetRespectsCustomInset() {
        let visible = CGRect(x: 0, y: 25, width: 1920, height: 1030)
        #expect(
            RescueGeometry.rescueTarget(visibleFrame: visible, inset: 40) ==
            CGPoint(x: 40, y: 65))
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
