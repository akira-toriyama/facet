import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure geometry tests for the rail's edge-neutral band split,
/// active-centred carousel offsets (2-b), and responsive
/// (short-edge-scaled) pads. A clean 1600×1000 bounds keeps the
/// arithmetic exact: thickness 300, outerPad 40, heroGap 16.
final class RailGeometryTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let t: CGFloat = 300, pad: CGFloat = 40, gap: CGFloat = 16

    private func bands(_ edge: RailEdge) -> (strip: CGRect, hero: CGRect) {
        railBands(in: bounds, edge: edge, thickness: t, outerPad: pad, heroGap: gap)
    }

    func testAxisForEdges() {
        XCTAssertEqual(RailEdge.top.axis, .horizontal)
        XCTAssertEqual(RailEdge.bottom.axis, .horizontal)
        XCTAssertEqual(RailEdge.left.axis, .vertical)
        XCTAssertEqual(RailEdge.right.axis, .vertical)
    }

    func testBottomBands() {
        let (s, h) = bands(.bottom)
        XCTAssertEqual(s, CGRect(x: 0, y: 700, width: 1600, height: 300))
        XCTAssertEqual(h, CGRect(x: 40, y: 40, width: 1520, height: 644))
    }

    func testTopBands() {
        let (s, h) = bands(.top)
        XCTAssertEqual(s, CGRect(x: 0, y: 0, width: 1600, height: 300))
        XCTAssertEqual(h, CGRect(x: 40, y: 316, width: 1520, height: 644))
    }

    func testLeftBands() {
        let (s, h) = bands(.left)
        XCTAssertEqual(s, CGRect(x: 0, y: 0, width: 300, height: 1000))
        XCTAssertEqual(h, CGRect(x: 316, y: 40, width: 1244, height: 920))
    }

    func testRightBands() {
        let (s, h) = bands(.right)
        XCTAssertEqual(s, CGRect(x: 1300, y: 0, width: 300, height: 1000))
        XCTAssertEqual(h, CGRect(x: 40, y: 40, width: 1244, height: 920))
    }

    func testStripsAreOppositeMirrors() {
        // Opposite edges put the strip on opposite sides, same size.
        XCTAssertEqual(bands(.bottom).strip.height, bands(.top).strip.height)
        XCTAssertEqual(bands(.left).strip.width, bands(.right).strip.width)
        XCTAssertEqual(bands(.bottom).strip.minY, 700)
        XCTAssertEqual(bands(.top).strip.minY, 0)
    }

    func testThicknessClampedToBounds() {
        // Over-thick request is clamped so the strip never exceeds bounds.
        let (s, _) = railBands(in: bounds, edge: .bottom, thickness: 5000,
                               outerPad: pad, heroGap: gap)
        XCTAssertEqual(s.height, 1000)
        XCTAssertEqual(s.minY, 0)
    }

    // MARK: - Carousel offsets (2-b)

    /// The worked example: 5 WS, ws5 (pos 4) selected → ws3 −2 … ws2 +2,
    /// i.e. displayed `[ws3][ws4][ws5][ws1][ws2]`.
    func testCarouselWorkedExample() {
        let off = railCarouselOffsets(count: 5, selectedPos: 4)
        // off[p] is position p's slot offset from centre.
        XCTAssertEqual(off[2], -2)   // ws3
        XCTAssertEqual(off[3], -1)   // ws4
        XCTAssertEqual(off[4], 0)    // ws5 (selected, centre)
        XCTAssertEqual(off[0], 1)    // ws1 (wraps to the right)
        XCTAssertEqual(off[1], 2)    // ws2
    }

    func testCarouselSelectedAlwaysAtZero() {
        for count in 1...9 {
            for sel in 0..<count {
                let off = railCarouselOffsets(count: count, selectedPos: sel)
                XCTAssertEqual(off[sel], 0, "selected must be centre (count \(count), sel \(sel))")
                // Offsets are a contiguous run around 0 (a permutation of
                // a centred range), so each value is unique.
                XCTAssertEqual(Set(off).count, count, "offsets must be distinct")
            }
        }
    }

    func testCarouselEvenBiasesRight() {
        // count 4, selected pos 0 → 2 cells left of centre, 1 right
        // (floor(4/2)=2 ⇒ selected sits one slot right of dead-centre).
        let off = railCarouselOffsets(count: 4, selectedPos: 0)
        XCTAssertEqual(off[0], 0)
        XCTAssertEqual(off.filter { $0 < 0 }.count, 2)
        XCTAssertEqual(off.filter { $0 > 0 }.count, 1)
    }

    func testCarouselWrapsBothSides() {
        // count 5, selected centre pos 2 → symmetric −2…+2.
        XCTAssertEqual(railCarouselOffsets(count: 5, selectedPos: 2).sorted(),
                       [-2, -1, 0, 1, 2])
    }

    func testCarouselEmpty() {
        XCTAssertEqual(railCarouselOffsets(count: 0, selectedPos: 0), [])
    }

    // MARK: - Responsive sizing (orientation- & display-size-aware)

    func testScaledPadsFromShortEdge() {
        // 1600×1000 → short edge 1000; each pad is its fraction of that.
        let p = railScaledPads(screen: CGSize(width: 1600, height: 1000),
                               edgeFloatFrac: 0.035, heroGapFrac: 0.05,
                               outerFrac: 0.035)
        XCTAssertEqual(p.edgeFloat, 35)
        XCTAssertEqual(p.heroGap, 50)
        XCTAssertEqual(p.outer, 35)
    }

    func testScaledPadsOrientationStable() {
        // Rotating the display (swap w/h) keeps the short edge → same pads.
        let land = railScaledPads(screen: CGSize(width: 1600, height: 1000),
                                  edgeFloatFrac: 0.035, heroGapFrac: 0.05,
                                  outerFrac: 0.035)
        let port = railScaledPads(screen: CGSize(width: 1000, height: 1600),
                                  edgeFloatFrac: 0.035, heroGapFrac: 0.05,
                                  outerFrac: 0.035)
        XCTAssertEqual(land.edgeFloat, port.edgeFloat)
        XCTAssertEqual(land.heroGap, port.heroGap)
        XCTAssertEqual(land.outer, port.outer)
    }
}
