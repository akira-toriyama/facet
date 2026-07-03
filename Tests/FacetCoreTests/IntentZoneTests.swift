import CoreGraphics
import Testing
@testable import FacetCore

/// Pure tests for the real-window-DnD intent-zone classifier (枠C):
/// a central rectangle = swap, four triangular wedges = insert. The
/// rect is 400×200 (wider than tall) so the wedge diagonals aren't at
/// 45° — exercising the aspect-correcting normalization.
struct IntentZoneTests {

    private let rect = CGRect(x: 0, y: 0, width: 400, height: 200)

    @Test func centerIsSwap() {
        #expect(intentZone(at: CGPoint(x: 200, y: 100), in: rect) == .center)
    }

    @Test func rightEdgeIsRightInsert() {
        #expect(intentZone(at: CGPoint(x: 395, y: 100), in: rect) == .edge(.right))
    }

    @Test func leftEdgeIsLeftInsert() {
        #expect(intentZone(at: CGPoint(x: 5, y: 100), in: rect) == .edge(.left))
    }

    @Test func topEdgeIsTopInsert() {
        #expect(intentZone(at: CGPoint(x: 200, y: 5), in: rect) == .edge(.top))
    }

    @Test func bottomEdgeIsBottomInsert() {
        #expect(intentZone(at: CGPoint(x: 200, y: 195), in: rect) == .edge(.bottom))
    }

    @Test func smallerCenterFractionShrinksSwapZone() {
        // s = √0.04 = 0.2, so |px| must be ≤ 0.2 to swap. px at x=260
        // is (260-200)/200 = 0.3 > 0.2 → falls into the right wedge.
        #expect(
            intentZone(at: CGPoint(x: 260, y: 100), in: rect,
                       centerFraction: 0.04)
            == .edge(.right))
    }

    @Test func samePointSwapsWithDefaultFraction() {
        // The same x=260 point IS within the default 0.4 center
        // (s = √0.4 ≈ 0.632, px = 0.3 ≤ 0.632).
        #expect(intentZone(at: CGPoint(x: 260, y: 100), in: rect) == .center)
    }

    @Test func degenerateRectIsCenter() {
        #expect(
            intentZone(at: .zero,
                       in: CGRect(x: 0, y: 0, width: 0, height: 0))
            == .center)
    }
}
