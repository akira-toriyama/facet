import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for whole-tree `rotate` / `mirror` (`facet workspace
/// --rotate` / `--mirror`). No AX / AppKit — same playbook as
/// `LayoutTreeTests`. A 2-window vertical split is the canonical case:
/// wid(1) left, wid(2) right on a 1600×900 rect.
final class RotateMirrorTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)

    /// wid(1) | wid(2) side by side (vertical split, halves of width).
    private func twoVertical() -> LayoutTree {
        var t = LayoutTree()
        t.insert(wid(1), focused: nil, in: rect)
        t.insert(wid(2), focused: wid(1), in: rect)
        return t
    }

    // MARK: - rotate

    func testRotate90TurnsLeftRightIntoTopBottom() {
        var t = twoVertical()
        t.rotate(degrees: 90)        // clockwise: left → top
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 0, width: 1600, height: 450))
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 450, width: 1600, height: 450))
    }

    func testRotate180ReversesOrderSameOrientation() {
        var t = twoVertical()
        t.rotate(degrees: 180)       // still left|right, but swapped
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 0, width: 800, height: 900))
        XCTAssertEqual(f[wid(1)], CGRect(x: 800, y: 0, width: 800, height: 900))
    }

    func testRotate270TurnsLeftRightIntoBottomTop() {
        var t = twoVertical()
        t.rotate(degrees: 270)       // counter-clockwise equivalent
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 0, width: 1600, height: 450))
        XCTAssertEqual(f[wid(1)], CGRect(x: 0, y: 450, width: 1600, height: 450))
    }

    func testRotate360IsIdentity() {
        let t0 = twoVertical()
        var t = t0
        t.rotate(degrees: 90)
        t.rotate(degrees: 90)
        t.rotate(degrees: 90)
        t.rotate(degrees: 90)
        XCTAssertEqual(t, t0, "four 90° steps return to the original tree")
    }

    func testRotateNonMultipleOf90IsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.rotate(degrees: 45)
        XCTAssertEqual(t, t0)
    }

    func testRotateEmptyTreeIsNoOp() {
        var t = LayoutTree()
        t.rotate(degrees: 90)
        XCTAssertEqual(t.leaves, [])
    }

    // MARK: - mirror

    func testMirrorHorizontalSwapsLeftRight() {
        var t = twoVertical()
        t.mirror(.horizontal)        // reflect left↔right
        let f = t.frames(in: rect)
        XCTAssertEqual(f[wid(2)], CGRect(x: 0, y: 0, width: 800, height: 900))
        XCTAssertEqual(f[wid(1)], CGRect(x: 800, y: 0, width: 800, height: 900))
    }

    func testMirrorVerticalIsNoOpOnLeftRightSplit() {
        // A vertical (left|right) split has nothing to flip top↔bottom.
        let t0 = twoVertical()
        var t = t0
        t.mirror(.vertical)
        XCTAssertEqual(t, t0)
    }

    func testMirrorHorizontalIsInvolution() {
        let t0 = twoVertical()
        var t = t0
        t.mirror(.horizontal)
        t.mirror(.horizontal)
        XCTAssertEqual(t, t0, "mirroring twice across the same axis is identity")
    }

    // MARK: - catalog wrapper (bsp-only guard)

    func testCatalogRotateNoOpOutsideBsp() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "master-left")
        XCTAssertFalse(c.rotateTree(workspace: 1, degrees: 90),
                       "rotate only applies to bsp mode")
        XCTAssertFalse(c.mirrorTree(workspace: 1, axis: .horizontal),
                       "mirror only applies to bsp mode")
    }

    func testCatalogRotateNoOpWhenNoTree() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "bsp")   // bsp but no windows yet
        XCTAssertFalse(c.rotateTree(workspace: 1, degrees: 90),
                       "empty bsp tree → unchanged → no reflow")
    }
}
