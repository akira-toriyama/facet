import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Tests for the runtime, mutable workspace set (A:
/// facet-cli-dynamic-runtime-model) — seed / add / remove / rename /
/// move, plus the index re-keying that keeps per-workspace state
/// aligned as positions shift.
struct DynamicWorkspaceTests {

    private func seeded(_ n: Int) -> WorkspaceCatalog {
        var c = WorkspaceCatalog()
        c.seed(configs: (1...n).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        return c
    }

    // MARK: - seed

    @Test func seedSortsByIndexAndCompacts() {
        var c = WorkspaceCatalog()
        c.seed(configs: [
            (index: 3, config: WorkspaceConfig(name: "c")),
            (index: 1, config: WorkspaceConfig(name: "a")),
            (index: 5, config: WorkspaceConfig(name: "b")),
        ])
        #expect(c.workspaceNames == ["a", "c", "b"])
        #expect(c.workspaceCount == 3)
    }

    @Test func seedIsIdempotent() {
        var c = seeded(3)
        c.seed(configs: [(index: 1, config: WorkspaceConfig(name: "x"))])
        #expect(c.workspaceCount == 3)
        #expect(c.workspaceNames == ["", "", ""])
    }

    @Test func seedEmptyFallsBackToOne() {
        var c = WorkspaceCatalog()
        c.seed(configs: [])
        #expect(c.workspaceCount == 1)
    }

    @Test func seedAppliesPerWSLayoutAtCompactedPosition() {
        var c = WorkspaceCatalog()
        c.defaultMode = "float"
        // Sparse: indices 1, 3, 5 → compact to positions 1, 2, 3.
        // WS at original idx 3 (position 2) gets "bsp".
        c.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "a", layout: nil)),
            (index: 3, config: WorkspaceConfig(name: "b", layout: "bsp")),
            (index: 5, config: WorkspaceConfig(name: "c", layout: "stack")),
        ])
        #expect(c.mode(of: 1) == "float", "no layout → default")
        #expect(c.mode(of: 2) == "bsp",
                       "config layout applied at compacted position")
        #expect(c.mode(of: 3) == "stack")
    }

    // MARK: - add / rename / name lookup

    @Test func addAppendsUnnamed() {
        var c = seeded(2)
        let pos = c.addWorkspace()
        #expect(pos == 3)
        #expect(c.workspaceCount == 3)
        #expect(c.workspaceNames[2] == "")
    }

    @Test func renameAndIndexOfName() {
        var c = seeded(3)
        c.renameWorkspace(2, to: "build")
        #expect(c.workspaceNames[1] == "build")
        #expect(c.index(ofName: "build") == 2)
        #expect(c.index(ofName: "nope") == nil)
        #expect(c.index(ofName: "") == nil,
                     "empty name is the unnamed sentinel, never matched")
    }

    // MARK: - remove

    @Test func removeLastWorkspaceRejected() {
        var c = seeded(1)
        let removed = c.removeWorkspace(1)
        #expect(!removed)
        #expect(c.workspaceCount == 1)
    }

    @Test func removeEvacuatesWindowsToNeighbour() {
        var c = seeded(3)
        _ = c.reconcile(live: [window(10)])   // 10 in WS1 (active)
        _ = c.moveWindow(wid(10), to: 2)      // 10 now in WS2
        let removed = c.removeWorkspace(2)
        #expect(removed)
        #expect(c.workspaceCount == 2)
        #expect(c.windowMap[wid(10)]?.workspace == 1,
                       "evacuated to neighbour WS1, not lost")
    }

    @Test func removeFirstEvacuatesToNextAndActiveFollows() {
        var c = seeded(3)
        _ = c.reconcile(live: [window(10)])   // 10 in WS1, active 1
        let removed = c.removeWorkspace(1)
        #expect(removed)
        #expect(c.workspaceCount == 2)
        // Old WS2 becomes new WS1 and absorbs the evacuee; active
        // follows there.
        #expect(c.windowMap[wid(10)]?.workspace == 1)
        #expect(c.activeIndex == 1)
    }

    @Test func removeShiftsHigherWorkspacesDownAndRekeysState() {
        var c = seeded(3)
        _ = c.reconcile(live: [window(10)])   // WS1
        _ = c.moveWindow(wid(10), to: 3)      // 10 in WS3
        _ = c.setMode(workspace: 3, to: "bsp")
        let removed = c.removeWorkspace(2)
        #expect(removed)   // WS3 -> WS2
        #expect(c.workspaceCount == 2)
        #expect(c.windowMap[wid(10)]?.workspace == 2,
                       "window's workspace re-keyed 3 -> 2")
        #expect(c.mode(of: 2) == "bsp",
                       "layout mode re-keyed 3 -> 2")
    }

    // MARK: - move (reorder)

    @Test func moveActiveReordersNamesAndFollows() {
        var c = seeded(3)
        _ = c.reconcile(live: [window(10)])   // 10 in WS1, active 1
        c.renameWorkspace(1, to: "dev")
        let moved = c.moveActiveWorkspace(to: 3)
        #expect(moved)
        #expect(c.activeIndex == 3, "active follows the moved WS")
        #expect(c.workspaceNames[2] == "dev")
        #expect(c.windowMap[wid(10)]?.workspace == 3,
                       "the window's workspace moved to position 3")
        // The two workspaces it jumped over shifted down.
        #expect(c.workspaceNames == ["", "", "dev"])
    }

    @Test func moveRejectsOutOfRangeOrUnchanged() {
        var c = seeded(3)
        let movedToOne = c.moveActiveWorkspace(to: 1)
        #expect(!movedToOne, "already there")
        let movedToFour = c.moveActiveWorkspace(to: 4)
        #expect(!movedToFour, "out of range")
        let movedToZero = c.moveActiveWorkspace(to: 0)
        #expect(!movedToZero)
    }
}
