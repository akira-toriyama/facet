import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure state-machine tests for the native adapter's
/// self-managed workspace state. Every test runs without AX
/// permission, AppKit, or any OS interaction — that's the point
/// of having extracted `WorkspaceCatalog` out of `NativeAdapter`.
final class WorkspaceCatalogTests: XCTestCase {

    // MARK: - Helpers

    private func wid(_ n: Int) -> WindowID {
        WindowID(serverID: n)
    }

    private func window(_ n: Int, pid: Int = 1000) -> Window {
        Window(id: wid(n), pid: pid, appName: "A",
               title: "w\(n)", isFocused: false,
               isFloating: false, frame: nil)
    }

    /// 1-based default workspace list (5 slots, matching
    /// `FacetConfig.defaultWorkspaceCount`).
    private let defaultConfigured = [1, 2, 3, 4, 5]

    /// Sparse list: only 1, 3, 5 — exercises the
    /// `isValid` sparse-aware path.
    private let sparseConfigured = [1, 3, 5]

    private func defaultConfiguredPairs() -> [(index: Int, name: String)] {
        defaultConfigured.map { ($0, "") }
    }

    // MARK: - Initial state

    func testInitialActiveIs1() {
        XCTAssertEqual(WorkspaceCatalog().activeIndex, 1)
    }

    func testInitialMapsAndSetsAreEmpty() {
        let c = WorkspaceCatalog()
        XCTAssertTrue(c.windowMap.isEmpty)
        XCTAssertTrue(c.anchorParked.isEmpty)
        XCTAssertTrue(c.minimizeParked.isEmpty)
        XCTAssertTrue(c.originalPositions.isEmpty)
    }

    // MARK: - Reconcile

