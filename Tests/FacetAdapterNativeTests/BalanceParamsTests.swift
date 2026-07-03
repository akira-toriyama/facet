import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// `facet workspace --balance` resets a WS's master knobs to their even
/// baseline. The catalog side is `resetParams`; the geometry is covered
/// by the per-engine layout tests. Here we check the reset plumbing +
/// the "actually changed?" return that lets the adapter skip a re-tile.
struct BalanceParamsTests {

    @Test func resetReturnsToDefaults() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "master-left")
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.2)
        _ = c.adjustMasterCount(workspace: 1, delta: 2)
        #expect(abs(c.params(of: 1).masterRatio - 0.7) < 1e-9)
        #expect(c.params(of: 1).masterCount == 3)

        let reset = c.resetParams(workspace: 1)
        #expect(reset,
                      "reset must report a change when knobs were nudged")
        let def = LayoutParams()
        #expect(abs(c.params(of: 1).masterRatio - def.masterRatio) < 1e-9)
        #expect(c.params(of: 1).masterCount == def.masterCount)
    }

    @Test func resetIsNoOpAtBaseline() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "master-left")
        // Never nudged → already at defaults → no change → skip re-tile.
        let reset = c.resetParams(workspace: 1)
        #expect(!reset,
                       "reset at the baseline must report no change")
    }

    @Test func resetIsNoOpAfterReset() {
        var c = WorkspaceCatalog()
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)
        let reset = c.resetParams(workspace: 1)
        #expect(reset)
        let resetAgain = c.resetParams(workspace: 1)
        #expect(!resetAgain,
                       "a second reset has nothing to undo")
    }

    @Test func resetIsPerWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)
        _ = c.adjustMasterRatio(workspace: 2, delta: 0.1)
        _ = c.resetParams(workspace: 1)
        #expect(abs(c.params(of: 1).masterRatio - LayoutParams().masterRatio) < 1e-9,
                       "WS 1 reset to baseline")
        #expect(abs(c.params(of: 2).masterRatio - 0.6) < 1e-9,
                       "resetting WS 1 must not touch WS 2")
    }
}
