import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

// EX-3.1 — nullable `WindowSlot.workspace` foundation. These tests prove the
// catalog is orphan-safe: a window with `workspace == nil` (a 迷子) never
// crashes any catalog op, is excluded from every per-workspace projection, and
// survives workspace mutation untouched — while a normal (workspaced) window's
// behaviour is byte-identical to before. Orphans are injected directly here
// (the public path that CREATES them lands in EX-3.2); at this layer nothing
// else sets nil, so these tests pin the foundation, not new behaviour.
//
// CLT can't run XCTest; CI is the gate (memory feedback-swift-tests-only-compile-in-ci).
final class OrphanWorkspaceTests: XCTestCase {

    /// Inject an orphan (workspace=nil) window directly into the catalog.
    private func makeOrphan(_ c: inout WorkspaceCatalog, _ n: Int, pid: Int = 1000) {
        c.windowMap[wid(n)] = WindowSlot(workspace: nil, pid: pid)
    }

    // MARK: - Snapshot excludes orphans (invisible)

    func testOrphanExcludedFromSnapshot() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // normal window → WS1
        makeOrphan(&c, 99)                          // orphan
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let snap = c.snapshot(live: [window(10), window(99)],
                              focused: nil, activeRect: rect)
        let allShown = Set(snap.flatMap { $0.windows.map(\.id) })
        XCTAssertTrue(allShown.contains(wid(10)), "normal window stays visible")
        XCTAssertFalse(allShown.contains(wid(99)),
                       "orphan is excluded from every workspace in the snapshot")
        // No phantom workspace is emitted for the orphan: exactly the 3 seeded.
        XCTAssertEqual(snap.count, 3)
    }

    // MARK: - Layout ops are no-ops / non-crashing on orphans

    func testToggleOrientationOrphanIsNoOpNoCrash() {
        var c = seededCatalog(2)
        makeOrphan(&c, 99)
        c.toggleOrientation(of: wid(99))           // must not crash (no tree)
        XCTAssertNil(c.windowMap[wid(99)]?.workspace, "orphan stays orphan")
    }

    // MARK: - Workspace mutation leaves orphans untouched

    func testRemoveWorkspaceLeavesOrphanUntouched() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        _ = c.moveWindow(wid(10), to: 2)           // → WS2 so removing WS3 is clean
        makeOrphan(&c, 99)
        XCTAssertTrue(c.removeWorkspace(3))
        XCTAssertNil(c.windowMap[wid(99)]?.workspace,
                     "orphan is not a member of any workspace → untouched by remove")
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 2, "normal window unchanged")
    }

    func testMoveActiveWorkspaceLeavesOrphanUntouched() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        makeOrphan(&c, 99)
        XCTAssertTrue(c.moveActiveWorkspace(to: 3)) // exercises remapIndices
        XCTAssertNil(c.windowMap[wid(99)]?.workspace,
                     "remapIndices skips orphans (position-agnostic)")
    }

    // MARK: - moveWindow un-orphans into a workspace

    func testMoveWindowUnOrphansIntoActiveWorkspaceRestores() {
        var c = seededCatalog(3)                    // active = WS1
        makeOrphan(&c, 99)
        let outcome = c.moveWindow(wid(99), to: 1)  // orphan → active WS
        XCTAssertEqual(c.windowMap[wid(99)]?.workspace, 1,
                       "orphan adopts the destination workspace")
        switch outcome {
        case .restore: break                        // entered the active WS → un-hide
        default: XCTFail("orphan → active WS should .restore, got \(outcome)")
        }
    }

    func testMoveWindowOrphanToInactiveWorkspaceStateOnly() {
        var c = seededCatalog(3)                    // active = WS1
        makeOrphan(&c, 99)
        let outcome = c.moveWindow(wid(99), to: 2)  // orphan → inactive WS
        XCTAssertEqual(c.windowMap[wid(99)]?.workspace, 2)
        switch outcome {
        case .stateOnly: break                      // not the active WS → stays parked
        default: XCTFail("orphan → inactive WS should .stateOnly, got \(outcome)")
        }
    }

    // MARK: - Equality / membership filters exclude orphans

    func testOrphanNotANonFloatingMemberOfAnyWorkspace() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        makeOrphan(&c, 99)
        for ws in 1...3 {
            XCTAssertFalse(c.nonFloatingMembers(of: ws).contains(wid(99)),
                           "orphan is a member of no workspace (\(ws))")
        }
        XCTAssertTrue(c.nonFloatingMembers(of: 1).contains(wid(10)))
    }
}
