import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Tests for the real-window-resize foundation (枠C 機能2 PR-1): the
/// LayoutTree fence walk + ratio update, and the WorkspaceCatalog
/// applyResize wrapper (bsp tree + stateless master divider). Pure — no
/// AX / AppKit. FOLLOW model: resize a leaf to a new frame, the
/// controlling split's ratio moves so the opposite side tracks it.
final class RealWindowResizeTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private func window(_ n: Int) -> Window {
        Window(id: wid(n), pid: 1000, appName: "A", title: "w\(n)",
               isFocused: false, isFloating: false, frame: nil)
    }
    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let tallRect = CGRect(x: 0, y: 0, width: 900, height: 1600)

    private func seeded(_ n: Int) -> WorkspaceCatalog {
        var c = WorkspaceCatalog()
        c.seed(configs: (1...5).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        _ = c.reconcile(live: (1...n).map { window($0) })
        return c
    }

    /// wid(1) | wid(2): vertical split (left | right halves of `rect`).
    private func twoVertical() -> LayoutTree {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: rect)
        t.insert(wid(2), focused: wid(1), in: rect)
        return t
    }

    /// wid(1) over wid(2): horizontal split (top | bottom of `tallRect`).
    private func twoHorizontal() -> LayoutTree {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: tallRect)
        t.insert(wid(2), focused: wid(1), in: tallRect)
        return t
    }

    // MARK: - LayoutTree.resize

    func testResizeRightEdgeGrowsAndNeighborFollows() {
        var t = twoVertical()                    // 1=(0,0,800,900)
        t.resize(wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: 900),
                 in: rect)
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1000, height: 900))
        XCTAssertEqual(f[wid(2)], CGRect(x: 1000, y: 0, width: 600, height: 900))
    }

    func testResizeRightEdgeShrinks() {
        var t = twoVertical()
        t.resize(wid(1), to: CGRect(x: 0, y: 0, width: 400, height: 900),
                 in: rect)
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 400, height: 900))
        XCTAssertEqual(f[wid(2)], CGRect(x: 400, y: 0, width: 1200, height: 900))
    }

    func testResizeNeighborLeftEdgeSameDivider() {
        // Dragging window 2's LEFT edge moves the same fence.
        var t = twoVertical()
        t.resize(wid(2), to: CGRect(x: 600, y: 0, width: 1000, height: 900),
                 in: rect)
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 600, height: 900))
        XCTAssertEqual(f[wid(2)], CGRect(x: 600, y: 0, width: 1000, height: 900))
    }

    func testResizeBottomEdgeHorizontalSplit() {
        var t = twoHorizontal()                  // 1=(0,0,900,800)
        t.resize(wid(1), to: CGRect(x: 0, y: 0, width: 900, height: 1000),
                 in: tallRect)
        let f = t.frames(in: tallRect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 900, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 1000, width: 900, height: 600))
    }

    func testResizeCornerUpdatesBothFences() {
        // [1 | 2] on top, 3 on the bottom — window 1 has a vertical
        // right-fence AND a horizontal bottom-fence (different ancestors).
        let root = LayoutNode.split(.init(
            orientation: .horizontal, ratio: 0.5,
            first: .split(.init(orientation: .vertical, ratio: 0.5,
                                first: .leaf(wid(1)), second: .leaf(wid(2)))),
            second: .leaf(wid(3))))
        var t = LayoutTree(root: root)
        let r = CGRect(x: 0, y: 0, width: 1600, height: 1600)
        t.resize(wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                 in: r)
        let f = t.frames(in: r)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(f[wid(2)], CGRect(x: 1000, y: 0, width: 600, height: 1000))
        XCTAssertEqual(f[wid(3)], CGRect(x: 0, y: 1000, width: 1600, height: 600))
    }

    func testResizeScreenEdgeIsNoOp() {
        // Window 1's LEFT edge is the screen boundary — no fence → no-op.
        let t0 = twoVertical()
        var t = t0
        t.resize(wid(1), to: CGRect(x: 100, y: 0, width: 700, height: 900),
                 in: rect)
        XCTAssertEqual(t, t0)
    }

    func testResizeClampsRatio() {
        var t = twoVertical()
        t.resize(wid(1), to: CGRect(x: 0, y: 0, width: 1590, height: 900),
                 in: rect)
        let f = t.frames(in: rect)
        // ratio 0.994 clamps to 0.95 → 1 = 1520 wide, 2 = 80.
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1520, height: 900))
        XCTAssertEqual(f[wid(2)], CGRect(x: 1520, y: 0, width: 80, height: 900))
    }

    func testResizeAbsentIsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.resize(wid(9), to: CGRect(x: 0, y: 0, width: 1000, height: 900),
                 in: rect)
        XCTAssertEqual(t, t0)
    }

    // MARK: - Catalog.applyResize

    func testCatalogApplyResizeBsp() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        XCTAssertTrue(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: 900),
            workspace: 1, in: rect))
        let f = c.tiledFrames(for: 1, in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1000, height: 900))
        XCTAssertEqual(f[wid(2)], CGRect(x: 1000, y: 0, width: 600, height: 900))
    }

    func testCatalogApplyResizeTallMaster() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "tall")   // master=1 (ratio 0.5 → 800w)
        XCTAssertTrue(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: 900),
            workspace: 1, in: rect))
        let f = c.engineFrames(for: 1, in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1000, height: 900))
    }

    func testCatalogApplyResizeNoOpGrid() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "grid")
        XCTAssertFalse(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: 900),
            workspace: 1, in: rect))
    }

    func testCatalogApplyResizeNoOpUnmovedEdge() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "tall")   // master right edge already 800
        XCTAssertFalse(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 800, height: 900),
            workspace: 1, in: rect))
    }
}
