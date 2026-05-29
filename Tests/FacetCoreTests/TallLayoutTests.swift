import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure geometry tests for the Tall / master-stack engine. A clean
/// 1600×1000 rect keeps the arithmetic exact (ratio 0.5 → 800; two
/// stack rows → 500 each).
final class TallLayoutTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let tall = TallLayout()

    func testEmptyOrderEmptyFrames() {
        XCTAssertTrue(tall.frames(order: [], focused: nil,
                                  params: LayoutParams(),
                                  in: screen).isEmpty)
    }

    func testSingleWindowFillsRect() {
        let f = tall.frames(order: [wid(1)], focused: nil,
                            params: LayoutParams(), in: screen)
        XCTAssertEqual(f, [wid(1): screen])
    }

    func testTwoWindowsSplitByRatio() {
        // master (order[0]) gets the left half, the single stack
        // window the right half — both full height.
        let f = tall.frames(order: [wid(1), wid(2)], focused: nil,
                            params: LayoutParams(masterRatio: 0.5),
                            in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    func testThreeWindowsStackRows() {
        // master left full height; two stack windows split the right
        // column into equal rows (order[1] on top at minY).
        let f = tall.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                            params: LayoutParams(masterRatio: 0.5),
                            in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 800, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testMasterRatioRespected() {
        let f = tall.frames(order: [wid(1), wid(2)], focused: nil,
                            params: LayoutParams(masterRatio: 0.6),
                            in: screen)
        XCTAssertEqual(f[wid(1)]?.width, 960)   // 0.6 * 1600
        XCTAssertEqual(f[wid(2)]?.width, 640)
        XCTAssertEqual(f[wid(2)]?.minX, 960)
    }

    func testMultipleMastersSplitLeftColumn() {
        // masterCount 2, 4 windows: two masters as rows in the left
        // half, two stack windows as rows in the right half.
        let f = tall.frames(order: [wid(1), wid(2), wid(3), wid(4)],
                            focused: nil,
                            params: LayoutParams(masterRatio: 0.5,
                                                 masterCount: 2),
                            in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 500, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 800, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(4)], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testMasterCountExceedingWindowsFillsWholeRect() {
        // masterCount 5 but only 2 windows → no stack column; the
        // master area is the whole rect, split into rows.
        let f = tall.frames(order: [wid(1), wid(2)], focused: nil,
                            params: LayoutParams(masterCount: 5),
                            in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    func testRegistryResolvesTall() {
        XCTAssertEqual(LayoutRegistry.engine(named: "tall")?.name, "tall")
        XCTAssertTrue(LayoutRegistry.names.contains("tall"))
    }
}
