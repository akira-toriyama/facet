import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for the window-marks bijection in `WorkspaceCatalog`
/// (`facet window --mark` / `--focus-mark`). The cross-workspace jump
/// itself lives in the adapter (needs AX); here we cover the name⇄
/// window mapping, reassignment, and prune-on-close.
final class WindowMarksTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }

    func testSetAndLookup() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        XCTAssertEqual(c.window(forMark: "a"), wid(1))
        XCTAssertEqual(c.mark(forWindow: wid(1)), "a")
        XCTAssertNil(c.window(forMark: "b"))
        XCTAssertNil(c.mark(forWindow: wid(2)))
    }

    func testNameReassignsToNewWindow() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        c.setMark("a", to: wid(2))            // same name, new window
        XCTAssertEqual(c.window(forMark: "a"), wid(2))
        XCTAssertNil(c.mark(forWindow: wid(1)),
                     "the old window must lose the reassigned mark")
        XCTAssertEqual(c.mark(forWindow: wid(2)), "a")
    }

    func testWindowHoldsAtMostOneMark() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        c.setMark("b", to: wid(1))            // remark the same window
        XCTAssertEqual(c.mark(forWindow: wid(1)), "b")
        XCTAssertNil(c.window(forMark: "a"),
                     "the window's previous name must be cleared")
        XCTAssertEqual(c.window(forMark: "b"), wid(1))
    }

    func testBijectionStaysOneToOne() {
        // a→1, b→2, then a→2 must leave only b cleared (b was on 2)
        // and 1 unmarked, with a↔2 the sole surviving pair for win 2.
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        c.setMark("b", to: wid(2))
        c.setMark("a", to: wid(2))
        XCTAssertEqual(c.window(forMark: "a"), wid(2))
        XCTAssertNil(c.window(forMark: "b"),
                     "win 2's old name 'b' must be cleared")
        XCTAssertNil(c.mark(forWindow: wid(1)),
                     "name 'a' left win 1")
        XCTAssertEqual(c.mark(forWindow: wid(2)), "a")
    }

    func testMarkPrunedWhenWindowCloses() {
        var c = WorkspaceCatalog()
        c.setMark("a", to: wid(1))
        XCTAssertEqual(c.window(forMark: "a"), wid(1))
        c.drop(wid(1))                        // window closed → forgetWindow
        XCTAssertNil(c.window(forMark: "a"),
                     "closing the window must prune its mark")
        XCTAssertNil(c.mark(forWindow: wid(1)))
    }
}
