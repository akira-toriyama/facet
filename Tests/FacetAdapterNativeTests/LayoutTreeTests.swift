import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for the BSP layout tree. No AX, no AppKit — same
/// playbook as `WorkspaceCatalogTests`.
struct LayoutTreeTests {

    // MARK: - Helpers

    /// Convenience rect: wide display by default so auto-balance
    /// picks vertical splits unless we say otherwise.
    private let wideRect = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let tallRect = CGRect(x: 0, y: 0, width: 600, height: 1200)

    // MARK: - Empty / single

    @Test func emptyTreeHasNoLeaves() {
        #expect(LayoutTree().leaves == [])
        #expect(LayoutTree().frames(in: wideRect) == [:])
    }

    @Test func insertIntoEmptyMakesRootLeaf() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        #expect(t.leaves == [wid(1)])
        #expect(t.frames(in: wideRect) == [wid(1): wideRect])
    }

    // MARK: - Auto-balance (Q3 decision)

    @Test func wideRectSecondInsertSplitsVertically() {
        // Wider than tall → vertical split → first window left,
        // new window right; halves of width.
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(1), in: wideRect)
        let f = t.frames(in: wideRect)
        #expect(f[wid(1)]?.origin == CGPoint.zero)
        #expect(f[wid(1)]?.width == 800)
        #expect(f[wid(2)]?.origin == CGPoint(x: 800, y: 0))
        #expect(f[wid(2)]?.width == 800)
        // Heights are unchanged for a vertical split.
        #expect(f[wid(1)]?.height == 900)
        #expect(f[wid(2)]?.height == 900)
    }

    @Test func tallRectSecondInsertSplitsHorizontally() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: tallRect)
        t.insert(wid(2), focused: wid(1), in: tallRect)
        let f = t.frames(in: tallRect)
        #expect(f[wid(1)]?.height == 600)
        #expect(f[wid(2)]?.origin == CGPoint(x: 0, y: 600))
        #expect(f[wid(2)]?.height == 600)
        #expect(f[wid(1)]?.width == 600)
    }

    @Test func newWindowLandsOnRightHalfOfFocused() {
        // Focused window's leaf is split; the NEW id should be on
        // the bottom / right of the split (Q3 frozen choice).
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(1), in: wideRect)
        let f = t.frames(in: wideRect)
        #expect(f[wid(2)]!.origin.x > f[wid(1)]!.origin.x,
                             "new window must land on the right")
    }

    // MARK: - Insertion with no focused match

    @Test func insertWithUnknownFocusedFallsBackToRightmost() {
        // Three insertions with no focused match → each new ID
        // should keep landing as a new rightmost leaf.
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(99), in: wideRect)
        t.insert(wid(3), focused: wid(99), in: wideRect)
        // Rightmost leaf in left-to-right traversal is the
        // last-inserted.
        #expect(t.leaves.last == wid(3))
    }

    // MARK: - Remove + healing

    @Test func removeSiblingAbsorbsSpace() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(1), in: wideRect)
        t.remove(wid(2))
        // wid(1) now occupies the full rect — the split was
        // healed back to a single leaf.
        let f = t.frames(in: wideRect)
        #expect(f == [wid(1): wideRect])
        #expect(t.leaves == [wid(1)])
    }

    @Test func removeDeeplyNestedHealsThroughChain() {
        var t = LayoutTree()
        for n in 1...4 {
            t.insert(wid(n), focused: wid(n - 1), in: wideRect)
        }
        // Drop the rightmost-inserted leaf; its sibling absorbs.
        t.remove(wid(4))
        #expect(!t.contains(wid(4)))
        #expect(t.leaves.count == 3)
    }

    @Test func removeOnlyLeafEmptiesTree() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.remove(wid(1))
        #expect(t.leaves == [])
        #expect(t.frames(in: wideRect) == [:])
    }

    @Test func removeUnknownIDIsNoop() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.remove(wid(99))
        #expect(t.leaves == [wid(1)])
    }

    // MARK: - toggleOrientation

    @Test func toggleOrientationFlipsParentSplit() {
        // Vertical split (wide rect default).
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(1), in: wideRect)
        let before = t.frames(in: wideRect)
        #expect(before[wid(1)]?.width == 800,
                       "starts vertical-split")
        t.toggleOrientation(of: wid(1))
        let after = t.frames(in: wideRect)
        // Now horizontal: same widths, halved heights.
        #expect(after[wid(1)]?.width == 1600)
        #expect(after[wid(1)]?.height == 450)
        #expect(after[wid(2)]?.origin.y == 450)
    }

    @Test func toggleOrientationRootLeafNoop() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.toggleOrientation(of: wid(1))
        // Single leaf → no parent to flip → still the same.
        #expect(t.frames(in: wideRect) == [wid(1): wideRect])
    }

    @Test func toggleOrientationUnknownIDNoop() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.toggleOrientation(of: wid(99))
        #expect(t.leaves == [wid(1)])
    }

    // MARK: - contains

    @Test func containsTrueForInsertedLeaf() {
        var t = LayoutTree()
        t.insert(wid(7), focused: nil, in: wideRect)
        #expect(t.contains(wid(7)))
        #expect(!t.contains(wid(99)))
    }
}
