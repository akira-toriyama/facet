import CoreGraphics
import Testing
@testable import FacetCore

/// Pure geometry tests for the grid engine. 1200×600 keeps cells
/// exact: /2 = 600, /3 = 400, /2 height = 300.
struct GridLayoutTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 600)
    private let grid = GridLayout()

    private func frames(_ n: Int) -> [WindowID: CGRect] {
        grid.frames(order: (1...n).map(wid), focused: nil,
                    params: LayoutParams(), in: screen)
    }

    @Test func emptyOrderEmptyFrames() {
        #expect(grid.frames(order: [], focused: nil,
                            params: LayoutParams(),
                            in: screen).isEmpty)
    }

    @Test func singleFillsRect() {
        #expect(frames(1) == [wid(1): screen])
    }

    @Test func twoSideBySide() {
        // cols = 2, rows = 1.
        let f = frames(2)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 600, height: 600))
        #expect(f[wid(2)] == CGRect(x: 600, y: 0, width: 600, height: 600))
    }

    @Test func fourMakesTwoByTwo() {
        // cols = 2, rows = 2 → 600×300 cells.
        let f = frames(4)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 600, height: 300))
        #expect(f[wid(2)] == CGRect(x: 600, y: 0, width: 600, height: 300))
        #expect(f[wid(3)] == CGRect(x: 0, y: 300, width: 600, height: 300))
        #expect(f[wid(4)] == CGRect(x: 600, y: 300, width: 600, height: 300))
    }

    @Test func threeWidensLastRow() {
        // cols = 2, rows = 2. Top row 2 cells (600 each); bottom row
        // has 1 window widened to the full 1200.
        let f = frames(3)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 600, height: 300))
        #expect(f[wid(2)] == CGRect(x: 600, y: 0, width: 600, height: 300))
        #expect(f[wid(3)] == CGRect(x: 0, y: 300, width: 1200, height: 300))
    }

    @Test func fiveIsThreeColsTwoRowsLastRowWidened() {
        // cols = 3, rows = 2. Top row 3 cells (400 each); bottom row
        // 2 windows widened to 600 each.
        let f = frames(5)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(f[wid(2)] == CGRect(x: 400, y: 0, width: 400, height: 300))
        #expect(f[wid(3)] == CGRect(x: 800, y: 0, width: 400, height: 300))
        #expect(f[wid(4)] == CGRect(x: 0, y: 300, width: 600, height: 300))
        #expect(f[wid(5)] == CGRect(x: 600, y: 300, width: 600, height: 300))
    }

    @Test func allWindowsGetAFrame() {
        for n in 1...9 {
            #expect(frames(n).count == n,
                    "every window must get exactly one frame")
        }
    }

    @Test func registryResolvesGrid() {
        #expect(LayoutRegistry.engine(named: "grid")?.name == "grid")
        #expect(LayoutRegistry.names.contains("grid"))
    }
}