    func testReconcileAssignsNewWindowsToActive() {
        var c = WorkspaceCatalog()
        let r = c.reconcile(live: [window(10), window(20)])
        XCTAssertEqual(r, .init(added: 2, removed: 0))
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1)
        XCTAssertEqual(c.windowMap[wid(20)]?.workspace, 1)
    }

    func testReconcileRecordsPidFromLiveWindow() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10, pid: 4242)])
        XCTAssertEqual(c.windowMap[wid(10)]?.pid, 4242)
    }

    func testReconcileRefreshesPidWhenItChangesUnderTheSameID() {
        // Defensive: if a wsid is ever reused after its owner dies,
        // the fresh pid should win so subsequent AX calls don't
        // target a stale (or now-different) process.
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10, pid: 1000)])
        _ = c.reconcile(live: [window(10, pid: 2000)])
        XCTAssertEqual(c.windowMap[wid(10)]?.pid, 2000)
    }

    func testReconcileNewWindowsLandInCurrentActive() {
        // Switch to WS 3 first; new windows should land in 3.
        var c = WorkspaceCatalog()
        _ = c.setActive(3, configuredIndexes: defaultConfigured)
        _ = c.reconcile(live: [window(10)])
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 3)
    }

    func testReconcileDropsGoneWindows() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        let r = c.reconcile(live: [window(10)])
        XCTAssertEqual(r, .init(added: 0, removed: 1))
        XCTAssertNil(c.windowMap[wid(20)])
    }

    func testReconcileDoesNotMovePreexistingWindow() {
        // Window assigned to WS 3 must stay there even after
        // active flips back to 1 and reconcile runs.
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.moveWindow(wid(10), to: 3,
                         configuredIndexes: defaultConfigured)
        _ = c.setActive(2, configuredIndexes: defaultConfigured)
        _ = c.reconcile(live: [window(10)])
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 3,
                       "reconcile must not reassign existing windows")
    }

    func testReconcileSweepsParkedSetsAndOriginalPositions() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.markAnchorParked(wid(10), originalPosition: .init(x: 1, y: 2))
        c.markMinimized(wid(20))
        // wid(10) disappears (e.g. user closed the window).
        _ = c.reconcile(live: [window(20)])
        XCTAssertFalse(c.anchorParked.contains(wid(10)))
        XCTAssertNil(c.originalPositions[wid(10)])
        // wid(20) still alive → minimize state preserved.
        XCTAssertTrue(c.minimizeParked.contains(wid(20)))
    }

    // MARK: - pid lookup

    func testPidForUnknownWindowIsNil() {
        XCTAssertNil(WorkspaceCatalog().pid(for: wid(10)))
    }

    func testPidForKnownWindowMatchesLiveValue() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10, pid: 1234)])
        XCTAssertEqual(c.pid(for: wid(10)), 1234)
    }

    // MARK: - isValid (sparse-aware)

    func testIsValidAcceptsConfiguredIndexes() {
        let c = WorkspaceCatalog()
        XCTAssertTrue(c.isValid(1, configuredIndexes: defaultConfigured))
        XCTAssertTrue(c.isValid(5, configuredIndexes: defaultConfigured))
    }

    func testIsValidRejectsGapInSparseConfig() {
        let c = WorkspaceCatalog()
        // Sparse [1, 3, 5] — 2 is invalid even though count ≥ 2.
        XCTAssertTrue(c.isValid(1, configuredIndexes: sparseConfigured))
        XCTAssertTrue(c.isValid(3, configuredIndexes: sparseConfigured))
        XCTAssertFalse(c.isValid(2, configuredIndexes: sparseConfigured),
                       "sparse config: 2 must be invalid")
        XCTAssertFalse(c.isValid(4, configuredIndexes: sparseConfigured))
    }

    func testIsValidRejectsZeroAndNegative() {
        let c = WorkspaceCatalog()
        XCTAssertFalse(c.isValid(0, configuredIndexes: defaultConfigured))
        XCTAssertFalse(c.isValid(-1, configuredIndexes: defaultConfigured))
    }

    // MARK: - setActive

    func testSetActiveReturnsNilForCurrentWorkspace() {
        var c = WorkspaceCatalog()
        XCTAssertNil(c.setActive(1, configuredIndexes: defaultConfigured),
                     "switching to current must be a no-op")
        XCTAssertEqual(c.activeIndex, 1)
    }

    func testSetActiveReturnsNilForInvalidTarget() {
        var c = WorkspaceCatalog()
        XCTAssertNil(c.setActive(2, configuredIndexes: sparseConfigured))
        XCTAssertEqual(c.activeIndex, 1, "rejected switch must not mutate")
    }

    func testSetActiveReturnsSwitchPlanWithCorrectSets() {
        // Three windows: 10 in WS1, 20 in WS2, 30 in WS2.
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10, pid: 100),
                               window(20, pid: 200),
                               window(30, pid: 300)])
        _ = c.moveWindow(wid(20), to: 2,
                         configuredIndexes: defaultConfigured)
        _ = c.moveWindow(wid(30), to: 2,
                         configuredIndexes: defaultConfigured)
        // Switching 1 → 2: 10 should park, {20, 30} should restore.
        let plan = c.setActive(2,
                               configuredIndexes: defaultConfigured)
        XCTAssertEqual(plan?.oldActive, 1)
        XCTAssertEqual(plan?.newActive, 2)
        XCTAssertEqual(plan?.toPark, [WindowRef(id: wid(10), pid: 100)])
        XCTAssertEqual(Set(plan?.toRestore ?? []),
                       [WindowRef(id: wid(20), pid: 200),
                        WindowRef(id: wid(30), pid: 300)])
        XCTAssertEqual(c.activeIndex, 2)
    }

    func testSwitchPlanCarriesPidFromCatalog() {
        // Specifically asserting the pid threading — even if pid
        // wasn't passed into setActive, the plan must include it
        // so the adapter can dispatch AX directly.
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10, pid: 9999)])
        let plan = c.setActive(2,
                               configuredIndexes: defaultConfigured)
        XCTAssertEqual(plan?.toPark.first?.pid, 9999)
    }

    // MARK: - moveWindow

    func testMoveWindowRejectsUnknownWindow() {
        var c = WorkspaceCatalog()
        let outcome = c.moveWindow(wid(99), to: 2,
                                   configuredIndexes: defaultConfigured)
        XCTAssertEqual(outcome, .rejected)
    }

    func testMoveWindowRejectsInvalidTarget() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        let outcome = c.moveWindow(wid(10), to: 2,
                                   configuredIndexes: sparseConfigured)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1,
                       "rejected move must not mutate")
    }

    func testMoveWindowRejectsAlreadyOnTarget() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        let outcome = c.moveWindow(wid(10), to: 1,
                                   configuredIndexes: defaultConfigured)
        XCTAssertEqual(outcome, .rejected)
    }

    func testMoveAwayFromActiveIsPark() {
        // Active = 1, window in 1 → move to 2 → park.
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10, pid: 777)])
        let outcome = c.moveWindow(wid(10), to: 2,
                                   configuredIndexes: defaultConfigured)
        XCTAssertEqual(outcome,
                       .park(WindowRef(id: wid(10), pid: 777)))
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 2)
        XCTAssertEqual(c.windowMap[wid(10)]?.pid, 777,
                       "pid must survive workspace reassignment")
    }

    func testMoveIntoActiveIsRestore() {
        // Window starts in WS 2 (non-active). Move it to active=1.
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10, pid: 555)])
        _ = c.moveWindow(wid(10), to: 2,
                         configuredIndexes: defaultConfigured)
        let outcome = c.moveWindow(wid(10), to: 1,
                                   configuredIndexes: defaultConfigured)
        XCTAssertEqual(outcome,
                       .restore(WindowRef(id: wid(10), pid: 555)))
    }

    func testMoveBetweenInactiveWorkspacesIsStateOnly() {
        // Active = 1. Window in WS 2 → move to WS 3 → invisible to
        // user, only the assignment changes.
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.moveWindow(wid(10), to: 2,
                         configuredIndexes: defaultConfigured)
        let outcome = c.moveWindow(wid(10), to: 3,
                                   configuredIndexes: defaultConfigured)
        XCTAssertEqual(outcome, .stateOnly)
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 3)
    }

    // MARK: - Anchor park bookkeeping

    func testShouldParkAnchorTrueWhenNotParked() {
        let c = WorkspaceCatalog()
        XCTAssertTrue(c.shouldParkAnchor(wid(10)))
    }

    func testShouldParkAnchorFalseAfterMark() {
        var c = WorkspaceCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        XCTAssertFalse(c.shouldParkAnchor(wid(10)),
                       "double-park guard")
    }

    func testConsumeAnchorRestoreReturnsAndClearsPosition() {
        var c = WorkspaceCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        XCTAssertEqual(c.consumeAnchorRestore(wid(10)),
                       .init(x: 5, y: 7))
        XCTAssertFalse(c.anchorParked.contains(wid(10)))
        XCTAssertNil(c.originalPositions[wid(10)])
    }

    func testConsumeAnchorRestoreReturnsNilForNonParked() {
        var c = WorkspaceCatalog()
        XCTAssertNil(c.consumeAnchorRestore(wid(10)),
                     "defensive against double-restore")
    }

    // MARK: - Minimize bookkeeping

    func testShouldMinimizeFlipsAfterMark() {
        var c = WorkspaceCatalog()
        XCTAssertTrue(c.shouldMinimize(wid(10)))
        c.markMinimized(wid(10))
        XCTAssertFalse(c.shouldMinimize(wid(10)))
        XCTAssertTrue(c.shouldUnminimize(wid(10)))
    }

    func testMarkUnminimizedClears() {
        var c = WorkspaceCatalog()
        c.markMinimized(wid(10))
        c.markUnminimized(wid(10))
        XCTAssertFalse(c.shouldUnminimize(wid(10)))
    }

    // MARK: - drop (closeWindow eviction)

    func testDropClearsAllTracesForWindow() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        c.markMinimized(wid(10))
        c.drop(wid(10))
        XCTAssertNil(c.windowMap[wid(10)])
        XCTAssertFalse(c.anchorParked.contains(wid(10)))
        XCTAssertFalse(c.minimizeParked.contains(wid(10)))
        XCTAssertNil(c.originalPositions[wid(10)])
    }

    func testDropIsIdempotent() {
        var c = WorkspaceCatalog()
        c.drop(wid(10))
        c.drop(wid(10))
    }

    // MARK: - Snapshot (0-based wire convention)

    func testSnapshotTranslatesIndexTo0Based() {
        let c = WorkspaceCatalog()
        let snap = c.snapshot(
            live: [], focused: nil,
            configured: defaultConfiguredPairs())
        XCTAssertEqual(snap.map(\.index), [0, 1, 2, 3, 4],
                       "snapshot must emit 0-based indexes")
    }

    func testSnapshotMarksActiveWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.setActive(3, configuredIndexes: defaultConfigured)
        let snap = c.snapshot(
            live: [], focused: nil,
            configured: defaultConfiguredPairs())
        XCTAssertEqual(snap.filter(\.isActive).map(\.index), [2],
                       "0-based index 2 = 1-based 3")
    }

    func testSnapshotPlacesWindowsInAssignedWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.moveWindow(wid(20), to: 3,
                         configuredIndexes: defaultConfigured)
        let snap = c.snapshot(
            live: [window(10), window(20)], focused: nil,
            configured: defaultConfiguredPairs())
        XCTAssertEqual(snap[0].windows.map(\.id), [wid(10)])
        XCTAssertEqual(snap[2].windows.map(\.id), [wid(20)])
        XCTAssertEqual(snap[1].windows.count, 0)
    }

    func testSnapshotStampsFocusedFlag() {
        let c = WorkspaceCatalog()
        let snap = c.snapshot(
            live: [window(10), window(20)],
            focused: wid(20),
            configured: defaultConfiguredPairs())
        let allWindows = snap.flatMap(\.windows)
        XCTAssertEqual(allWindows.first { $0.id == wid(20) }?.isFocused,
                       true)
        XCTAssertEqual(allWindows.first { $0.id == wid(10) }?.isFocused,
                       false)
    }

    func testSnapshotFallsBackToActiveForUnmappedWindow() {
        // Window not in windowMap → snapshot puts it in activeIndex
        // (covers the race where snapshot runs before reconcile).
        var c = WorkspaceCatalog()
        _ = c.setActive(2, configuredIndexes: defaultConfigured)
        let snap = c.snapshot(
            live: [window(99)], focused: nil,
            configured: defaultConfiguredPairs())
        XCTAssertEqual(snap[1].windows.map(\.id), [wid(99)])
    }

    // MARK: - Phase γ.1 — layout modes + floating + tile

    private let displayRect = CGRect(x: 0, y: 0,
                                     width: 1600, height: 900)

    func testDefaultModeIsFloatForUnsetWorkspace() {
        XCTAssertEqual(WorkspaceCatalog().mode(of: 1), "float")
    }

    func testSetModeBspCreatesTreeFromCurrentMembers() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        XCTAssertEqual(c.mode(of: 1), "bsp")
        let frames = c.tiledFrames(for: 1, in: displayRect)
        XCTAssertEqual(Set(frames.keys), [wid(10), wid(20)])
    }

    func testSetModeFloatDiscardsTree() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        XCTAssertNotNil(c.layoutTrees[1])
        _ = c.setMode(workspace: 1, to: "float", in: displayRect)
        XCTAssertNil(c.layoutTrees[1])
        XCTAssertEqual(c.tiledFrames(for: 1, in: displayRect), [:])
    }

    func testSetModeLowercasesInput() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "BSP", in: displayRect)
        XCTAssertEqual(c.mode(of: 1), "bsp")
    }

    func testReconcileAutoInsertsNewWindowsIntoActiveBspTree() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        let frames = c.tiledFrames(for: 1, in: displayRect)
        XCTAssertEqual(Set(frames.keys), [wid(10), wid(20)])
    }

    func testReconcileSkipsFloatingWindowsFromTree() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        c.toggleFloat(wid(10))
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        XCTAssertTrue(c.tiledFrames(for: 1, in: displayRect).isEmpty)
    }

    func testToggleFloatRemovesFromTreeAndReinserts() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        c.toggleFloat(wid(20))
        XCTAssertEqual(Set(c.tiledFrames(for: 1, in: displayRect).keys),
                       [wid(10)])
        XCTAssertTrue(c.isFloating(wid(20)))
        c.toggleFloat(wid(20), focused: wid(10), in: displayRect)
        XCTAssertEqual(Set(c.tiledFrames(for: 1, in: displayRect).keys),
                       [wid(10), wid(20)])
    }

    func testDropAlsoEvictsFromTree() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        c.drop(wid(10))
        XCTAssertEqual(Set(c.tiledFrames(for: 1, in: displayRect).keys),
                       [wid(20)])
    }

    func testReconcileGoneSweepHealsTree() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        _ = c.reconcile(live: [window(20)],
                        focused: nil, activeRect: displayRect)
        XCTAssertEqual(Set(c.tiledFrames(for: 1, in: displayRect).keys),
                       [wid(20)])
    }

    func testMoveWindowBetweenBspWorkspacesMaintainsBothTrees() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.setMode(workspace: 2, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        let outcome = c.moveWindow(wid(20), to: 2,
                                   configuredIndexes: defaultConfigured,
                                   in: displayRect)
        XCTAssertEqual(outcome,
                       .park(WindowRef(id: wid(20), pid: 1000)))
        XCTAssertEqual(Set(c.tiledFrames(for: 1, in: displayRect).keys),
                       [wid(10)])
        XCTAssertEqual(Set(c.tiledFrames(for: 2, in: displayRect).keys),
                       [wid(20)])
    }

    func testToggleOrientationDelegatesToOwningTree() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        let before = c.tiledFrames(for: 1, in: displayRect)
        XCTAssertEqual(before[wid(10)]?.width, 800,
                       "starts vertical-split")
        c.toggleOrientation(of: wid(10))
        let after = c.tiledFrames(for: 1, in: displayRect)
        XCTAssertEqual(after[wid(10)]?.width, 1600,
                       "horizontal-split after flip")
    }

    func testTiledFramesEmptyForFloatMode() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        XCTAssertEqual(c.tiledFrames(for: 1, in: displayRect), [:])
    }

    func testSnapshotPicksModePerWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 2, to: "bsp", in: displayRect)
        let snap = c.snapshot(
            live: [], focused: nil,
            configured: defaultConfiguredPairs())
        XCTAssertEqual(snap[0].layoutMode, "float",
                       "WS 1 unset → float")
        XCTAssertEqual(snap[1].layoutMode, "bsp",
                       "WS 2 set to bsp")
    }

    // MARK: - Phase γ.2 — stack mode

    func testSetModeStackCreatesOrderFromCurrentMembers() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(20), window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        // Members sort by id (deterministic) → [10, 20].
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10), wid(20)])
    }

    func testSetModeStackSkipsFloatingMembers() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.toggleFloat(wid(20))
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10)])
    }

    func testStackOrderEmptyForNonStackMode() {
        let c = WorkspaceCatalog()
        XCTAssertEqual(c.stackOrder(of: 1), [])
    }

    func testReconcileNewWindowBecomesStackTop() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        // New window 20 must land at index 0 (Q7c).
        XCTAssertEqual(c.stackOrder(of: 1).first, wid(20))
    }

    func testCycleStackNextRotatesLeft() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        XCTAssertEqual(c.stackOrder(of: 1),
                       [wid(10), wid(20), wid(30)])
        let top = c.cycleStack(workspace: 1, direction: .next)
        XCTAssertEqual(top, wid(20))
        XCTAssertEqual(c.stackOrder(of: 1),
                       [wid(20), wid(30), wid(10)])
    }

    func testCycleStackPrevRotatesRight() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        let top = c.cycleStack(workspace: 1, direction: .prev)
        XCTAssertEqual(top, wid(30))
        XCTAssertEqual(c.stackOrder(of: 1),
                       [wid(30), wid(10), wid(20)])
    }

    func testCycleStackSingleMemberIsNoop() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        XCTAssertNil(c.cycleStack(workspace: 1, direction: .next))
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10)])
    }

    func testCycleStackEmptyIsNoop() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        XCTAssertNil(c.cycleStack(workspace: 1, direction: .next))
    }

    func testDropEvictsFromStackOrder() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        c.drop(wid(10))
        XCTAssertEqual(c.stackOrder(of: 1), [wid(20)])
    }

    func testToggleFloatRemovesFromStackAndReadds() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        c.toggleFloat(wid(20))
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10)])
        // Unfloat → returns to stack at top.
        c.toggleFloat(wid(20), focused: nil, in: displayRect)
        XCTAssertEqual(c.stackOrder(of: 1).first, wid(20))
    }

    func testMoveWindowIntoStackPutsItOnTop() {
        var c = WorkspaceCatalog()
        _ = c.setMode(workspace: 2, to: "stack",
                      in: displayRect)
        _ = c.reconcile(live: [window(10)])
        // 10 is in WS 1 (active default). Move into WS 2 stack.
        _ = c.moveWindow(wid(10), to: 2,
                         configuredIndexes: defaultConfigured,
                         in: displayRect)
        XCTAssertEqual(c.stackOrder(of: 2), [wid(10)])
    }

    func testSetModeFlipReplacesLayoutKind() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        // BSP → stack: tree gone, order built.
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        XCTAssertNotNil(c.layoutTrees[1])
        _ = c.setMode(workspace: 1, to: "stack", in: displayRect)
        XCTAssertNil(c.layoutTrees[1])
        XCTAssertEqual(c.stackOrder(of: 1).sorted { $0.serverID < $1.serverID },
                       [wid(10), wid(20)])
        // Stack → BSP: order gone, tree built.
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        XCTAssertNil(c.stackOrders[1])
        XCTAssertNotNil(c.layoutTrees[1])
    }

    func testClearParkedStateDropsAllHideFlags() {
        var c = WorkspaceCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 1, y: 2))
        c.markMinimized(wid(10))
        c.clearParkedState(of: wid(10))
        XCTAssertFalse(c.anchorParked.contains(wid(10)))
        XCTAssertFalse(c.minimizeParked.contains(wid(10)))
        XCTAssertNil(c.originalPositions[wid(10)])
    }

    func testSnapshotStampsIsFloating() {
        var c = WorkspaceCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.toggleFloat(wid(10))
        let snap = c.snapshot(
            live: [window(10), window(20)], focused: nil,
            configured: defaultConfiguredPairs())
        let allWindows = snap.flatMap(\.windows)
        XCTAssertEqual(allWindows.first { $0.id == wid(10) }?.isFloating,
                       true)
        XCTAssertEqual(allWindows.first { $0.id == wid(20) }?.isFloating,
                       false)
    }

    func testSnapshotRespectsSparseConfig() {
        let c = WorkspaceCatalog()
        let snap = c.snapshot(
            live: [], focused: nil,
            configured: [(1, "dev"), (3, "ide"), (5, "sns")])
        XCTAssertEqual(snap.map(\.index), [0, 2, 4])
        XCTAssertEqual(snap.map(\.name), ["dev", "ide", "sns"])
    }
}
