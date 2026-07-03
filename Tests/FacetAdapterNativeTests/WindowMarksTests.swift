import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for the window-marks bijection in `WorkspaceCatalog`
/// (`facet window --mark` / `--focus-mark`). The cross-workspace jump
/// itself lives in the adapter (needs AX); here we cover the name⇄
/// window mapping, reassignment, and prune-on-close.
struct WindowMarksTests {

    @Test func setAndLookup() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        #expect(c.window(forMark: "a") == wid(1))
        #expect(c.mark(forWindow: wid(1)) == "a")
        #expect(c.window(forMark: "b") == nil)
        #expect(c.mark(forWindow: wid(2)) == nil)
    }

    @Test func nameReassignsToNewWindow() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        c.setMark("a", to: wid(2))            // same name, new window
        #expect(c.window(forMark: "a") == wid(2))
        #expect(c.mark(forWindow: wid(1)) == nil,
                     "the old window must lose the reassigned mark")
        #expect(c.mark(forWindow: wid(2)) == "a")
    }

    @Test func windowHoldsAtMostOneMark() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        c.setMark("b", to: wid(1))            // remark the same window
        #expect(c.mark(forWindow: wid(1)) == "b")
        #expect(c.window(forMark: "a") == nil,
                     "the window's previous name must be cleared")
        #expect(c.window(forMark: "b") == wid(1))
    }

    @Test func bijectionStaysOneToOne() {
        // a→1, b→2, then a→2 must leave only b cleared (b was on 2)
        // and 1 unmarked, with a↔2 the sole surviving pair for win 2.
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        c.setMark("b", to: wid(2))
        c.setMark("a", to: wid(2))
        #expect(c.window(forMark: "a") == wid(2))
        #expect(c.window(forMark: "b") == nil,
                     "win 2's old name 'b' must be cleared")
        #expect(c.mark(forWindow: wid(1)) == nil,
                     "name 'a' left win 1")
        #expect(c.mark(forWindow: wid(2)) == "a")
    }

    @Test func removeMark() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        let removedExisting = c.removeMark("a")
        #expect(removedExisting, "removing an existing mark succeeds")
        #expect(c.window(forMark: "a") == nil)
        #expect(c.mark(forWindow: wid(1)) == nil)
        let removedAbsent = c.removeMark("a")
        #expect(!removedAbsent,
                       "removing an absent mark reports false")
    }

    @Test func markPrunedWhenWindowCloses() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        #expect(c.window(forMark: "a") == wid(1))
        c.drop(wid(1))                        // window closed → forgetWindow
        #expect(c.window(forMark: "a") == nil,
                     "closing the window must prune its mark")
        #expect(c.mark(forWindow: wid(1)) == nil)
    }
}
