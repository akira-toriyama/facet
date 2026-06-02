import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Tests for the real-window-DnD backend verbs (枠C): LayoutTree leaf
/// swap / edge-insert, and the WorkspaceCatalog swap / insert wrappers
/// across stateless and bsp modes. Pure — no AX / AppKit, same playbook
/// as `WorkspaceCatalogTests` / `RotateMirrorTests`.
final class RealWindowDnDTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private func window(_ n: Int) -> Window {
        Window(id: wid(n), pid: 1000, appName: "A", title: "w\(n)",
               isFocused: false, isFloating: false, frame: nil)
    }
    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)

    /// 5-workspace catalog seeded with windows 1...n all in active WS 1.
    private func seeded(_ n: Int) -> WorkspaceCatalog {
        var c = WorkspaceCatalog()
        c.seed(configs: (1...5).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        _ = c.reconcile(live: (1...n).map { window($0) })
        return c
    }

    /// wid(1) | wid(2): a vertical split (left | right halves).
    private func twoVertical() -> LayoutTree {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: rect)
        t.insert(wid(2), focused: wid(1), in: rect)
        return t
    }

    // MARK: - LayoutTree swap

    func testTreeSwapTradesFrames() {
        var t = twoVertical()
        t.swap(wid(1), wid(2))
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 0, width: 800, height: 900))
        XCTAssertEqual(f[wid(1)], CGRect(x: 800, y: 0, width: 800, height: 900))
    }

    func testTreeSwapPreservesShape() {
        var t = twoVertical()
        t.swap(wid(1), wid(2))
        XCTAssertEqual(t.leaves, [wid(2), wid(1)])
    }

    func testTreeSwapAbsentIsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.swap(wid(1), wid(9))
        XCTAssertEqual(t, t0)
    }

    func testTreeSwapSameIsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.swap(wid(1), wid(1))
        XCTAssertEqual(t, t0)
    }

    // MARK: - LayoutTree insert beside

    func testTreeInsertBottomReSplitsHorizontally() {
        var t = twoVertical()                       // wid1 | wid2
        t.insert(wid(2), beside: wid(1), edge: .bottom)
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1600, height: 450))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 450, width: 1600, height: 450))
    }

    func testTreeInsertRightReSplitsVertically() {
        var t = twoVertical()                       // wid1 left
        t.insert(wid(1), beside: wid(2), edge: .right)
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 0, width: 800, height: 900))
        XCTAssertEqual(f[wid(1)], CGRect(x: 800, y: 0, width: 800, height: 900))
    }

    func testTreeInsertAbsentIsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.insert(wid(9), beside: wid(1), edge: .right)
        XCTAssertEqual(t, t0)
    }

    // MARK: - Catalog swap / insert (stateless engine)

    func testCatalogSwapStatelessReordersOrder() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "tall")     // order seeded [1,2,3]
        XCTAssertTrue(c.swapWindows(wid(1), wid(3), workspace: 1))
        XCTAssertEqual(c.orderedMembers(of: 1), [wid(3), wid(2), wid(1)])
    }

    func testCatalogSwapSameWindowNoOp() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "tall")
        XCTAssertFalse(c.swapWindows(wid(2), wid(2), workspace: 1))
    }

    func testCatalogSwapCrossWSNoOp() {
        // wid(99) is not a member of WS 1.
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "tall")
        XCTAssertFalse(c.swapWindows(wid(1), wid(99), workspace: 1))
    }

    func testCatalogSwapFloatModeNoOp() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "float")
        XCTAssertFalse(c.swapWindows(wid(1), wid(2), workspace: 1),
                       "float keeps no managed order")
    }

    func testCatalogInsertStatelessRepositions() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "tall")     // [1,2,3]
        XCTAssertTrue(c.insertWindow(wid(1), beside: wid(3),
                                     edge: .right, workspace: 1))
        XCTAssertEqual(c.orderedMembers(of: 1), [wid(2), wid(3), wid(1)])
    }

    func testCatalogInsertNoChangeNoOp() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "tall")     // [1,2,3]
        // wid(2) after wid(1) — already there.
        XCTAssertFalse(c.insertWindow(wid(2), beside: wid(1),
                                      edge: .right, workspace: 1))
    }

    // MARK: - Catalog swap / insert (bsp)

    func testCatalogSwapBspSwapsLeaves() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        XCTAssertTrue(c.swapWindows(wid(1), wid(2), workspace: 1))
        XCTAssertEqual(c.layoutTrees[1]?.leaves, [wid(2), wid(1)])
    }

    func testCatalogInsertBspReSplits() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        XCTAssertTrue(c.insertWindow(wid(1), beside: wid(2),
                                     edge: .right, workspace: 1))
        XCTAssertEqual(c.layoutTrees[1]?.leaves, [wid(2), wid(1)])
    }

    func testCatalogSwapBspAbsentNoOp() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        XCTAssertFalse(c.swapWindows(wid(1), wid(99), workspace: 1))
    }

    // MARK: - Drop-prediction foundation (PR-3 overlay)
    // The overlay highlights only the windows a drop MOVES — diffing the
    // pre-drop computed layout against the post-drop one. These verify
    // that diff picks the right set (the basis of `predictedDrop`).

    func testSwapMovesExactlyTheSwappedPair() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "tall")     // master=1, stack=[2,3]
        let before = c.engineFrames(for: 1, in: rect)
        var copy = c
        XCTAssertTrue(copy.swapWindows(wid(1), wid(3), workspace: 1))
        let after = copy.engineFrames(for: 1, in: rect)
        let moved = Set(after.keys.filter { after[$0] != before[$0] })
        // 1 (master ↔ stack) and 3 trade; 2 keeps its stack slot.
        XCTAssertEqual(moved, [wid(1), wid(3)])
    }

    func testInsertReshapesTargetAndMoved() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)   // 1 | 2
        let before = c.tiledFrames(for: 1, in: rect)
        var copy = c
        XCTAssertTrue(copy.insertWindow(wid(1), beside: wid(2),
                                        edge: .bottom, workspace: 1))
        let after = copy.tiledFrames(for: 1, in: rect)
        let moved = Set(after.keys.filter { after[$0] != before[$0] })
        // Both reshape: 2 (right half → top half), 1 (left half → bottom).
        XCTAssertEqual(moved, [wid(1), wid(2)])
    }
}
