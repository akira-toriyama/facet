import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure geometry tests for the grid engine. 1200×600 keeps cells
/// exact: /2 = 600, /3 = 400, /2 height = 300.
final class GridLayoutTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 600)
    private let grid = GridLayout()

    private func frames(_ n: Int) -> [WindowID: CGRect] {
        grid.frames(order: (1...n).map(wid), focused: nil,
                    params: LayoutParams(), in: screen)
    }

    func testEmptyOrderEmptyFrames() {
        XCTAssertTrue(grid.frames(order: [], focused: nil,
                                  params: LayoutParams(),
                                  in: screen).isEmpty)
    }

    func testSingleFillsRect() {
        XCTAssertEqual(frames(1), [wid(1): screen])
    }

    func testTwoSideBySide() {
        // cols = 2, rows = 1.
        let f = frames(2)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 600, height: 600))
        XCTAssertEqual(f[wid(2)], CGRect(x: 600, y: 0, width: 600, height: 600))
    }

    func testFourMakesTwoByTwo() {
        // cols = 2, rows = 2 → 600×300 cells.
        let f = frames(4)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 600, height: 300))
        XCTAssertEqual(f[wid(2)], CGRect(x: 600, y: 0, width: 600, height: 300))
        XCTAssertEqual(f[wid(3)], CGRect(x: 0, y: 300, width: 600, height: 300))
        XCTAssertEqual(f[wid(4)], CGRect(x: 600, y: 300, width: 600, height: 300))
    }

    func testThreeWidensLastRow() {
        // cols = 2, rows = 2. Top row 2 cells (600 each); bottom row
        // has 1 window widened to the full 1200.
        let f = frames(3)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 600, height: 300))
        XCTAssertEqual(f[wid(2)], CGRect(x: 600, y: 0, width: 600, height: 300))
        XCTAssertEqual(f[wid(3)], CGRect(x: 0, y: 300, width: 1200, height: 300))
    }

    func testFiveIsThreeColsTwoRowsLastRowWidened() {
        // cols = 3, rows = 2. Top row 3 cells (400 each); bottom row
        // 2 windows widened to 600 each.
        let f = frames(5)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(f[wid(2)], CGRect(x: 400, y: 0, width: 400, height: 300))
        XCTAssertEqual(f[wid(3)], CGRect(x: 800, y: 0, width: 400, height: 300))
        XCTAssertEqual(f[wid(4)], CGRect(x: 0, y: 300, width: 600, height: 300))
        XCTAssertEqual(f[wid(5)], CGRect(x: 600, y: 300, width: 600, height: 300))
    }

    func testAllWindowsGetAFrame() {
        for n in 1...9 {
            XCTAssertEqual(frames(n).count, n,
                           "every window must get exactly one frame")
        }
    }

    func testRegistryResolvesGrid() {
        XCTAssertEqual(LayoutRegistry.engine(named: "grid")?.name, "grid")
        XCTAssertTrue(LayoutRegistry.names.contains("grid"))
    }
}
