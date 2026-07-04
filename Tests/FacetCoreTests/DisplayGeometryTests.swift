import CoreGraphics
import Testing
@testable import FacetCore

// MARK: - Display layouts used across tests

/// Single laptop display, 1920×1080 at origin.
private let single = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]

/// Two displays side-by-side: primary on the left, external
/// 4K-ish on the right starting at x=1920.
private let dual = [
    CGRect(x: 0, y: 0, width: 1920, height: 1080),       // primary
    CGRect(x: 1920, y: 0, width: 3840, height: 2160),    // external
]

/// Pure tests for `DisplayGeometry`. No NSScreen, no AX, no
/// AppKit — every assertion runs against synthetic `[CGRect]`
/// display layouts. Multi-display logic is covered here even
/// though the developer environment is single-display, so the
/// rescue / snap behaviour is verified before it has to fire
/// in production.
struct DisplayGeometryTests {

    // MARK: - isVisible

    @Test("isVisible: rect intersects any display in the layout", arguments: [
        (rect: CGRect(x: 100, y: 100, width: 400, height: 300),
         displays: single, expected: true),
        // Half on the primary, half on the external — counts as
        // visible (intersects both).
        (rect: CGRect(x: 1800, y: 100, width: 400, height: 300),
         displays: dual, expected: true),
        // Rect is way to the right of any display.
        (rect: CGRect(x: 10_000, y: 100, width: 400, height: 300),
         displays: dual, expected: false),
        // Mid-reconfig moment: OS reports no displays. Anything is
        // "not visible" — caller falls back to a safe default.
        (rect: CGRect(x: 0, y: 0, width: 100, height: 100),
         displays: [], expected: false),
    ])
    func isVisible(rect: CGRect, displays: [CGRect], expected: Bool) {
        #expect(DisplayGeometry.isVisible(rect, in: displays) == expected)
    }

    // MARK: - nearestDisplay

    @Test("nearestDisplay: closest by centre distance, nil when empty",
          arguments: [
        (rect: CGRect(x: 100, y: 100, width: 100, height: 100),
         displays: dual, expected: dual[0]),
        (rect: CGRect(x: 3500, y: 1000, width: 100, height: 100),
         displays: dual, expected: dual[1]),
        // Rect is far to the right of both displays. Closer in
        // *centre distance* to the external (its centre is at
        // ≈3840, x=10000 → dist 6160 vs primary centre 960 →
        // dist 9040).
        (rect: CGRect(x: 10_000, y: 1000, width: 100, height: 100),
         displays: dual, expected: dual[1]),
        // Single display always wins, even for a wildly off-screen rect.
        (rect: CGRect(x: -5000, y: -5000, width: 100, height: 100),
         displays: single, expected: single[0]),
        (rect: CGRect(x: 0, y: 0, width: 100, height: 100),
         displays: [], expected: nil),
    ] as [(rect: CGRect, displays: [CGRect], expected: CGRect?)])
    func nearestDisplay(rect: CGRect, displays: [CGRect], expected: CGRect?) {
        #expect(DisplayGeometry.nearestDisplay(to: rect, in: displays) == expected)
    }

    // MARK: - orphanedPoints

    @Test("orphanedPoints: points not contained by any display", arguments: [
        // All sit on a display → none orphaned.
        (points: [CGPoint(x: 500, y: 500),       // on primary
                  CGPoint(x: 3000, y: 1000)],     // on external
         displays: dual, expected: []),
        // Only the anchor-corner of a disconnected display is stranded.
        (points: [CGPoint(x: 500, y: 500),        // on primary (keep)
                  CGPoint(x: 5800, y: 2155),      // anchor-corner of
                                                   // disconnected display
                  CGPoint(x: 3000, y: 1000)],     // on external (keep)
         displays: dual, expected: [CGPoint(x: 5800, y: 2155)]),
        // Mid-reconfig with zero displays: every parked window is
        // orphan, caller can decide how to handle it.
        (points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)],
         displays: [], expected: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)]),
        // CGRect.contains is half-open on the upper edges:
        // (display.maxX, display.maxY) is OUTSIDE. anchor parking
        // uses (maxX-1, maxY-1) which IS inside — so this asserts
        // the contract the rescue logic depends on.
        (points: [CGPoint(x: 1920, y: 1080)],     // exact corner → outside
         displays: single, expected: [CGPoint(x: 1920, y: 1080)]),
        (points: [CGPoint(x: 1919, y: 1079)],     // one-in corner → inside
         displays: single, expected: []),
    ])
    func orphanedPoints(points: [CGPoint], displays: [CGRect], expected: [CGPoint]) {
        #expect(
            DisplayGeometry.orphanedPoints(among: points, displays: displays)
            == expected)
    }
}
