import CoreGraphics
import Testing
@testable import FacetCore

/// `MasterRightLayout` = `MasterLeftLayout` mirrored across X (master
/// docks on the right). 1600×1000, ratio 0.5 → master right column 800
/// wide, stack rows in the left 800-wide column.
struct MasterRightLayoutTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let mr = MasterRightLayout()
    private let ml = MasterLeftLayout()

    /// Mirror a frame across the rect's vertical centre line.
    private func mirrorX(_ f: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - (f.minX - rect.minX) - f.width,
               y: f.minY, width: f.width, height: f.height)
    }

    @Test func singleWindowFillsRect() {
        let f = mr.frames(order: [wid(1)], focused: nil,
                          params: LayoutParams(), in: screen)
        #expect(f == [wid(1): screen])
    }

    @Test func twoWindowsMasterOnRight() {
        let f = mr.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        #expect(f[wid(1)] == CGRect(x: 800, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 0, y: 0, width: 800, height: 1000))
    }

    @Test func threeWindowsStackRowsOnLeft() {
        let f = mr.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        #expect(f[wid(1)] == CGRect(x: 800, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 0, y: 0, width: 800, height: 500))
        #expect(f[wid(3)] == CGRect(x: 0, y: 500, width: 800, height: 500))
    }

    @Test func masterRatioRespected() {
        let f = mr.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterRatio: 0.6),
                          in: screen)
        #expect(f[wid(1)]?.width == 960)      // 0.6 * 1600
        #expect(f[wid(1)]?.minX == 640)       // docked right
        #expect(f[wid(2)]?.width == 640)
        #expect(f[wid(2)]?.minX == 0)
    }

    /// The defining invariant: master-right is the exact X-mirror of
    /// master-left for the same order/params.
    @Test func isXMirrorOfMasterLeft() {
        for n in [2, 3, 4, 5] {
            let order = (1...n).map(wid)
            let p = LayoutParams(masterRatio: 0.55, masterCount: 1)
            let left = ml.frames(order: order, focused: nil, params: p, in: screen)
            let right = mr.frames(order: order, focused: nil, params: p, in: screen)
            for id in order {
                #expect(right[id] == left[id].map { mirrorX($0, in: screen) },
                        "master-right must be master-left mirrored across X (n=\(n))")
            }
        }
    }

    @Test func registryResolvesMasterRight() {
        #expect(LayoutRegistry.engine(named: "master-right")?.name == "master-right")
        #expect(LayoutRegistry.names.contains("master-right"))
    }
}
