import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for the BSP layout tree. No AX, no AppKit — same
/// playbook as `WorkspaceCatalogTests`.
final class LayoutTreeTests: XCTestCase {

    // MARK: - Helpers

    private func wid(_ n: Int) -> WindowID {
        WindowID(serverID: n)
    }

    /// Convenience rect: wide display by default so auto-balance
    /// picks vertical splits unless we say otherwise.
    private let wideRect = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let tallRect = CGRect(x: 0, y: 0, width: 600, height: 1200)

    // MARK: - Empty / single

    func testEmptyTreeHasNoLeaves() {
        XCTAssertEqual(LayoutTree().leaves, [])
        XCTAssertEqual(LayoutTree().frames(in: wideRect), [:])
    }

    func testInsertIntoEmptyMakesRootLeaf() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        XCTAssertEqual(t.leaves, [wid(1)])
        XCTAssertEqual(t.frames(in: wideRect), [wid(1): wideRect])
    }

    // MARK: - Auto-balance (Q3 decision)

    func testWideRectSecondInsertSplitsVertically() {
        // Wider than tall → vertical split → first window left,
        // new window right; halves of width.
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(1), in: wideRect)
        let f = t.frames(in: wideRect)
        XCTAssertEqual(f[wid(1)]?.origin, CGPoint.zero)
        XCTAssertEqual(f[wid(1)]?.width, 800)
        XCTAssertEqual(f[wid(2)]?.origin, CGPoint(x: 800, y: 0))
        XCTAssertEqual(f[wid(2)]?.width, 800)
        // Heights are unchanged for a vertical split.
        XCTAssertEqual(f[wid(1)]?.height, 900)
        XCTAssertEqual(f[wid(2)]?.height, 900)
    }

    func testTallRectSecondInsertSplitsHorizontally() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: tallRect)
        t.insert(wid(2), focused: wid(1), in: tallRect)
        let f = t.frames(in: tallRect)
        XCTAssertEqual(f[wid(1)]?.height, 600)
        XCTAssertEqual(f[wid(2)]?.origin, CGPoint(x: 0, y: 600))
        XCTAssertEqual(f[wid(2)]?.height, 600)
        XCTAssertEqual(f[wid(1)]?.width, 600)
    }

    func testNewWindowLandsOnRightHalfOfFocused() {
        // Focused window's leaf is split; the NEW id should be on
        // the bottom / right of the split (Q3 frozen choice).
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(1), in: wideRect)
        let f = t.frames(in: wideRect)
        XCTAssertGreaterThan(f[wid(2)]!.origin.x, f[wid(1)]!.origin.x,
                             "new window must land on the right")
    }

    // MARK: - Insertion with no focused match

    func testInsertWithUnknownFocusedFallsBackToRightmost() {
        // Three insertions with no focused match → each new ID
        // should keep landing as a new rightmost leaf.
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(99), in: wideRect)
        t.insert(wid(3), focused: wid(99), in: wideRect)
        // Rightmost leaf in left-to-right traversal is the
        // last-inserted.
        XCTAssertEqual(t.leaves.last, wid(3))
    }

    // MARK: - Remove + healing

    func testRemoveSiblingAbsorbsSpace() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(1), in: wideRect)
        t.remove(wid(2))
        // wid(1) now occupies the full rect — the split was
        // healed back to a single leaf.
        let f = t.frames(in: wideRect)
        XCTAssertEqual(f, [wid(1): wideRect])
        XCTAssertEqual(t.leaves, [wid(1)])
    }

    func testRemoveDeeplyNestedHealsThroughChain() {
        var t = LayoutTree()
        for n in 1...4 {
            t.insert(wid(n), focused: wid(n - 1), in: wideRect)
        }
        // Drop the rightmost-inserted leaf; its sibling absorbs.
        t.remove(wid(4))
        XCTAssertFalse(t.contains(wid(4)))
        XCTAssertEqual(t.leaves.count, 3)
    }

    func testRemoveOnlyLeafEmptiesTree() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.remove(wid(1))
        XCTAssertEqual(t.leaves, [])
        XCTAssertEqual(t.frames(in: wideRect), [:])
    }

    func testRemoveUnknownIDIsNoop() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.remove(wid(99))
        XCTAssertEqual(t.leaves, [wid(1)])
    }

    // MARK: - toggleOrientation

    func testToggleOrientationFlipsParentSplit() {
        // Vertical split (wide rect default).
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.insert(wid(2), focused: wid(1), in: wideRect)
        let before = t.frames(in: wideRect)
        XCTAssertEqual(before[wid(1)]?.width, 800,
                       "starts vertical-split")
        t.toggleOrientation(of: wid(1))
        let after = t.frames(in: wideRect)
        // Now horizontal: same widths, halved heights.
        XCTAssertEqual(after[wid(1)]?.width, 1600)
        XCTAssertEqual(after[wid(1)]?.height, 450)
        XCTAssertEqual(after[wid(2)]?.origin.y, 450)
    }

    func testToggleOrientationRootLeafNoop() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.toggleOrientation(of: wid(1))
        // Single leaf → no parent to flip → still the same.
        XCTAssertEqual(t.frames(in: wideRect), [wid(1): wideRect])
    }

    func testToggleOrientationUnknownIDNoop() {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: wideRect)
        t.toggleOrientation(of: wid(99))
        XCTAssertEqual(t.leaves, [wid(1)])
    }

    // MARK: - contains

    func testContainsTrueForInsertedLeaf() {
        var t = LayoutTree()
        t.insert(wid(7), focused: nil, in: wideRect)
        XCTAssertTrue(t.contains(wid(7)))
        XCTAssertFalse(t.contains(wid(99)))
    }
}
