import CoreGraphics
import XCTest
@testable import FacetCore

/// `MasterBottomLayout` = `MasterTopLayout` mirrored across Y (master
/// docks on the bottom). 1600×1000, ratio 0.5 → master bottom row 500
/// tall, stack columns in the top 500-tall row.
final class MasterBottomLayoutTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let mb = MasterBottomLayout()
    private let mt = MasterTopLayout()

    /// Mirror a frame across the rect's horizontal centre line.
    private func mirrorY(_ f: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: f.minX,
               y: rect.maxY - (f.minY - rect.minY) - f.height,
               width: f.width, height: f.height)
    }

    func testSingleWindowFillsRect() {
        let f = mb.frames(order: [wid(1)], focused: nil,
                          params: LayoutParams(), in: screen)
        XCTAssertEqual(f, [wid(1): screen])
    }

    func testTwoWindowsMasterOnBottom() {
        let f = mb.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 500, width: 1600, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 0, width: 1600, height: 500))
    }

    func testThreeMasterRowStackColumnsOnTop() {
        let f = mb.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 500, width: 1600, height: 500))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertEqual(f[wid(3)], CGRect(x: 800, y: 0, width: 800, height: 500))
    }

    func testRatioControlsMasterHeight() {
        let f = mb.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterRatio: 0.6),
                          in: screen)
        XCTAssertEqual(f[wid(1)]?.height, 600)     // 0.6 * 1000
        XCTAssertEqual(f[wid(1)]?.minY, 400)       // docked bottom
        XCTAssertEqual(f[wid(2)]?.height, 400)
        XCTAssertEqual(f[wid(2)]?.minY, 0)
    }

    /// The defining invariant: master-bottom is the exact Y-mirror of
    /// master-top for the same order/params.
    func testIsYMirrorOfMasterTop() {
        for n in [2, 3, 4, 5] {
            let order = (1...n).map(wid)
            let p = LayoutParams(masterRatio: 0.55, masterCount: 1)
            let top = mt.frames(order: order, focused: nil, params: p, in: screen)
            let bottom = mb.frames(order: order, focused: nil, params: p, in: screen)
            for id in order {
                XCTAssertEqual(bottom[id], top[id].map { mirrorY($0, in: screen) },
                               "master-bottom must be master-top mirrored across Y (n=\(n))")
            }
        }
    }

    func testRegistryResolvesMasterBottom() {
        XCTAssertEqual(LayoutRegistry.engine(named: "master-bottom")?.name,
                       "master-bottom")
        XCTAssertTrue(LayoutRegistry.names.contains("master-bottom"))
    }
}
