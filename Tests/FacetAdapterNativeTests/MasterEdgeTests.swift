import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// M9-2 made the master edges (`master-left` / `-right` / `-top` /
/// `-bottom` / `-center`) distinct layout engines selected directly via
/// `setMode` (`--layout=master-EDGE`); the old `flipTallWide`
/// orientation knob is gone. The geometry is covered by the per-engine
/// `Master*LayoutTests`; here we check the catalog mode-swap plumbing —
/// switching edges keeps the per-WS master knobs and is per-workspace.
struct MasterEdgeTests {

    @Test func switchingEdgePreservesMasterKnobs() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "master-left")
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)
        _ = c.adjustMasterCount(workspace: 1, delta: 1)
        // Switching to another edge changes only the engine; the master
        // knobs are per-WS state and must survive (the M9-2 replacement
        // for flipTallWide's "knobs untouched" guarantee).
        _ = c.setMode(workspace: 1, to: "master-top")
        #expect(c.mode(of: 1) == "master-top")
        #expect(abs(c.params(of: 1).masterRatio - 0.6) < 1e-9,
                       "switching master edge must not reset the master ratio")
        #expect(c.params(of: 1).masterCount == 2,
                       "switching master edge must not reset the master count")
    }

    @Test func modeSwapIsPerWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "master-left")
        _ = c.setMode(workspace: 2, to: "master-left")
        _ = c.setMode(workspace: 1, to: "master-right")
        #expect(c.mode(of: 1) == "master-right")
        #expect(c.mode(of: 2) == "master-left",
                       "changing WS 1's edge must not touch WS 2")
    }

    @Test func allFiveEdgesResolveAsMasterEngines() {
        var c = WorkspaceCatalog()
        let edges = ["master-left", "master-right", "master-top",
                     "master-bottom", "master-center"]
        for (i, mode) in edges.enumerated() {
            _ = c.setMode(workspace: i + 1, to: mode)
            #expect(c.mode(of: i + 1) == mode)
            #expect(LayoutRegistry.engine(named: mode)?.hasMaster == true,
                           "\(mode) should resolve as a master engine")
        }
    }
}
