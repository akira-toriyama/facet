import CoreGraphics
import Testing
@testable import FacetCore

/// Pure geometry tests for `master-center` (the old `centered`).
/// 1600×1000, ratio 0.5 → side columns 400 wide, centered master 800
/// wide.
struct MasterCenterLayoutTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let cm = MasterCenterLayout()

    @Test func emptyOrderEmptyFrames() {
        #expect(cm.frames(order: [], focused: nil,
                          params: LayoutParams(),
                          in: screen).isEmpty)
    }

    @Test func masterOnlyFillsWholeRect() {
        let f = cm.frames(order: [wid(1)], focused: nil,
                          params: LayoutParams(), in: screen)
        #expect(f == [wid(1): screen])
    }

    @Test func masterCentredWithTwoStackOneEachSide() {
        // 1 master + 2 stack: right gets the first (ceil), left the
        // second. Master centered 800 wide between 400 side columns.
        let f = cm.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        #expect(f[wid(1)] == CGRect(x: 400, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 1200, y: 0, width: 400, height: 1000))
        #expect(f[wid(3)] == CGRect(x: 0, y: 0, width: 400, height: 1000))
    }

    @Test func singleStackGoesRightLeftEmpty() {
        // 1 master + 1 stack: master stays centered, the stack window
        // lands in the right column, left column is empty.
        let f = cm.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        #expect(f.count == 2)
        #expect(f[wid(1)] == CGRect(x: 400, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 1200, y: 0, width: 400, height: 1000))
    }

    @Test func sideColumnsStackIntoRows() {
        // 1 master + 4 stack → 2 per side, each side split into rows.
        let f = cm.frames(order: (1...5).map(wid), focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        // right = stack[0],stack[1] = wid2,wid3 ; left = wid4,wid5
        #expect(f[wid(1)] == CGRect(x: 400, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 1200, y: 0, width: 400, height: 500))
        #expect(f[wid(3)] == CGRect(x: 1200, y: 500, width: 400, height: 500))
        #expect(f[wid(4)] == CGRect(x: 0, y: 0, width: 400, height: 500))
        #expect(f[wid(5)] == CGRect(x: 0, y: 500, width: 400, height: 500))
    }

    @Test func masterRatioWidensCenter() {
        // ratio 0.6 → sides 320, center 960.
        let f = cm.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                          params: LayoutParams(masterRatio: 0.6),
                          in: screen)
        #expect(f[wid(1)]?.minX == 320)
        #expect(f[wid(1)]?.width == 960)
        #expect(f[wid(3)]?.width == 320)   // left side
    }

    @Test func twoMastersFillWholeWhenNoStack() {
        let f = cm.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterCount: 2),
                          in: screen)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 1600, height: 500))
        #expect(f[wid(2)] == CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    @Test func registryResolvesMasterCenter() {
        #expect(LayoutRegistry.engine(named: "master-center")?.name
                == "master-center")
        #expect(LayoutRegistry.engine(named: "MASTER-CENTER")?.name
                == "master-center")
        #expect(LayoutRegistry.names.contains("master-center"))
    }
}
