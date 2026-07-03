import CoreGraphics
import Testing
@testable import FacetCore

/// Pure geometry tests for the master-left engine (the old `tall`). A
/// clean 1600×1000 rect keeps the arithmetic exact (ratio 0.5 → 800;
/// two stack rows → 500 each).
struct MasterLeftLayoutTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let ml = MasterLeftLayout()

    @Test func emptyOrderEmptyFrames() {
        #expect(ml.frames(order: [], focused: nil,
                          params: LayoutParams(),
                          in: screen).isEmpty)
    }

    @Test func singleWindowFillsRect() {
        let f = ml.frames(order: [wid(1)], focused: nil,
                          params: LayoutParams(), in: screen)
        #expect(f == [wid(1): screen])
    }

    @Test func twoWindowsSplitByRatio() {
        // master (order[0]) gets the left half, the single stack
        // window the right half — both full height.
        let f = ml.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    @Test func threeWindowsStackRows() {
        // master left full height; two stack windows split the right
        // column into equal rows (order[1] on top at minY).
        let f = ml.frames(order: [wid(1), wid(2), wid(3)], focused: nil,
                          params: LayoutParams(masterRatio: 0.5),
                          in: screen)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 800, y: 0, width: 800, height: 500))
        #expect(f[wid(3)] == CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    @Test func masterRatioRespected() {
        let f = ml.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterRatio: 0.6),
                          in: screen)
        #expect(f[wid(1)]?.width == 960)   // 0.6 * 1600
        #expect(f[wid(2)]?.width == 640)
        #expect(f[wid(2)]?.minX == 960)
    }

    @Test func multipleMastersSplitLeftColumn() {
        // masterCount 2, 4 windows: two masters as rows in the left
        // half, two stack windows as rows in the right half.
        let f = ml.frames(order: [wid(1), wid(2), wid(3), wid(4)],
                          focused: nil,
                          params: LayoutParams(masterRatio: 0.5,
                                               masterCount: 2),
                          in: screen)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 800, height: 500))
        #expect(f[wid(2)] == CGRect(x: 0, y: 500, width: 800, height: 500))
        #expect(f[wid(3)] == CGRect(x: 800, y: 0, width: 800, height: 500))
        #expect(f[wid(4)] == CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    @Test func masterCountExceedingWindowsFillsWholeRect() {
        // masterCount 5 but only 2 windows → no stack column; the
        // master area is the whole rect, split into rows.
        let f = ml.frames(order: [wid(1), wid(2)], focused: nil,
                          params: LayoutParams(masterCount: 5),
                          in: screen)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 1600, height: 500))
        #expect(f[wid(2)] == CGRect(x: 0, y: 500, width: 1600, height: 500))
    }

    @Test func registryResolvesMasterLeft() {
        #expect(LayoutRegistry.engine(named: "master-left")?.name
                == "master-left")
        #expect(LayoutRegistry.engine(named: "MASTER-LEFT")?.name
                == "master-left")
        #expect(LayoutRegistry.names.contains("master-left"))
    }
}
