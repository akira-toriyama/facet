import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure geometry tests for the spiral engine. 1600×1000 → halves are
/// 800 / 500, quarters 400 / 250.
final class SpiralLayoutTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let spiral = SpiralLayout()

    private func frames(_ n: Int) -> [WindowID: CGRect] {
        spiral.frames(order: (1...n).map(wid), focused: nil,
                      params: LayoutParams(), in: screen)
    }

    func testEmptyOrderEmptyFrames() {
        XCTAssertTrue(spiral.frames(order: [], focused: nil,
                                    params: LayoutParams(),
                                    in: screen).isEmpty)
    }

    func testSingleFillsRect() {
        XCTAssertEqual(frames(1), [wid(1): screen])
    }

    func testTwoSplitsLeftRight() {
        // window 0 left half, last window fills the right half.
        let f = frames(2)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    func testThreeWindsLeftThenTop() {
        // 0: left; 1: top of the right half; 2(last): bottom remainder.
        let f = frames(3)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 800, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testFourSpiralsClockwiseInward() {
        // 0 left, 1 top-right, 2 right-of-remainder, 3 fills the rest.
        let f = frames(4)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 800, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 1200, y: 500, width: 400, height: 500))
        XCTAssertEqual(f[wid(4)], CGRect(x: 800, y: 500, width: 400, height: 500))
    }

    func testEveryWindowGetsAFrameAndNoneEscapeRect() {
        for n in 1...8 {
            let f = frames(n)
            XCTAssertEqual(f.count, n)
            for r in f.values {
                XCTAssertGreaterThanOrEqual(r.minX, 0)
                XCTAssertGreaterThanOrEqual(r.minY, 0)
                XCTAssertLessThanOrEqual(r.maxX, 1600.0001)
                XCTAssertLessThanOrEqual(r.maxY, 1000.0001)
                XCTAssertGreaterThan(r.width, 0)
                XCTAssertGreaterThan(r.height, 0)
            }
        }
    }

    func testRegistryResolvesSpiral() {
        XCTAssertEqual(LayoutRegistry.engine(named: "spiral")?.name, "spiral")
        XCTAssertTrue(LayoutRegistry.names.contains("spiral"))
    }
}
