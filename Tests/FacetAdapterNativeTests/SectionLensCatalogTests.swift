import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure state-machine tests for the section-lens park/restore
/// (`WorkspaceCatalog+SectionLens.swift`, tag-unification Phase 1): a
/// `type="lens"` section becomes a REAL hide within the active workspace —
/// the windows its `match` excludes are anchor-parked + detached so the
/// in-lens windows reclaim the slots. The catalog half is pure (the adapter
/// owns the live-window `match` evaluation and hands the visible-id verdict
/// in), so these tests pass `visibleIDs` directly — no AX / AppKit / OS.
/// Memory: `facet-phase1-lens-realhide-plan`.
final class SectionLensCatalogTests: XCTestCase {

    private var rect: CGRect { CGRect(x: 0, y: 0, width: 1000, height: 800) }

    /// Catalog with windows 10/20/30 adopted into WS1, `mode` applied.
    private func threeWindowCatalog(mode: String) -> WorkspaceCatalog {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: mode, in: rect)
        return c
    }

    // MARK: - applySectionLens park / restore

    func testParksOutOfLensRestoresIntoLens() {
        var c = threeWindowCatalog(mode: "master-left")
        c.activeSectionLens = "Web"
        // Lens shows 10 + 20; 30 is out.
        let park = c.applySectionLens(visibleIDs: [wid(10), wid(20)], in: rect)
        XCTAssertEqual(Set(park.toPark.map(\.id)), [wid(30)])
        XCTAssertTrue(park.toRestore.isEmpty)
        XCTAssertEqual(c.lensParkedMembers, [wid(30)])
        // 30 gave up its tile slot (detached + excluded from the engine order).
        XCTAssertEqual(c.nonFloatingMembers(of: 1), [wid(10), wid(20)])

        // Widen the lens to include 30 again → it restores + re-attaches.
        let back = c.applySectionLens(visibleIDs: [wid(10), wid(20), wid(30)],
                                      in: rect)
        XCTAssertEqual(Set(back.toRestore.map(\.id)), [wid(30)])
        XCTAssertTrue(back.toPark.isEmpty)
        XCTAssertTrue(c.lensParkedMembers.isEmpty)
        XCTAssertEqual(c.nonFloatingMembers(of: 1), [wid(10), wid(20), wid(30)])
    }

    func testApplyIsIdempotent() {
        var c = threeWindowCatalog(mode: "master-left")
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10)], in: rect)
        // Same verdict again → empty plan, no churn.
        let again = c.applySectionLens(visibleIDs: [wid(10)], in: rect)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(c.lensParkedMembers, [wid(20), wid(30)])
    }

    func testEmptyMatchParksEveryone() {
        // D2: a valid match selecting nothing is allowed — the workspace just
        // empties (windows keep their slivers; `--clear` brings them back).
        var c = threeWindowCatalog(mode: "master-left")
        c.activeSectionLens = "None"
        let park = c.applySectionLens(visibleIDs: [], in: rect)
        XCTAssertEqual(Set(park.toPark.map(\.id)), [wid(10), wid(20), wid(30)])
        XCTAssertEqual(c.lensParkedMembers, [wid(10), wid(20), wid(30)])
        XCTAssertTrue(c.nonFloatingMembers(of: 1).isEmpty)
    }

    func testBspParkedWindowLeavesTheTree() {
        var c = threeWindowCatalog(mode: "bsp")
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10), wid(20)], in: rect)
        // bsp tiles from the tree (not `nonFloatingMembers`), so the parked
        // window must be DETACHED — its frame disappears from `tiledFrames`.
        XCTAssertNil(c.tiledFrames(for: 1, in: rect)[wid(30)])
        XCTAssertNotNil(c.tiledFrames(for: 1, in: rect)[wid(10)])
    }

    // MARK: - Exemptions (sticky / stashed / hidden)

    func testStickyWindowIsNeverLensParked() {
        var c = threeWindowCatalog(mode: "master-left")
        c.setSticky(wid(10))                 // pinned across every WS
        c.activeSectionLens = "None"
        let park = c.applySectionLens(visibleIDs: [], in: rect)
        // 10 is park-exempt (sticky); only 20 + 30 park.
        XCTAssertEqual(Set(park.toPark.map(\.id)), [wid(20), wid(30)])
        XCTAssertFalse(c.lensParkedMembers.contains(wid(10)))
    }

    func testStashedWindowIsNeverLensParked() {
        var c = threeWindowCatalog(mode: "master-left")
        _ = c.stashWindow("pad", id: wid(10))   // off-screen on a shelf
        c.activeSectionLens = "None"
        let park = c.applySectionLens(visibleIDs: [], in: rect)
        XCTAssertFalse(Set(park.toPark.map(\.id)).contains(wid(10)))
        XCTAssertFalse(c.lensParkedMembers.contains(wid(10)))
    }

    // MARK: - Active-WS scoping

    func testOnlyActiveWorkspaceMembersAreConsidered() {
        var c = threeWindowCatalog(mode: "master-left")
        _ = c.moveWindow(wid(30), to: 2, in: rect)   // 30 now lives in WS2
        c.activeSectionLens = "None"
        let park = c.applySectionLens(visibleIDs: [], in: rect)
        // Only the active WS (WS1 = 10,20) parks; WS2's 30 is untouched.
        XCTAssertEqual(Set(park.toPark.map(\.id)), [wid(10), wid(20)])
        XCTAssertFalse(c.lensParkedMembers.contains(wid(30)))
    }

    // MARK: - clearSectionLens

    func testClearRestoresEverythingAndDropsTheLens() {
        var c = threeWindowCatalog(mode: "master-left")
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10)], in: rect)
        XCTAssertEqual(c.lensParkedMembers, [wid(20), wid(30)])

        let cleared = c.clearSectionLens(in: rect)
        XCTAssertEqual(Set(cleared.toRestore.map(\.id)), [wid(20), wid(30)])
        XCTAssertTrue(cleared.toPark.isEmpty)
        XCTAssertNil(c.activeSectionLens)
        XCTAssertTrue(c.lensParkedMembers.isEmpty)
        XCTAssertEqual(c.nonFloatingMembers(of: 1), [wid(10), wid(20), wid(30)])
    }

    // MARK: - Lens-aware setActive (D1 net plan)

    func testSwitchRestoresOnlyInLensMembers() {
        var c = threeWindowCatalog(mode: "master-left")
        _ = c.moveWindow(wid(20), to: 2, in: rect)
        _ = c.moveWindow(wid(30), to: 2, in: rect)   // WS1={10}, WS2={20,30}
        c.activeSectionLens = "Web"
        // Switch to WS2 with the lens showing only 20.
        let plan = c.setActive(2, lensVisibleIDs: [wid(20)], in: rect)
        XCTAssertNotNil(plan)
        // toPark = old-WS member (10) + the destination's out-of-lens 30
        // (idempotent park; it stays off-screen). Only 20 (in-lens) restores.
        XCTAssertEqual(Set(plan!.toPark.map(\.id)), [wid(10), wid(30)])
        XCTAssertEqual(Set(plan!.toRestore.map(\.id)), [wid(20)])   // in-lens only
        // 30 is out of the lens → recorded + detached, never restored.
        XCTAssertEqual(c.lensParkedMembers, [wid(30)])
        XCTAssertEqual(c.nonFloatingMembers(of: 2), [wid(20)])
    }

    func testSwitchLiftsLensOffOldWorkspace() {
        var c = threeWindowCatalog(mode: "master-left")   // WS1={10,20,30}
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10)], in: rect)   // park 20,30
        XCTAssertEqual(c.lensParkedMembers, [wid(20), wid(30)])

        // Switch to (empty) WS2: the lens lifts off WS1 (set clears) so an
        // inactive WS's preview is never narrowed by it.
        _ = c.setActive(2, lensVisibleIDs: [], in: rect)
        XCTAssertTrue(c.lensParkedMembers.isEmpty)
        // WS1 (now inactive) shows all its members again in the preview.
        XCTAssertEqual(c.nonFloatingMembers(of: 1), [wid(10), wid(20), wid(30)])
    }

    func testSwitchWithoutLensRestoresAllUnchangedBehaviour() {
        // The lens-unaware wrapper must behave exactly like before.
        var c = threeWindowCatalog(mode: "master-left")
        _ = c.moveWindow(wid(20), to: 2, in: rect)   // WS1={10,30}, WS2={20}
        let plan = c.setActive(2)
        XCTAssertEqual(Set(plan!.toRestore.map(\.id)), [wid(20)])
        XCTAssertTrue(c.lensParkedMembers.isEmpty)
    }

    // MARK: - Snapshot surfaces the lens-park flag (PR4)

    func testSnapshotMarksLensParkedWindows() {
        var c = threeWindowCatalog(mode: "master-left")
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10), wid(20)], in: rect)  // 30 out
        let snap = c.snapshot(live: [window(10), window(20), window(30)],
                              focused: nil, activeRect: rect)
        func parked(_ id: WindowID) -> Bool {
            snap[0].windows.first { $0.id == id }?.isLensParked ?? false
        }
        XCTAssertTrue(parked(wid(30)), "out-of-lens window is flagged lens-parked")
        XCTAssertFalse(parked(wid(10)), "in-lens window is not lens-parked")
        XCTAssertFalse(parked(wid(20)), "in-lens window is not lens-parked")
    }

    func testSnapshotClearsLensParkFlagAfterClear() {
        var c = threeWindowCatalog(mode: "master-left")
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10)], in: rect)
        _ = c.clearSectionLens(in: rect)
        let snap = c.snapshot(live: [window(10), window(20), window(30)],
                              focused: nil, activeRect: rect)
        XCTAssertTrue(snap[0].windows.allSatisfy { !$0.isLensParked },
                      "a cleared lens leaves no window flagged lens-parked")
    }

    func testSnapshotNeverFlagsInactiveWorkspaceWindows() {
        // The lens parks only the ACTIVE WS, so an inactive WS's preview is
        // never narrowed — its windows must read `isLensParked == false`.
        var c = threeWindowCatalog(mode: "master-left")
        _ = c.moveWindow(wid(30), to: 2, in: rect)   // 30 lives on inactive WS2
        c.activeSectionLens = "None"
        _ = c.applySectionLens(visibleIDs: [], in: rect)   // park WS1's 10,20
        let snap = c.snapshot(live: [window(10), window(20), window(30)],
                              focused: nil, activeRect: rect)
        XCTAssertEqual(snap[1].windows.first { $0.id == wid(30) }?.isLensParked,
                       false, "inactive-WS window is never lens-parked")
    }

    // MARK: - forgetWindow cleanup

    func testForgetWindowClearsLensParkState() {
        var c = threeWindowCatalog(mode: "master-left")
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10)], in: rect)
        XCTAssertTrue(c.lensParkedMembers.contains(wid(20)))
        // Window 20 closes (gone from the live list).
        _ = c.reconcile(live: [window(10), window(30)])
        XCTAssertFalse(c.lensParkedMembers.contains(wid(20)))
    }
}
