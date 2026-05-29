import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure tests for `CGRect.roundedToPhysicalPixels(scale:)`.
final class PixelRoundingTests: XCTestCase {

    func testScaleZeroIsNoOp() {
        let r = CGRect(x: 0.3, y: 0.7, width: 10.1, height: 5.2)
        XCTAssertEqual(r.roundedToPhysicalPixels(scale: 0), r)
    }

    func testNegativeScaleIsNoOp() {
        let r = CGRect(x: 0.3, y: 0.7, width: 10.1, height: 5.2)
        XCTAssertEqual(r.roundedToPhysicalPixels(scale: -2), r)
    }

    func testScale1RoundsToWholePoint() {
        // Non-Retina: edges snap to integer points.
        let r = CGRect(x: 0.3, y: 0.7, width: 10.4, height: 5.6)
            .roundedToPhysicalPixels(scale: 1)
        // x0 0.3→0, y0 0.7→1, x1 10.7→11, y1 6.3→6.
        XCTAssertEqual(r.minX, 0, accuracy: 0.001)
        XCTAssertEqual(r.minY, 1, accuracy: 0.001)
        XCTAssertEqual(r.width, 11, accuracy: 0.001)   // 11 - 0
        XCTAssertEqual(r.height, 5, accuracy: 0.001)   // 6 - 1
    }

    func testScale2RoundsToHalfPoint() {
        // Retina: edges snap to 0.5-point (= whole physical pixel).
        let r = CGRect(x: 0.3, y: 0, width: 100.4, height: 50)
            .roundedToPhysicalPixels(scale: 2)
        // x0 (0.6).rounded()/2 = 0.5; x1 (201.4).rounded()/2 = 100.5.
        XCTAssertEqual(r.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(r.maxX, 100.5, accuracy: 0.001)
        XCTAssertEqual(r.width, 100.0, accuracy: 0.001)   // 100.5 - 0.5
    }

    func testAdjacentEdgesMeetExactly() {
        // Two frames sharing an edge at x = 100.4 round to the same
        // value, so they still meet — no seam, no overlap.
        let scale: CGFloat = 2
        let a = CGRect(x: 0, y: 0, width: 100.4, height: 50)
            .roundedToPhysicalPixels(scale: scale)
        let b = CGRect(x: 100.4, y: 0, width: 60, height: 50)
            .roundedToPhysicalPixels(scale: scale)
        XCTAssertEqual(a.maxX, b.minX, accuracy: 0.001)
    }
}
