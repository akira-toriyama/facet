import CoreGraphics
import Testing
@testable import FacetCore

/// Pure geometry tests for the spiral engine. 1600×1000 → halves are
/// 800 / 500, quarters 400 / 250.
struct SpiralLayoutTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let spiral = SpiralLayout()

    private func frames(_ n: Int) -> [WindowID: CGRect] {
        spiral.frames(order: (1...n).map(wid), focused: nil,
                      params: LayoutParams(), in: screen)
    }

    @Test func emptyOrderEmptyFrames() {
        #expect(spiral.frames(order: [], focused: nil,
                              params: LayoutParams(),
                              in: screen).isEmpty)
    }

    @Test func singleFillsRect() {
        #expect(frames(1) == [wid(1): screen])
    }

    @Test func twoSplitsLeftRight() {
        // window 0 left half, last window fills the right half.
        let f = frames(2)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    @Test func threeWindsLeftThenTop() {
        // 0: left; 1: top of the right half; 2(last): bottom remainder.
        let f = frames(3)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 800, y: 0, width: 800, height: 500))
        #expect(f[wid(3)] == CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    @Test func fourSpiralsClockwiseInward() {
        // 0 left, 1 top-right, 2 right-of-remainder, 3 fills the rest.
        let f = frames(4)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 800, y: 0, width: 800, height: 500))
        #expect(f[wid(3)] == CGRect(x: 1200, y: 500, width: 400, height: 500))
        #expect(f[wid(4)] == CGRect(x: 800, y: 500, width: 400, height: 500))
    }

    @Test func everyWindowGetsAFrameAndNoneEscapeRect() {
        for n in 1...8 {
            let f = frames(n)
            #expect(f.count == n)
            for r in f.values {
                #expect(r.minX >= 0)
                #expect(r.minY >= 0)
                #expect(r.maxX <= 1600.0001)
                #expect(r.maxY <= 1000.0001)
                #expect(r.width > 0)
                #expect(r.height > 0)
            }
        }
    }

    /// The 4th rotation direction (`default` / i%4==3) docks into the
    /// BOTTOM half of the remainder and shrinks the leftover to the top
    /// half. It is only reached at index 3 when there are ≥5 windows (for
    /// n≤4 the 4th window is `last` and just fills the remainder, never
    /// running the bottom-split branch). Regression pins the exact
    /// bottom-split y-arithmetic — a wrong sign / wrong half would still
    /// land inside the rect and pass the bounds-only loop, but mis-place
    /// the window.
    @Test func fiveSpiralsBottomSplitDefaultBranch() {
        let f = frames(5)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 800, height: 1000))
        #expect(f[wid(2)] == CGRect(x: 800, y: 0, width: 800, height: 500))
        #expect(f[wid(3)] == CGRect(x: 1200, y: 500, width: 400, height: 500))
        #expect(f[wid(4)] == CGRect(x: 800, y: 750, width: 400, height: 250))
        #expect(f[wid(5)] == CGRect(x: 800, y: 500, width: 400, height: 250))
    }

    @Test func registryResolvesSpiral() {
        #expect(LayoutRegistry.engine(named: "spiral")?.name == "spiral")
        #expect(LayoutRegistry.names.contains("spiral"))
    }
}
