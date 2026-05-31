import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Tall ⇄ Wide are now distinct layout engines, not an orientation
/// knob: `flipTallWide` swaps the WS's `layoutModes` entry. The
/// geometry itself is covered by `TallLayoutTests` / `WideLayoutTests`;
/// here we check the mode-swap plumbing.
final class MasterOrientationTests: XCTestCase {

    func testFlipSwapsTallAndWide() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "tall")
        XCTAssertEqual(c.mode(of: 1), "tall")
        XCTAssertTrue(c.flipTallWide(workspace: 1))
        XCTAssertEqual(c.mode(of: 1), "wide")
        XCTAssertTrue(c.flipTallWide(workspace: 1))
        XCTAssertEqual(c.mode(of: 1), "tall")
    }

    func testFlipIsNoOpForOtherModes() {
        var c = WorkspaceCatalog()
        // float (default): no-op.
        XCTAssertFalse(c.flipTallWide(workspace: 1))
        XCTAssertEqual(c.mode(of: 1), "float")
        // bsp: no-op (it has its own --toggle-orientation = split rotate).
        _ = c.setMode(workspace: 2, to: "bsp")
        XCTAssertFalse(c.flipTallWide(workspace: 2))
        XCTAssertEqual(c.mode(of: 2), "bsp")
        // centered: no-op — only tall⇄wide swap.
        _ = c.setMode(workspace: 3, to: "centered")
        XCTAssertFalse(c.flipTallWide(workspace: 3))
        XCTAssertEqual(c.mode(of: 3), "centered")
    }

    func testFlipPreservesMasterKnobs() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "tall")
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)
        _ = c.adjustMasterCount(workspace: 1, delta: 1)
        XCTAssertTrue(c.flipTallWide(workspace: 1))
        XCTAssertEqual(c.mode(of: 1), "wide")
        XCTAssertEqual(c.params(of: 1).masterRatio, 0.6, accuracy: 1e-9,
                       "flipping tall⇄wide must not reset the master ratio")
        XCTAssertEqual(c.params(of: 1).masterCount, 2,
                       "flipping tall⇄wide must not reset the master count")
    }

    func testFlipIsPerWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "tall")
        _ = c.setMode(workspace: 2, to: "tall")
        _ = c.flipTallWide(workspace: 1)
        XCTAssertEqual(c.mode(of: 1), "wide")
        XCTAssertEqual(c.mode(of: 2), "tall",
                       "flipping WS 1 must not touch WS 2")
    }
}
