import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for whole-tree `rotate` / `mirror` (`facet workspace
/// --rotate` / `--mirror`). No AX / AppKit — same playbook as
/// `LayoutTreeTests`. A 2-window vertical split is the canonical case:
/// wid(1) left, wid(2) right on a 1600×900 rect.
struct RotateMirrorTests {

    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)

    // MARK: - rotate

    @Test func rotate90TurnsLeftRightIntoTopBottom() {
        var t = twoVertical()
        t.rotate(degrees: 90)        // clockwise: left → top
        let f = t.frames(in: rect)
        #expect(f[wid(1)] == CGRect(x: 0, y: 0, width: 1600, height: 450))
        #expect(f[wid(2)] == CGRect(x: 0, y: 450, width: 1600, height: 450))
    }

    @Test func rotate180ReversesOrderSameOrientation() {
        var t = twoVertical()
        t.rotate(degrees: 180)       // still left|right, but swapped
        let f = t.frames(in: rect)
        #expect(f[wid(2)] == CGRect(x: 0, y: 0, width: 800, height: 900))
        #expect(f[wid(1)] == CGRect(x: 800, y: 0, width: 800, height: 900))
    }

    @Test func rotate270TurnsLeftRightIntoBottomTop() {
        var t = twoVertical()
        t.rotate(degrees: 270)       // counter-clockwise equivalent
        let f = t.frames(in: rect)
        #expect(f[wid(2)] == CGRect(x: 0, y: 0, width: 1600, height: 450))
        #expect(f[wid(1)] == CGRect(x: 0, y: 450, width: 1600, height: 450))
    }

    @Test func rotate360IsIdentity() {
        let t0 = twoVertical()
        var t = t0
        t.rotate(degrees: 90)
        t.rotate(degrees: 90)
        t.rotate(degrees: 90)
        t.rotate(degrees: 90)
        #expect(t == t0, "four 90° steps return to the original tree")
    }

    @Test func rotateNonMultipleOf90IsNoOp() {
        let t0 = twoVertical()
        var t = t0
        t.rotate(degrees: 45)
        #expect(t == t0)
    }

    @Test func rotateEmptyTreeIsNoOp() {
        var t = LayoutTree()
        t.rotate(degrees: 90)
        #expect(t.leaves == [])
    }

    // MARK: - mirror

    @Test func mirrorHorizontalSwapsLeftRight() {
        var t = twoVertical()
        t.mirror(.horizontal)        // reflect left↔right
        let f = t.frames(in: rect)
        #expect(f[wid(2)] == CGRect(x: 0, y: 0, width: 800, height: 900))
        #expect(f[wid(1)] == CGRect(x: 800, y: 0, width: 800, height: 900))
    }

    @Test func mirrorVerticalIsNoOpOnLeftRightSplit() {
        // A vertical (left|right) split has nothing to flip top↔bottom.
        let t0 = twoVertical()
        var t = t0
        t.mirror(.vertical)
        #expect(t == t0)
    }

    @Test func mirrorHorizontalIsInvolution() {
        let t0 = twoVertical()
        var t = t0
        t.mirror(.horizontal)
        t.mirror(.horizontal)
        #expect(t == t0, "mirroring twice across the same axis is identity")
    }

    // MARK: - catalog wrapper (bsp-only guard)

    @Test func catalogRotateNoOpOutsideBsp() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "master-left")
        let rotated = c.rotateTree(workspace: 1, degrees: 90)
        #expect(!rotated,
                       "rotate only applies to bsp mode")
        let mirrored = c.mirrorTree(workspace: 1, axis: .horizontal)
        #expect(!mirrored,
                       "mirror only applies to bsp mode")
    }

    @Test func catalogRotateNoOpWhenNoTree() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "bsp")   // bsp but no windows yet
        let rotated = c.rotateTree(workspace: 1, degrees: 90)
        #expect(!rotated,
                       "empty bsp tree → unchanged → no reflow")
    }
}
