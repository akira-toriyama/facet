import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure geometry tests for the rail's edge-neutral band split and
/// scroll maths (M9-3 / M9-4). A clean 1600×1000 bounds keeps the
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

    // MARK: - Scroll

    func testScrollKeepsSelectedVisible() {
        // 10 cells of slot 100 in a 700-long viewport → maxOffset 300.
        XCTAssertEqual(railScrollToShow(index: 0, count: 10, slot: 100,
                                        avail: 700, offset: 0), 0)
        XCTAssertEqual(railScrollToShow(index: 9, count: 10, slot: 100,
                                        avail: 700, offset: 0), 300)
        XCTAssertEqual(railScrollToShow(index: 8, count: 10, slot: 100,
                                        avail: 700, offset: 0), 200)
        // Already visible → offset unchanged.
        XCTAssertEqual(railScrollToShow(index: 2, count: 10, slot: 100,
                                        avail: 700, offset: 100), 100)
    }

    func testScrollZeroWhenEverythingFits() {
        // 5 cells, 700 viewport → all fit, no scroll regardless of index.
        XCTAssertEqual(railScrollToShow(index: 4, count: 5, slot: 100,
                                        avail: 700, offset: 0), 0)
    }
}
