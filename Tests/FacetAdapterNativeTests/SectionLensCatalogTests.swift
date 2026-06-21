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

    // MARK: - Cross-workspace scoping (EX-1 exclusive model)

    /// EX-1: the lens now parks windows in ALL workspaces, not just the active
    /// one. Window B in WS2 (inactive) must be parked when it does not match
    /// the lens, even though the active workspace is WS1.
    func testApplySectionLensParksAcrossWorkspaces() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "master-left", in: rect)
        _ = c.moveWindow(wid(20), to: 2, in: rect)   // A=wid(10) WS1 active, B=wid(20) WS2
        c.activeSectionLens = "Web"
        let plan = c.applySectionLens(visibleIDs: [wid(10)], in: rect)
        // B (wid 20) lives in inactive WS2 but must still park.
        XCTAssertTrue(plan.toPark.map(\.id).contains(wid(20)),
                      "inactive-WS window must park under EX-1 cross-workspace lens")
        XCTAssertTrue(c.lensParkedMembers.contains(wid(20)),
                      "lensParkedMembers must include the inactive-WS window")
    }

    /// EX-1 restore: a lens-parked window from WS2 must re-attach to WS2's
    /// layout (not the active WS1) when it re-enters the lens.
    ///
    /// Asserts on the per-workspace bsp TREE via `tiledFrames`, because that is
    /// the container `attachToLayout(workspace:)` actually writes — keyed on the
    /// passed workspace. `nonFloatingMembers` would NOT catch the bug: it is a
    /// pure `windowMap` filter (`workspace == n && !lensParkedMembers`) that
    /// never reads the layout containers, so it reads identically whether the
    /// restore re-attaches to WS2 or WS1. With bsp, a window re-attached to the
    /// WRONG workspace lands in that workspace's tree and is ABSENT from its
    /// home tree — so the two `tiledFrames` assertions go red if the restore
    /// branch uses `activeIndex` (WS1) instead of `slot.workspace` (WS2).
    func testApplySectionLensRestoresWindowToHomeWorkspace() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)
        _ = c.setMode(workspace: 2, to: "bsp", in: rect)
        _ = c.moveWindow(wid(20), to: 2, in: rect)   // wid(10)=WS1, wid(20)=WS2
        c.activeSectionLens = "Web"
        // Park wid(20) — it doesn't match the lens initially → detached from
        // WS2's tree.
        _ = c.applySectionLens(visibleIDs: [wid(10)], in: rect)
        XCTAssertTrue(c.lensParkedMembers.contains(wid(20)), "precondition: wid(20) is parked")
        XCTAssertNil(c.tiledFrames(for: 2, in: rect)[wid(20)],
                     "precondition: wid(20) detached from WS2's tree")
        // Now widen the lens to include wid(20) — it should restore to WS2.
        let restore = c.applySectionLens(visibleIDs: [wid(10), wid(20)], in: rect)
        XCTAssertTrue(restore.toRestore.map(\.id).contains(wid(20)),
                      "wid(20) must be in the restore plan")
        XCTAssertFalse(c.lensParkedMembers.contains(wid(20)),
                       "wid(20) must leave lensParkedMembers after restore")
        // The critical, red-on-regression assertions: wid(20) re-attaches to
        // WS2's tree (its home), and is absent from WS1's. The `activeIndex`
        // bug would invert both.
        XCTAssertNotNil(c.tiledFrames(for: 2, in: rect)[wid(20)],
                        "wid(20) must re-attach to its home WS2 tree, not WS1")
        XCTAssertNil(c.tiledFrames(for: 1, in: rect)[wid(20)],
                     "wid(20) must NOT appear in WS1's tree after restore")
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

    // MARK: - Exclusive setActive (EX-0.4: workspace switch always clears the lens)

    /// EX-0.4: switching workspace clears the active section-lens — the
    /// `activeSectionLens` and `activeSectionLensLayout` fields are nil after
    /// the switch, and `lensParkedMembers` is empty.
    ///
    /// Red-on-regression: if the lens-clear were removed (e.g. by reverting
    /// to the old D1 re-compose path) `activeSectionLens` would remain "Web"
    /// after the switch and the first assertion would fail immediately.
    func testSwitchClearsActiveLens() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "master-left", in: rect)
        _ = c.moveWindow(wid(20), to: 2, in: rect)
        _ = c.moveWindow(wid(30), to: 2, in: rect)   // WS1={10}, WS2={20,30}
        // applySectionLens spans all workspaces, so wid(20)/wid(30) in inactive
        // WS2 are parked — lensParkedMembers is non-empty going into the switch.
        c.activeSectionLens = "Web"
        c.activeSectionLensLayout = "grid"          // EX-0.3 runtime override
        _ = c.applySectionLens(visibleIDs: [wid(10)], in: rect)   // parks 20+30
        XCTAssertFalse(c.lensParkedMembers.isEmpty, "precondition: lens is applied")

        // Switch to WS2 — must clear the lens.
        let plan = c.setActive(2, in: rect)
        XCTAssertNotNil(plan)
        // Lens fields are cleared.
        XCTAssertNil(c.activeSectionLens,
                     "activeSectionLens must be nil after a workspace switch (exclusive model)")
        XCTAssertNil(c.activeSectionLensLayout,
                     "activeSectionLensLayout must be nil after a workspace switch")
        // Parked-member set is empty: the lift loop re-attached everything.
        XCTAssertTrue(c.lensParkedMembers.isEmpty,
                      "lensParkedMembers must be empty after the switch lifts the lens")
        // Destination members (20, 30) are in `toRestore` — no selective re-park.
        XCTAssertEqual(Set(plan!.toRestore.map(\.id)), [wid(20), wid(30)])
        // Old-WS members (10) are in `toPark`.
        XCTAssertEqual(Set(plan!.toPark.map(\.id)), [wid(10)])
    }

    /// EX-0.4: switch with no prior lens active behaves identically to
    /// the pre-EX historical path — destination members are unconditionally
    /// restored, lensParkedMembers stays empty, lens fields stay nil.
    func testSwitchWithoutLensRestoresAllUnchangedBehaviour() {
        var c = threeWindowCatalog(mode: "master-left")
        _ = c.moveWindow(wid(20), to: 2, in: rect)   // WS1={10,30}, WS2={20}
        let plan = c.setActive(2)
        XCTAssertNotNil(plan)
        XCTAssertEqual(Set(plan!.toRestore.map(\.id)), [wid(20)])
        XCTAssertTrue(c.lensParkedMembers.isEmpty)
        XCTAssertNil(c.activeSectionLens)
    }

    /// EX-0.4 replaces D1's "lift only" with "lift + null lens fields".
    /// This test verifies the lift half: lens-parked windows from WS1 are
    /// re-attached to WS1's layout so an inactive WS's preview is correct.
    ///
    /// Red-on-regression: if `lensParkedMembers.removeAll()` were removed
    /// from `setActive`, the second assert (`lensParkedMembers.isEmpty`)
    /// would fail; if the re-attach loop were removed, the
    /// `nonFloatingMembers(of: 1)` count would be wrong.
    func testSwitchLiftsAndClearsLensFromOldWorkspace() {
        var c = threeWindowCatalog(mode: "master-left")   // WS1={10,20,30}
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10)], in: rect)   // parks 20, 30
        XCTAssertEqual(c.lensParkedMembers, [wid(20), wid(30)], "precondition")

        // Switch to (empty) WS2.
        _ = c.setActive(2, in: rect)

        // Lens is fully cleared.
        XCTAssertNil(c.activeSectionLens,
                     "activeSectionLens must be nil after switch (EX-0.4)")
        XCTAssertTrue(c.lensParkedMembers.isEmpty,
                      "lensParkedMembers must be empty after the lift")
        // WS1 (now inactive) has all its members back in the layout
        // (re-attached by the lift loop).
        XCTAssertEqual(Set(c.nonFloatingMembers(of: 1)), [wid(10), wid(20), wid(30)],
                       "WS1 must show all members after the lens is lifted")
    }

    /// EX-0.4: switching to a destination workspace restores ALL its
    /// members (no per-lens filtering). Under D1 only in-lens members were
    /// restored; under EX-0.4 the destination is unfiltered.
    ///
    /// Red-on-regression: if the old D1 selective-restore branch were
    /// reinstated (checking `lensVisibleIDs`), the destination's out-of-lens
    /// member (30) would be omitted from `toRestore` and this assertion fails.
    func testSwitchRestoresAllDestinationMembers() {
        var c = threeWindowCatalog(mode: "master-left")
        _ = c.moveWindow(wid(20), to: 2, in: rect)
        _ = c.moveWindow(wid(30), to: 2, in: rect)   // WS1={10}, WS2={20,30}
        c.activeSectionLens = "Web"
        // Switch to WS2 — both 20 AND 30 must be in toRestore (no filtering).
        let plan = c.setActive(2, in: rect)
        XCTAssertNotNil(plan)
        XCTAssertEqual(Set(plan!.toRestore.map(\.id)), [wid(20), wid(30)],
                       "EX-0.4: ALL destination members must be restored, not just in-lens ones")
        // Source member (10) parks.
        XCTAssertEqual(Set(plan!.toPark.map(\.id)), [wid(10)])
        // Lens is cleared.
        XCTAssertNil(c.activeSectionLens)
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

    func testSnapshotFlagsInactiveWorkspaceWindowsWhenParkedByLens() {
        // EX-1: the cross-workspace lens parks non-matching windows in ALL
        // workspaces, so an inactive WS's out-of-lens window IS flagged
        // `isLensParked == true` in the snapshot.
        var c = threeWindowCatalog(mode: "master-left")
        _ = c.moveWindow(wid(30), to: 2, in: rect)   // 30 lives on inactive WS2
        c.activeSectionLens = "None"
        _ = c.applySectionLens(visibleIDs: [], in: rect)   // park ALL: 10,20,30
        let snap = c.snapshot(live: [window(10), window(20), window(30)],
                              focused: nil, activeRect: rect)
        XCTAssertEqual(snap[1].windows.first { $0.id == wid(30) }?.isLensParked,
                       true, "inactive-WS out-of-lens window is flagged lens-parked (EX-1)")
    }

    // MARK: - Cross-workspace union members + frames (EX-1b.2)

    /// Proves sectionLensUnionMembers() is a cross-workspace union: it returns
    /// windows from BOTH WS1 (active) and WS2 (inactive) that are not parked,
    /// and excludes the window that was parked out of the lens.
    func testSectionLensUnionMembersExcludeParkedFloatingHidden() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "master-left", in: rect)
        _ = c.moveWindow(wid(20), to: 2, in: rect)
        _ = c.moveWindow(wid(30), to: 2, in: rect)
        // wid(10) in WS1 (active), wid(20) and wid(30) in WS2 (inactive)
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10), wid(20)], in: rect) // wid(30) parks
        // Cross-workspace: both WS1 and WS2 windows appear in the union.
        XCTAssertEqual(Set(c.sectionLensUnionMembers()), [wid(10), wid(20)],
                       "union must contain windows from both WS1 (active) and WS2 (inactive)")
        XCTAssertFalse(c.sectionLensUnionMembers().contains(wid(30)),
                       "parked window must not appear in the union")
    }

    /// Proves sectionLensUnionFrames() tiles the cross-workspace union with a
    /// stateless engine, producing distinct non-overlapping frames.
    func testSectionLensUnionFramesTileWithStatelessEngine() {
        var c = seededCatalog(1)
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "master-left", in: rect)
        c.activeSectionLens = "Web"
        _ = c.applySectionLens(visibleIDs: [wid(10), wid(20)], in: rect)
        let frames = c.sectionLensUnionFrames(layout: "grid",
                                              in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        XCTAssertEqual(frames.count, 2, "stateless engine must produce one frame per union member")
        XCTAssertNotEqual(frames[wid(10)], frames[wid(20)],
                          "two windows must get distinct non-overlapping cells")
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
