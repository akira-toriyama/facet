import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// `facet workspace --balance` resets a WS's master knobs to their even
/// baseline. The catalog side is `resetParams`; the geometry is covered
/// by the per-engine layout tests. Here we check the reset plumbing +
/// the "actually changed?" return that lets the adapter skip a re-tile.
final class BalanceParamsTests: XCTestCase {

    func testResetReturnsToDefaults() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "tall")
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.2)
        _ = c.adjustMasterCount(workspace: 1, delta: 2)
        XCTAssertEqual(c.params(of: 1).masterRatio, 0.7, accuracy: 1e-9)
        XCTAssertEqual(c.params(of: 1).masterCount, 3)

        XCTAssertTrue(c.resetParams(workspace: 1),
                      "reset must report a change when knobs were nudged")
        let def = LayoutParams()
        XCTAssertEqual(c.params(of: 1).masterRatio, def.masterRatio,
                       accuracy: 1e-9)
        XCTAssertEqual(c.params(of: 1).masterCount, def.masterCount)
    }

    func testResetIsNoOpAtBaseline() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "tall")
        // Never nudged → already at defaults → no change → skip re-tile.
        XCTAssertFalse(c.resetParams(workspace: 1),
                       "reset at the baseline must report no change")
    }

    func testResetIsNoOpAfterReset() {
        var c = WorkspaceCatalog()
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)
        XCTAssertTrue(c.resetParams(workspace: 1))
        XCTAssertFalse(c.resetParams(workspace: 1),
                       "a second reset has nothing to undo")
    }

    func testResetIsPerWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)
        _ = c.adjustMasterRatio(workspace: 2, delta: 0.1)
        _ = c.resetParams(workspace: 1)
        XCTAssertEqual(c.params(of: 1).masterRatio, LayoutParams().masterRatio,
                       accuracy: 1e-9, "WS 1 reset to baseline")
        XCTAssertEqual(c.params(of: 2).masterRatio, 0.6, accuracy: 1e-9,
                       "resetting WS 1 must not touch WS 2")
    }
}
