import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Tests for the runtime, mutable workspace set (A:
/// facet-cli-dynamic-runtime-model) — seed / add / remove / rename /
/// move, plus the index re-keying that keeps per-workspace state
/// aligned as positions shift.
final class DynamicWorkspaceTests: XCTestCase {

    private func seeded(_ n: Int) -> WorkspaceCatalog {
        var c = WorkspaceCatalog()
        c.seed(configs: (1...n).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        return c
    }

    // MARK: - seed

    func testSeedSortsByIndexAndCompacts() {
        var c = WorkspaceCatalog()
        c.seed(configs: [
            (index: 3, config: WorkspaceConfig(name: "c")),
            (index: 1, config: WorkspaceConfig(name: "a")),
            (index: 5, config: WorkspaceConfig(name: "b")),
        ])
        XCTAssertEqual(c.workspaceNames, ["a", "c", "b"])
        XCTAssertEqual(c.workspaceCount, 3)
    }

    func testSeedIsIdempotent() {
        var c = seeded(3)
        c.seed(configs: [(index: 1, config: WorkspaceConfig(name: "x"))])
        XCTAssertEqual(c.workspaceCount, 3)
        XCTAssertEqual(c.workspaceNames, ["", "", ""])
    }

    func testSeedEmptyFallsBackToOne() {
        var c = WorkspaceCatalog()
        c.seed(configs: [])
        XCTAssertEqual(c.workspaceCount, 1)
    }

    func testSeedAppliesPerWSLayoutAtCompactedPosition() {
        var c = WorkspaceCatalog()
        c.defaultMode = "float"
        // Sparse: indices 1, 3, 5 → compact to positions 1, 2, 3.
        // WS at original idx 3 (position 2) gets "bsp".
        c.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "a", layout: nil)),
            (index: 3, config: WorkspaceConfig(name: "b", layout: "bsp")),
            (index: 5, config: WorkspaceConfig(name: "c", layout: "stack")),
        ])
        XCTAssertEqual(c.mode(of: 1), "float", "no layout → default")
        XCTAssertEqual(c.mode(of: 2), "bsp",
                       "config layout applied at compacted position")
        XCTAssertEqual(c.mode(of: 3), "stack")
    }

    // MARK: - add / rename / name lookup

    func testAddAppendsUnnamed() {
        var c = seeded(2)
        let pos = c.addWorkspace()
        XCTAssertEqual(pos, 3)
        XCTAssertEqual(c.workspaceCount, 3)
        XCTAssertEqual(c.workspaceNames[2], "")
    }

    func testRenameAndIndexOfName() {
        var c = seeded(3)
        c.renameWorkspace(2, to: "build")
        XCTAssertEqual(c.workspaceNames[1], "build")
        XCTAssertEqual(c.index(ofName: "build"), 2)
        XCTAssertNil(c.index(ofName: "nope"))
        XCTAssertNil(c.index(ofName: ""),
                     "empty name is the unnamed sentinel, never matched")
    }

    // MARK: - remove

    func testRemoveLastWorkspaceRejected() {
        var c = seeded(1)
        XCTAssertFalse(c.removeWorkspace(1))
        XCTAssertEqual(c.workspaceCount, 1)
    }

    func testRemoveEvacuatesWindowsToNeighbour() {
        var c = seeded(3)
        _ = c.reconcile(live: [window(10)])   // 10 in WS1 (active)
        _ = c.moveWindow(wid(10), to: 2)      // 10 now in WS2
        XCTAssertTrue(c.removeWorkspace(2))
        XCTAssertEqual(c.workspaceCount, 2)
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1,
                       "evacuated to neighbour WS1, not lost")
    }

    func testRemoveFirstEvacuatesToNextAndActiveFollows() {
        var c = seeded(3)
        _ = c.reconcile(live: [window(10)])   // 10 in WS1, active 1
        XCTAssertTrue(c.removeWorkspace(1))
        XCTAssertEqual(c.workspaceCount, 2)
        // Old WS2 becomes new WS1 and absorbs the evacuee; active
        // follows there.
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1)
        XCTAssertEqual(c.activeIndex, 1)
    }

    func testRemoveShiftsHigherWorkspacesDownAndRekeysState() {
        var c = seeded(3)
        _ = c.reconcile(live: [window(10)])   // WS1
        _ = c.moveWindow(wid(10), to: 3)      // 10 in WS3
        _ = c.setMode(workspace: 3, to: "bsp")
        XCTAssertTrue(c.removeWorkspace(2))   // WS3 -> WS2
        XCTAssertEqual(c.workspaceCount, 2)
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 2,
                       "window's workspace re-keyed 3 -> 2")
        XCTAssertEqual(c.mode(of: 2), "bsp",
                       "layout mode re-keyed 3 -> 2")
    }

    // MARK: - move (reorder)

    func testMoveActiveReordersNamesAndFollows() {
        var c = seeded(3)
        _ = c.reconcile(live: [window(10)])   // 10 in WS1, active 1
        c.renameWorkspace(1, to: "dev")
        XCTAssertTrue(c.moveActiveWorkspace(to: 3))
        XCTAssertEqual(c.activeIndex, 3, "active follows the moved WS")
        XCTAssertEqual(c.workspaceNames[2], "dev")
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 3,
                       "the window's workspace moved to position 3")
        // The two workspaces it jumped over shifted down.
        XCTAssertEqual(c.workspaceNames, ["", "", "dev"])
    }

    func testMoveRejectsOutOfRangeOrUnchanged() {
        var c = seeded(3)
        XCTAssertFalse(c.moveActiveWorkspace(to: 1), "already there")
        XCTAssertFalse(c.moveActiveWorkspace(to: 4), "out of range")
        XCTAssertFalse(c.moveActiveWorkspace(to: 0))
    }
}
