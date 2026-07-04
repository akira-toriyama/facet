import CoreGraphics
import Testing
@testable import FacetCore

/// Pure tests for the real-window-DnD intent-zone classifier (枠C):
/// a central rectangle = swap, four triangular wedges = insert. The
/// rect is 400×200 (wider than tall) so the wedge diagonals aren't at
/// 45° — exercising the aspect-correcting normalization.
struct IntentZoneTests {

    private let rect = CGRect(x: 0, y: 0, width: 400, height: 200)

    // Classify a point in the fixed 400×200 rect. A nil `centerFraction`
    // exercises the default (0.4); a non-nil value passes it explicitly.
    @Test("point in fixed rect maps to swap/insert zone", arguments: [
        (point: CGPoint(x: 200, y: 100), centerFraction: CGFloat?.none, expected: IntentZone.center),
        (point: CGPoint(x: 395, y: 100), centerFraction: CGFloat?.none, expected: IntentZone.edge(.right)),
        (point: CGPoint(x: 5, y: 100), centerFraction: CGFloat?.none, expected: IntentZone.edge(.left)),
        (point: CGPoint(x: 200, y: 5), centerFraction: CGFloat?.none, expected: IntentZone.edge(.top)),
        (point: CGPoint(x: 200, y: 195), centerFraction: CGFloat?.none, expected: IntentZone.edge(.bottom)),
        // s = √0.04 = 0.2, so |px| must be ≤ 0.2 to swap. px at x=260
        // is (260-200)/200 = 0.3 > 0.2 → falls into the right wedge.
        (point: CGPoint(x: 260, y: 100), centerFraction: CGFloat?(0.04), expected: IntentZone.edge(.right)),
        // The same x=260 point IS within the default 0.4 center
        // (s = √0.4 ≈ 0.632, px = 0.3 ≤ 0.632).
        (point: CGPoint(x: 260, y: 100), centerFraction: CGFloat?.none, expected: IntentZone.center),
    ])
    func zone(point: CGPoint, centerFraction: CGFloat?, expected: IntentZone) {
        if let centerFraction {
            #expect(intentZone(at: point, in: rect, centerFraction: centerFraction) == expected)
        } else {
            #expect(intentZone(at: point, in: rect) == expected)
        }
    }

    @Test func degenerateRectIsCenter() {
        #expect(
            intentZone(at: .zero,
                       in: CGRect(x: 0, y: 0, width: 0, height: 0))
            == .center)
    }
}
