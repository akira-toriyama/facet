import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// M9-2 made the master edges (`master-left` / `-right` / `-top` /
/// `-bottom` / `-center`) distinct layout engines selected directly via
/// `setMode` (`--layout=master-EDGE`); the old `flipTallWide`
/// orientation knob is gone. The geometry is covered by the per-engine
/// `Master*LayoutTests`; here we check the catalog mode-swap plumbing —
/// switching edges keeps the per-WS master knobs and is per-workspace.
final class MasterEdgeTests: XCTestCase {

    func testSwitchingEdgePreservesMasterKnobs() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "master-left")
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)
        _ = c.adjustMasterCount(workspace: 1, delta: 1)
        // Switching to another edge changes only the engine; the master
        // knobs are per-WS state and must survive (the M9-2 replacement
        // for flipTallWide's "knobs untouched" guarantee).
        _ = c.setMode(workspace: 1, to: "master-top")
        XCTAssertEqual(c.mode(of: 1), "master-top")
        XCTAssertEqual(c.params(of: 1).masterRatio, 0.6, accuracy: 1e-9,
                       "switching master edge must not reset the master ratio")
        XCTAssertEqual(c.params(of: 1).masterCount, 2,
                       "switching master edge must not reset the master count")
    }

    func testModeSwapIsPerWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "master-left")
        _ = c.setMode(workspace: 2, to: "master-left")
        _ = c.setMode(workspace: 1, to: "master-right")
        XCTAssertEqual(c.mode(of: 1), "master-right")
        XCTAssertEqual(c.mode(of: 2), "master-left",
                       "changing WS 1's edge must not touch WS 2")
    }

    func testAllFiveEdgesResolveAsMasterEngines() {
        var c = WorkspaceCatalog()
        let edges = ["master-left", "master-right", "master-top",
                     "master-bottom", "master-center"]
        for (i, mode) in edges.enumerated() {
            _ = c.setMode(workspace: i + 1, to: mode)
            XCTAssertEqual(c.mode(of: i + 1), mode)
            XCTAssertEqual(LayoutRegistry.engine(named: mode)?.hasMaster, true,
                           "\(mode) should resolve as a master engine")
        }
    }
}
