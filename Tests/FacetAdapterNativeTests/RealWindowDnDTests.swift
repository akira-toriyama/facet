import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Tests for the real-window-DnD backend verbs (枠C): LayoutTree leaf
/// swap / edge-insert, and the WorkspaceCatalog swap / insert wrappers
/// across stateless and bsp modes. Pure — no AX / AppKit, same playbook
/// as `WorkspaceCatalogTests` / `RotateMirrorTests`.
struct RealWindowDnDTests {

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

    // MARK: - LayoutTree swap

    @Test func treeSwapTradesFrames() {
        var t = twoVertical()
        t.swap(wid(1), wid(2))
        let f = t.frames(in: rect)
        #expect(f[wid(2)] == CGRect(x: 0, y: 0, width: 800, height: 900))
        #expect(f[wid(1)] == CGRect(x: 800, y: 0, width: 800, height: 900))
    }

    @Test func treeSwapPreservesShape() {
        var t = twoVertical()
        t.swap(wid(1), wid(2))
        #expect(t.leaves == [wid(2), wid(1)])
    }

    @Test func treeSwapAbsentIsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.swap(wid(1), wid(9))
        #expect(t == t0)
    }

    @Test func treeSwapSameIsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.swap(wid(1), wid(1))
        #expect(t == t0)
    }

    // MARK: - LayoutTree insert beside

    @Test func treeInsertBottomReSplitsHorizontally() {
        var t = twoVertical()                       // wid1 | wid2
        t.insert(wid(2), beside: wid(1), edge: .bottom)
        let f = t.frames(in: rect)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 1600, height: 450))
        #expect(f[wid(2)] == CGRect(x: 0, y: 450, width: 1600, height: 450))
    }

    @Test func treeInsertRightReSplitsVertically() {
        var t = twoVertical()                       // wid1 left
        t.insert(wid(1), beside: wid(2), edge: .right)
        let f = t.frames(in: rect)
        #expect(f[wid(2)] == CGRect(x: 0, y: 0, width: 800, height: 900))
        #expect(f[wid(1)] == CGRect(x: 800, y: 0, width: 800, height: 900))
    }

    @Test func treeInsertAbsentIsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.insert(wid(9), beside: wid(1), edge: .right)
        #expect(t == t0)
    }

    // MARK: - Catalog swap / insert (stateless engine)

    @Test func catalogSwapStatelessReordersOrder() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "master-left")     // order seeded [1,2,3]
        let swapped = c.swapWindows(wid(1), wid(3), workspace: 1)
        #expect(swapped)
        #expect(c.orderedMembers(of: 1) == [wid(3), wid(2), wid(1)])
    }

    @Test func catalogSwapSameWindowNoOp() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "master-left")
        let swapped = c.swapWindows(wid(2), wid(2), workspace: 1)
        #expect(!swapped)
    }

    @Test func catalogSwapCrossWSNoOp() {
        // wid(99) is not a member of WS 1.
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "master-left")
        let swapped = c.swapWindows(wid(1), wid(99), workspace: 1)
        #expect(!swapped)
    }

    @Test func catalogSwapFloatModeNoOp() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "float")
        let swapped = c.swapWindows(wid(1), wid(2), workspace: 1)
        #expect(!swapped,
                "float keeps no managed order")
    }

    @Test func catalogInsertStatelessRepositions() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "master-left")     // [1,2,3]
        let inserted = c.insertWindow(wid(1), beside: wid(3),
                                     edge: .right, workspace: 1)
        #expect(inserted)
        #expect(c.orderedMembers(of: 1) == [wid(2), wid(3), wid(1)])
    }

    @Test func catalogInsertNoChangeNoOp() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "master-left")     // [1,2,3]
        // wid(2) after wid(1) — already there.
        let inserted = c.insertWindow(wid(2), beside: wid(1),
                                      edge: .right, workspace: 1)
        #expect(!inserted)
    }

    // MARK: - Catalog swap / insert (bsp)

    @Test func catalogSwapBspSwapsLeaves() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        let swapped = c.swapWindows(wid(1), wid(2), workspace: 1)
        #expect(swapped)
        #expect(c.layoutTrees[1]?.leaves == [wid(2), wid(1)])
    }

    @Test func catalogInsertBspReSplits() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        let inserted = c.insertWindow(wid(1), beside: wid(2),
                                     edge: .right, workspace: 1)
        #expect(inserted)
        #expect(c.layoutTrees[1]?.leaves == [wid(2), wid(1)])
    }

    @Test func catalogSwapBspAbsentNoOp() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        let swapped = c.swapWindows(wid(1), wid(99), workspace: 1)
        #expect(!swapped)
    }

    // MARK: - Drop-prediction foundation (PR-3 overlay)
    // The overlay highlights only the windows a drop MOVES — diffing the
    // pre-drop computed layout against the post-drop one. These verify
    // that diff picks the right set (the basis of `predictedDrop`).

    @Test func swapMovesExactlyTheSwappedPair() {
        var c = seeded(3)
        _ = c.setMode(workspace: 1, to: "master-left")     // master=1, stack=[2,3]
        let before = c.engineFrames(for: 1, in: rect)
        var copy = c
        let swapped = copy.swapWindows(wid(1), wid(3), workspace: 1)
        #expect(swapped)
        let after = copy.engineFrames(for: 1, in: rect)
        let moved = Set(after.keys.filter { after[$0] != before[$0] })
        // 1 (master ↔ stack) and 3 trade; 2 keeps its stack slot.
        #expect(moved == [wid(1), wid(3)])
    }

    @Test func insertReshapesTargetAndMoved() {
        var c = seeded(2)
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)   // 1 | 2
        let before = c.tiledFrames(for: 1, in: rect)
        var copy = c
        let inserted = copy.insertWindow(wid(1), beside: wid(2),
                                        edge: .bottom, workspace: 1)
        #expect(inserted)
        let after = copy.tiledFrames(for: 1, in: rect)
        let moved = Set(after.keys.filter { after[$0] != before[$0] })
        // Both reshape: 2 (right half → top half), 1 (left half → bottom).
        #expect(moved == [wid(1), wid(2)])
    }
}
