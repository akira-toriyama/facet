import CoreGraphics
import XCTest
@testable import FacetCore

/// `WideLayout` = master row on top, stack columns below (TallLayout
/// rotated 90°). 1600×1000, ratio 0.5 → master row 500 tall, columns
/// 800 wide.
final class WideLayoutTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let wide = WideLayout()

    private func params(_ ratio: CGFloat = 0.5, masters: Int = 1) -> LayoutParams {
        LayoutParams(masterRatio: ratio, masterCount: masters)
    }

    func testSingleFillsRect() {
        let f = wide.frames(order: [wid(1)], focused: nil,
                            params: params(), in: screen)
        XCTAssertEqual(f, [wid(1): screen])
    }

    func testTwoSplitTopBottom() {
        let f = wide.frames(order: [wid(1), wid(2)], focused: nil,
                            params: params(), in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    func testThreeMasterRowStackColumns() {
        // master spans the top; two stack windows are columns below.
        let f = wide.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                            params: params(), in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 500, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testMultipleMastersAsTopColumns() {
        let f = wide.frames(order: [wid(1), wid(2), wid(3), wid(4)],
                            focused: nil, params: params(masters: 2),
                            in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 800, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 0, y: 500, width: 800, height: 500))
        XCTAssertEqual(f[wid(4)], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testRatioControlsMasterHeight() {
        let f = wide.frames(order: [wid(1), wid(2)], focused: nil,
                            params: params(0.6), in: screen)
        XCTAssertEqual(f[wid(1)]?.height, 600)   // 0.6 * 1000
        XCTAssertEqual(f[wid(2)]?.minY, 600)
        XCTAssertEqual(f[wid(2)]?.height, 400)
    }

    func testTallAndWideDiffer() {
        let order = [wid(1), wid(2)]
        let t = TallLayout().frames(order: order, focused: nil,
                                    params: LayoutParams(), in: screen)
        let w = wide.frames(order: order, focused: nil,
                            params: params(), in: screen)
        XCTAssertNotEqual(t[wid(1)], w[wid(1)],
                          "Tall and Wide must place the master differently")
    }

    func testRegistryResolvesWide() {
        XCTAssertEqual(LayoutRegistry.engine(named: "wide")?.name, "wide")
        XCTAssertEqual(LayoutRegistry.engine(named: "WIDE")?.name, "wide")
        XCTAssertTrue(LayoutRegistry.names.contains("wide"))
    }
}
