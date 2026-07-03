import CoreGraphics
import Testing
@testable import FacetCore

/// Pure tests for `CGRect.roundedToPhysicalPixels(scale:)`.
struct PixelRoundingTests {

    @Test func scaleZeroIsNoOp() {
        let r = CGRect(x: 0.3, y: 0.7, width: 10.1, height: 5.2)
        #expect(r.roundedToPhysicalPixels(scale: 0) == r)
    }

    @Test func negativeScaleIsNoOp() {
        let r = CGRect(x: 0.3, y: 0.7, width: 10.1, height: 5.2)
        #expect(r.roundedToPhysicalPixels(scale: -2) == r)
    }

    @Test func scale1RoundsToWholePoint() {
        // Non-Retina: edges snap to integer points.
        let r = CGRect(x: 0.3, y: 0.7, width: 10.4, height: 5.6)
            .roundedToPhysicalPixels(scale: 1)
        // x0 0.3→0, y0 0.7→1, x1 10.7→11, y1 6.3→6.
        #expect(abs(r.minX - 0) < 0.001)
        #expect(abs(r.minY - 1) < 0.001)
        #expect(abs(r.width - 11) < 0.001)   // 11 - 0
        #expect(abs(r.height - 5) < 0.001)   // 6 - 1
    }

    @Test func scale2RoundsToHalfPoint() {
        // Retina: edges snap to 0.5-point (= whole physical pixel).
        let r = CGRect(x: 0.3, y: 0, width: 100.4, height: 50)
            .roundedToPhysicalPixels(scale: 2)
        // x0 (0.6).rounded()/2 = 0.5; x1 (201.4).rounded()/2 = 100.5.
        #expect(abs(r.minX - 0.5) < 0.001)
        #expect(abs(r.maxX - 100.5) < 0.001)
        #expect(abs(r.width - 100.0) < 0.001)   // 100.5 - 0.5
    }

    @Test func adjacentEdgesMeetExactly() {
        // Two frames sharing an edge at x = 100.4 round to the same
        // value, so they still meet — no seam, no overlap.
        let scale: CGFloat = 2
        let a = CGRect(x: 0, y: 0, width: 100.4, height: 50)
            .roundedToPhysicalPixels(scale: scale)
        let b = CGRect(x: 100.4, y: 0, width: 60, height: 50)
            .roundedToPhysicalPixels(scale: scale)
        #expect(abs(a.maxX - b.minX) < 0.001)
    }
}
