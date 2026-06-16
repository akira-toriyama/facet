import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure tests for `DisplayGeometry`. No NSScreen, no AX, no
/// AppKit — every assertion runs against synthetic `[CGRect]`
/// display layouts. Multi-display logic is covered here even
/// though the developer environment is single-display, so the
/// rescue / snap behaviour is verified before it has to fire
/// in production.
final class DisplayGeometryTests: XCTestCase {

    // MARK: - Display layouts used across tests

    /// Single laptop display, 1920×1080 at origin.
    private let single = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]

    /// Two displays side-by-side: primary on the left, external
    /// 4K-ish on the right starting at x=1920.
    private let dual = [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),       // primary
        CGRect(x: 1920, y: 0, width: 3840, height: 2160),    // external
    ]

    // MARK: - isVisible

    func testIsVisibleTrueWhenRectFitsInsideOnlyDisplay() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertTrue(DisplayGeometry.isVisible(rect, in: single))
    }

    func testIsVisibleTrueWhenRectStraddlesBoundary() {
        // Half on the primary, half on the external — counts as
        // visible (intersects both).
        let rect = CGRect(x: 1800, y: 100, width: 400, height: 300)
        XCTAssertTrue(DisplayGeometry.isVisible(rect, in: dual))
    }

    func testIsVisibleFalseWhenRectIsCompletelyOff() {
        // Rect is way to the right of any display.
        let rect = CGRect(x: 10_000, y: 100,
                          width: 400, height: 300)
        XCTAssertFalse(DisplayGeometry.isVisible(rect, in: dual))
    }

    func testIsVisibleFalseWithEmptyDisplays() {
        // Mid-reconfig moment: OS reports no displays. Anything
        // is "not visible" — caller falls back to a safe default.
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertFalse(DisplayGeometry.isVisible(rect, in: []))
    }

    // MARK: - nearestDisplay

    func testNearestDisplayPicksPrimaryWhenRectIsThere() {
        let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
        let near = DisplayGeometry.nearestDisplay(to: rect, in: dual)
        XCTAssertEqual(near, dual[0])
    }

    func testNearestDisplayPicksExternalWhenRectIsThere() {
        let rect = CGRect(x: 3500, y: 1000, width: 100, height: 100)
        let near = DisplayGeometry.nearestDisplay(to: rect, in: dual)
        XCTAssertEqual(near, dual[1])
    }

    func testNearestDisplayPicksClosestForOrphanRect() {
        // Rect is far to the right of both displays. Closer in
        // *centre distance* to the external (its centre is at
        // ≈3840, x=10000 → dist 6160 vs primary centre 960 →
        // dist 9040).
        let rect = CGRect(x: 10_000, y: 1000,
                          width: 100, height: 100)
        let near = DisplayGeometry.nearestDisplay(to: rect, in: dual)
        XCTAssertEqual(near, dual[1])
    }

    func testNearestDisplaySingleDisplayAlwaysReturnsIt() {
        let rect = CGRect(x: -5000, y: -5000,
                          width: 100, height: 100)
        let near = DisplayGeometry.nearestDisplay(to: rect, in: single)
        XCTAssertEqual(near, single[0])
    }

    func testNearestDisplayNilForEmptyDisplays() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(DisplayGeometry.nearestDisplay(to: rect, in: []))
    }

    // MARK: - orphanedPoints

    func testOrphanedPointsEmptyWhenAllSitOnDisplays() {
        let points = [
            CGPoint(x: 500, y: 500),       // on primary
            CGPoint(x: 3000, y: 1000),     // on external
        ]
        XCTAssertEqual(
            DisplayGeometry.orphanedPoints(among: points,
                                           displays: dual),
            [])
    }

    func testOrphanedPointsReturnsOnlyTheStrandedOnes() {
        let points = [
            CGPoint(x: 500, y: 500),       // on primary (keep)
            CGPoint(x: 5800, y: 2155),     // anchor-corner of
                                            // disconnected display
            CGPoint(x: 3000, y: 1000),     // on external (keep)
        ]
        let displays = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 3840, height: 2160),
        ]
        let orphans = DisplayGeometry.orphanedPoints(
            among: points, displays: displays)
        XCTAssertEqual(orphans, [CGPoint(x: 5800, y: 2155)])
    }

    func testOrphanedPointsTreatsAllAsOrphanWhenNoDisplays() {
        // Mid-reconfig with zero displays: every parked window
        // is orphan, caller can decide how to handle it (likely
        // wait for the next reconfig).
        let points = [CGPoint(x: 0, y: 0),
                      CGPoint(x: 100, y: 100)]
        XCTAssertEqual(
            DisplayGeometry.orphanedPoints(among: points,
                                           displays: []),
            points)
    }

    func testOrphanedPointsHandlesExactCornerAsOutside() {
        // CGRect.contains is half-open on the upper edges:
        // (display.maxX, display.maxY) is OUTSIDE. anchor parking
        // uses (maxX-1, maxY-1) which IS inside — so this asserts
        // the contract the rescue logic depends on.
        let display = CGRect(x: 0, y: 0,
                             width: 1920, height: 1080)
        let cornerOutside = CGPoint(x: 1920, y: 1080)
        let cornerInside = CGPoint(x: 1919, y: 1079)
        XCTAssertEqual(
            DisplayGeometry.orphanedPoints(among: [cornerOutside],
                                           displays: [display]),
            [cornerOutside])
        XCTAssertEqual(
            DisplayGeometry.orphanedPoints(among: [cornerInside],
                                           displays: [display]),
            [])
    }
}
