import CoreGraphics
import XCTest
@testable import FacetCore

/// `MasterTopLayout` (the old `wide`) = master row on top, stack
/// columns below (master-left rotated 90°). 1600×1000, ratio 0.5 →
/// master row 500 tall, columns 800 wide.
final class MasterTopLayoutTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let mt = MasterTopLayout()

    private func params(_ ratio: CGFloat = 0.5, masters: Int = 1) -> LayoutParams {
        LayoutParams(masterRatio: ratio, masterCount: masters)
    }

    func testSingleFillsRect() {
        let f = mt.frames(order: [wid(1)], focused: nil,
                          params: params(), in: screen)
        XCTAssertEqual(f, [wid(1): screen])
    }

    func testTwoSplitTopBottom() {
        let f = mt.frames(order: [wid(1), wid(2)], focused: nil,
                          params: params(), in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    func testThreeMasterRowStackColumns() {
        // master spans the top; two stack windows are columns below.
        let f = mt.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                          params: params(), in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 500, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testMultipleMastersAsTopColumns() {
        let f = mt.frames(order: [wid(1), wid(2), wid(3), wid(4)],
                          focused: nil, params: params(masters: 2),
                          in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 800, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 0, y: 500, width: 800, height: 500))
        XCTAssertEqual(f[wid(4)], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testRatioControlsMasterHeight() {
        let f = mt.frames(order: [wid(1), wid(2)], focused: nil,
                          params: params(0.6), in: screen)
        XCTAssertEqual(f[wid(1)]?.height, 600)   // 0.6 * 1000
        XCTAssertEqual(f[wid(2)]?.minY, 600)
        XCTAssertEqual(f[wid(2)]?.height, 400)
    }

    func testMasterLeftAndTopDiffer() {
        let order = [wid(1), wid(2)]
        let l = MasterLeftLayout().frames(order: order, focused: nil,
                                          params: LayoutParams(), in: screen)
        let t = mt.frames(order: order, focused: nil,
                          params: params(), in: screen)
        XCTAssertNotEqual(l[wid(1)], t[wid(1)],
                          "master-left and master-top must place the master differently")
    }

    func testRegistryResolvesMasterTop() {
        XCTAssertEqual(LayoutRegistry.engine(named: "master-top")?.name, "master-top")
        XCTAssertEqual(LayoutRegistry.engine(named: "MASTER-TOP")?.name, "master-top")
        XCTAssertTrue(LayoutRegistry.names.contains("master-top"))
    }
}
