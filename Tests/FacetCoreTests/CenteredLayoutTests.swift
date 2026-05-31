import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure geometry tests for `centered`. 1600×1000, ratio 0.5 → side
/// columns 400 wide, centered master 800 wide.
final class CenteredLayoutTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let cm = CenteredLayout()

    func testEmptyOrderEmptyFrames() {
        XCTAssertTrue(cm.frames(order: [], focused: nil,
                                params: LayoutParams(),
                                in: screen).isEmpty)
    }

    func testMasterOnlyFillsWholeRect() {
        let f = cm.frames(order: [wid(1)], focused: nil,
                          params: LayoutParams(), in: screen)
        XCTAssertEqual(f, [wid(1): screen])
    }

    func testMasterCentredWithTwoStackOneEachSide() {
        // 1 master + 2 stack: right gets the first (ceil), left the
        // second. Master centered 800 wide between 400 side columns.
        let f = cm.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 400, y: 0, width: 800, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 1200, y: 0, width: 400, height: 1000))
        XCTAssertEqual(f[wid(3)], CGRect(x: 0, y: 0, width: 400, height: 1000))
    }

    func testSingleStackGoesRightLeftEmpty() {
        // 1 master + 1 stack: master stays centered, the stack window
        // lands in the right column, left column is empty.
        let f = cm.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(f[wid(1)], CGRect(x: 400, y: 0, width: 800, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 1200, y: 0, width: 400, height: 1000))
    }

    func testSideColumnsStackIntoRows() {
        // 1 master + 4 stack → 2 per side, each side split into rows.
        let f = cm.frames(order: (1...5).map(wid), focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        // right = stack[0],stack[1] = wid2,wid3 ; left = wid4,wid5
        XCTAssertEqual(f[wid(1)], CGRect(x: 400, y: 0, width: 800, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 1200, y: 0, width: 400, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 1200, y: 500, width: 400, height: 500))
        XCTAssertEqual(f[wid(4)], CGRect(x: 0, y: 0, width: 400, height: 500))
        XCTAssertEqual(f[wid(5)], CGRect(x: 0, y: 500, width: 400, height: 500))
    }

    func testMasterRatioWidensCenter() {
        // ratio 0.6 → sides 320, center 960.
        let f = cm.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                          params: LayoutParams(masterRatio: 0.6),
                          in: screen)
        XCTAssertEqual(f[wid(1)]?.minX, 320)
        XCTAssertEqual(f[wid(1)]?.width, 960)
        XCTAssertEqual(f[wid(3)]?.width, 320)   // left side
    }

    func testTwoMastersFillWholeWhenNoStack() {
        let f = cm.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterCount: 2),
                          in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    func testRegistryResolvesCentered() {
        XCTAssertEqual(LayoutRegistry.engine(named: "centered")?.name,
                       "centered")
        XCTAssertEqual(LayoutRegistry.engine(named: "CENTERED")?.name,
                       "centered")
        XCTAssertTrue(LayoutRegistry.names.contains("centered"))
    }
}
