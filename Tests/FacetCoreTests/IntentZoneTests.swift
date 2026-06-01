import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure tests for the real-window-DnD intent-zone classifier (枠C):
/// a central rectangle = swap, four triangular wedges = insert. The
/// rect is 400×200 (wider than tall) so the wedge diagonals aren't at
/// 45° — exercising the aspect-correcting normalization.
final class IntentZoneTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 400, height: 200)

    func testCenterIsSwap() {
        XCTAssertEqual(intentZone(at: CGPoint(x: 200, y: 100), in: rect),
                       .center)
    }

    func testRightEdgeIsRightInsert() {
        XCTAssertEqual(intentZone(at: CGPoint(x: 395, y: 100), in: rect),
                       .edge(.right))
    }

    func testLeftEdgeIsLeftInsert() {
        XCTAssertEqual(intentZone(at: CGPoint(x: 5, y: 100), in: rect),
                       .edge(.left))
    }

    func testTopEdgeIsTopInsert() {
        XCTAssertEqual(intentZone(at: CGPoint(x: 200, y: 5), in: rect),
                       .edge(.top))
    }

    func testBottomEdgeIsBottomInsert() {
        XCTAssertEqual(intentZone(at: CGPoint(x: 200, y: 195), in: rect),
                       .edge(.bottom))
    }

    func testSmallerCenterFractionShrinksSwapZone() {
        // s = √0.04 = 0.2, so |px| must be ≤ 0.2 to swap. px at x=260
        // is (260-200)/200 = 0.3 > 0.2 → falls into the right wedge.
        XCTAssertEqual(
            intentZone(at: CGPoint(x: 260, y: 100), in: rect,
                       centerFraction: 0.04),
            .edge(.right))
    }

    func testSamePointSwapsWithDefaultFraction() {
        // The same x=260 point IS within the default 0.4 center
        // (s = √0.4 ≈ 0.632, px = 0.3 ≤ 0.632).
        XCTAssertEqual(intentZone(at: CGPoint(x: 260, y: 100), in: rect),
                       .center)
    }

    func testDegenerateRectIsCenter() {
        XCTAssertEqual(
            intentZone(at: .zero,
                       in: CGRect(x: 0, y: 0, width: 0, height: 0)),
            .center)
    }
}
