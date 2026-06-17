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

    // MARK: - resize freeze set (live reflow: opposite subtree only)

    func testResizeReturnsFreezeSetSimpleFence() {
        // w1 | w2: drag w1's right edge → fence is the root; the dragged
        // side is just {w1}, so only w2 (opposite) follows.
        var t = twoVertical()
        let h = t.frames(in: rect)[wid(1)]!.height
        let frozen = t.resize(
            wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: h), in: rect)
        XCTAssertEqual(frozen, [wid(1)])
    }

    func testResizeHighFenceFreezesWholeSubtree() {
        // w1 | (w2 · w3): dragging w2's LEFT edge moves the ROOT fence
        // (w1 | [w2 w3]); its dragged side comoves, so {w2,w3} freeze and
        // only w1 follows. Without this the live reflow re-tiles w3 to its
        // computed slot, off w2's actual frame → the gap トミー saw.
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: rect)
        t.insert(wid(2), focused: wid(1), in: rect)   // w1 | w2
        t.insert(wid(3), focused: wid(2), in: rect)   // w1 | (w2 · w3)
        let w2 = t.frames(in: rect)[wid(2)]!
        let frozen = t.resize(
            wid(2),
            to: CGRect(x: 600, y: w2.minY, width: w2.maxX - 600,
                       height: w2.height),
            in: rect)
        XCTAssertEqual(frozen, [wid(2), wid(3)])
    }

    // MARK: - Catalog.applyResize

    func testCatalogApplyResizeBsp() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        XCTAssertNotNil(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: 900),
            workspace: 1, in: rect))
        let f = c.tiledFrames(for: 1, in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1000, height: 900))
        XCTAssertEqual(f[wid(2)], CGRect(x: 1000, y: 0, width: 600, height: 900))
    }

    func testCatalogApplyResizeTallMaster() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "master-left")   // master=1 (ratio 0.5 → 800w)
        XCTAssertNotNil(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: 900),
            workspace: 1, in: rect))
        let f = c.engineFrames(for: 1, in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1000, height: 900))
    }

    func testCatalogApplyResizeNoOpGrid() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "grid")
        XCTAssertNil(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 1000, height: 900),
            workspace: 1, in: rect))
    }

    func testCatalogApplyResizeNoOpUnmovedEdge() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "master-left")   // master right edge already 800
        XCTAssertNil(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 800, height: 900),
            workspace: 1, in: rect))
    }

    // MARK: - Catalog.applyResize with inner gap (un-gap mapping)

    func testCatalogApplyResizeGapNoSpuriousCrossAxis() {
        // With an inner gap the dragged window's on-screen frame is inset
        // from its tree slot. A pure-HEIGHT resize must NOT be read as a
        // width (X) edge move via that constant gap offset — that was the
        // "縮小すると隣の窓の右がおかしい" bug. Side-by-side (vertical split):
        // wid1's tree slot is [0,800]; on-screen its interior right edge
        // sits at 790 (inner-gap 20). Drag only its bottom edge up; the
        // right edge stays at 790 → no width change, and (no horizontal
        // split to move) the resize is a no-op.
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        XCTAssertNil(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 790, height: 700),
            workspace: 1, in: rect, innerGap: 20))
        let f = c.tiledFrames(for: 1, in: rect)
        XCTAssertEqual(f[wid(1)]?.maxX, 800)   // divider untouched
        XCTAssertEqual(f[wid(2)]?.minX, 800)
    }

    func testCatalogApplyResizeBspWithGap() {
        // Drag wid1's on-screen RIGHT edge (gapped at 790) out to 990. The
        // un-gap maps it back to the true divider (1000) so the ratio + the
        // neighbour land where the user dropped the edge, gap and all.
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        XCTAssertNotNil(c.applyResize(
            wid(1), to: CGRect(x: 0, y: 0, width: 990, height: 900),
            workspace: 1, in: rect, innerGap: 20))
        let f = c.tiledFrames(for: 1, in: rect)
        XCTAssertEqual(f[wid(1)]?.maxX, 1000)
        XCTAssertEqual(f[wid(2)]?.minX, 1000)
    }
}
