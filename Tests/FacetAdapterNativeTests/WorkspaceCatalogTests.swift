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

    /// A catalog seeded with `n` contiguous, unnamed workspaces — the
    /// dynamic live set the adapter normally seeds from config. Most
    /// tests need ≥1 workspace before `setActive` / `snapshot` etc.
    /// work (an unseeded catalog has an empty set). Uses `.init()` so
    /// it isn't itself rewritten when call sites adopt this helper.
    private func seededCatalog(_ n: Int = 5) -> WorkspaceCatalog {
        var c = WorkspaceCatalog.init()
        c.seed(configs: (1...n).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        return c
    }

    // MARK: - Initial state

    func testInitialActiveIs1() {
        XCTAssertEqual(seededCatalog().activeIndex, 1)
    }

    func testInitialMapsAndSetsAreEmpty() {
        let c = seededCatalog()
        XCTAssertTrue(c.windowMap.isEmpty)
        XCTAssertTrue(c.anchorParked.isEmpty)
        XCTAssertTrue(c.originalPositions.isEmpty)
    }

    // MARK: - Reconcile

    func testReconcileAssignsNewWindowsToActive() {
        var c = seededCatalog()
        let r = c.reconcile(live: [window(10), window(20)])
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(Set(r.addedIDs), [wid(10), wid(20)])
        XCTAssertEqual(r.removedIDs, [])
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1)
        XCTAssertEqual(c.windowMap[wid(20)]?.workspace, 1)
    }

    func testReconcileRecordsPidFromLiveWindow() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 4242)])
        XCTAssertEqual(c.windowMap[wid(10)]?.pid, 4242)
    }

    func testReconcileRefreshesPidWhenItChangesUnderTheSameID() {
        // Defensive: if a wsid is ever reused after its owner dies,
        // the fresh pid should win so subsequent AX calls don't
        // target a stale (or now-different) process.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 1000)])
        _ = c.reconcile(live: [window(10, pid: 2000)])
        XCTAssertEqual(c.windowMap[wid(10)]?.pid, 2000)
    }

    func testReconcileNewWindowsLandInCurrentActive() {
        // Switch to WS 3 first; new windows should land in 3.
        var c = seededCatalog()
        _ = c.setActive(3)
        _ = c.reconcile(live: [window(10)])
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 3)
    }

    func testReconcileDropsGoneWindows() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        let r = c.reconcile(live: [window(10)])
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(r.addedIDs, [])
        XCTAssertEqual(r.removedIDs, [wid(20)],
                       "removed IDs surface the gone window")
        XCTAssertNil(c.windowMap[wid(20)])
    }

    // MARK: - Trusted-new fast-path (two-tick gate)

    func testTwoTickGateDefersUntrustedNewWindow() {
        // Under requireConfirm a new on-screen window waits for a
        // SECOND sighting before joining the map (swallows the
        // cross-Space `isOnscreen` flip during a Space switch).
        var c = seededCatalog()
        let r1 = c.reconcile(live: [window(10)], requireConfirm: true)
        XCTAssertEqual(r1.added, 0)
        XCTAssertEqual(r1.removed, 0)
        XCTAssertEqual(r1.addedIDs, [])
        XCTAssertNil(c.windowMap[wid(10)])
        let r2 = c.reconcile(live: [window(10)], requireConfirm: true)
        XCTAssertEqual(r2.added, 1)
        XCTAssertEqual(r2.addedIDs, [wid(10)])
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1)
    }

    func testTrustedNewWindowSkipsGate() {
        // A genuinely-new window (kAXWindowCreated → trusted) joins on
        // the FIRST sighting even under requireConfirm — this is the
        // add-latency win.
        var c = seededCatalog()
        let r = c.reconcile(live: [window(10)],
                            trusted: [wid(10)],
                            requireConfirm: true)
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.addedIDs, [wid(10)])
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1)
    }

    func testIgnoreKeepsWindowUnmanaged() {
        // Config `action="ignore"` window never enters the map, and
        // stays out on later reconciles (marked examined) even once
        // the ignore hint is no longer supplied.
        var c = seededCatalog()
        let r = c.reconcile(live: [window(10), window(20)],
                            ignore: [wid(20)])
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1)
        XCTAssertNil(c.windowMap[wid(20)])
        let r2 = c.reconcile(live: [window(10), window(20)])
        XCTAssertEqual(r2.added, 0)
        XCTAssertNil(c.windowMap[wid(20)])
    }

    func testDeferredWindowSkippedButReProbedLater() {
        // A window the adapter couldn't classify yet (AX role
        // unresolved — the probe raced a still-creating window or hit
        // the per-call cap) is `deferred`: it does NOT join this tick,
        // not even on the trusted fast-path. Unlike `ignore` it is NOT
        // marked examined, so once AX resolves (no longer supplied as
        // deferred) a later reconcile adopts it. This is what lets a
        // real window tile a poll late while a transient popup — which
        // vanishes before it ever resolves — never tiles at all.
        var c = seededCatalog()
        let r1 = c.reconcile(live: [window(10), window(20)],
                             trusted: [wid(10), wid(20)],
                             deferred: [wid(20)],
                             requireConfirm: true)
        XCTAssertEqual(r1.added, 1, "only the resolved window joins")
        XCTAssertEqual(r1.addedIDs, [wid(10)])
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1)
        XCTAssertNil(c.windowMap[wid(20)],
                     "deferred window skipped even when trusted")
        // Next tick: AX resolved → no longer deferred → adopted. Proves
        // the defer did NOT mark it examined (contrast: `ignore` does).
        let r2 = c.reconcile(live: [window(10), window(20)])
        XCTAssertEqual(r2.added, 1)
        XCTAssertEqual(r2.addedIDs, [wid(20)])
        XCTAssertEqual(c.windowMap[wid(20)]?.workspace, 1)
    }

    func testTrustedDoesNotOverrideOffScreenDefer() {
        // Trusted bypasses only the two-tick gate, not the off-screen
        // defer that runs before it: a window still transiently
        // off-screen mid-creation must NOT slip in.
        var c = seededCatalog()
        let offscreen = Window(id: wid(10), pid: 1000, appName: "A",
                               title: "w10", isFocused: false,
                               isFloating: false, frame: nil,
                               isOnscreen: false)
        let r = c.reconcile(live: [offscreen],
                            trusted: [wid(10)],
                            requireConfirm: true)
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.addedIDs, [])
        XCTAssertNil(c.windowMap[wid(10)])
    }

    func testReconcileDoesNotMovePreexistingWindow() {
        // Window assigned to WS 3 must stay there even after
        // active flips back to 1 and reconcile runs.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.moveWindow(wid(10), to: 3)
        _ = c.setActive(2)
        _ = c.reconcile(live: [window(10)])
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 3,
                       "reconcile must not reassign existing windows")
    }

    func testReconcileSweepsParkedSetsAndOriginalPositions() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.markAnchorParked(wid(10), originalPosition: .init(x: 1, y: 2))
        c.markAnchorParked(wid(20), originalPosition: .init(x: 3, y: 4))
        // wid(10) disappears (e.g. user closed the window).
        _ = c.reconcile(live: [window(20)])
        XCTAssertFalse(c.anchorParked.contains(wid(10)))
        XCTAssertNil(c.originalPositions[wid(10)])
        // wid(20) still alive → park state preserved.
        XCTAssertTrue(c.anchorParked.contains(wid(20)))
        XCTAssertNotNil(c.originalPositions[wid(20)])
    }

    // MARK: - pid lookup

    func testPidForUnknownWindowIsNil() {
        XCTAssertNil(seededCatalog().pid(for: wid(10)))
    }

    func testPidForKnownWindowMatchesLiveValue() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 1234)])
        XCTAssertEqual(c.pid(for: wid(10)), 1234)
    }

    // MARK: - isValid (contiguous live set)

    func testIsValidAcceptsLiveRange() {
        let c = seededCatalog()           // 5 contiguous workspaces
        XCTAssertTrue(c.isValid(1))
        XCTAssertTrue(c.isValid(5))
    }

    func testIsValidRejectsBeyondCount() {
        let c = seededCatalog(3)          // positions 1...3
        XCTAssertTrue(c.isValid(3))
        XCTAssertFalse(c.isValid(4),
                       "the live set is contiguous 1...count")
    }

    func testIsValidRejectsZeroAndNegative() {
        let c = seededCatalog()
        XCTAssertFalse(c.isValid(0))
        XCTAssertFalse(c.isValid(-1))
    }

    // MARK: - setActive

    func testSetActiveReturnsNilForCurrentWorkspace() {
        var c = seededCatalog()
        XCTAssertNil(c.setActive(1),
                     "switching to current must be a no-op")
        XCTAssertEqual(c.activeIndex, 1)
    }

    func testSetActiveReturnsNilForInvalidTarget() {
        var c = seededCatalog(3)
        XCTAssertNil(c.setActive(6), "beyond the live count")
        XCTAssertEqual(c.activeIndex, 1, "rejected switch must not mutate")
    }

    func testSetActiveReturnsSwitchPlanWithCorrectSets() {
        // Three windows: 10 in WS1, 20 in WS2, 30 in WS2.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 100),
                               window(20, pid: 200),
                               window(30, pid: 300)])
        _ = c.moveWindow(wid(20), to: 2)
        _ = c.moveWindow(wid(30), to: 2)
        // Switching 1 → 2: 10 should park, {20, 30} should restore.
        let plan = c.setActive(2)
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
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 9999)])
        let plan = c.setActive(2)
        XCTAssertEqual(plan?.toPark.first?.pid, 9999)
    }

    // MARK: - moveWindow

    func testMoveWindowRejectsUnknownWindow() {
        var c = seededCatalog()
        let outcome = c.moveWindow(wid(99), to: 2)
        XCTAssertEqual(outcome, .rejected)
    }

    func testMoveWindowRejectsInvalidTarget() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])
        // Target beyond the live workspace count is rejected.
        let outcome = c.moveWindow(wid(10), to: 99)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1,
                       "rejected move must not mutate")
    }

    func testMoveWindowRejectsAlreadyOnTarget() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        let outcome = c.moveWindow(wid(10), to: 1)
        XCTAssertEqual(outcome, .rejected)
    }

    func testMoveAwayFromActiveIsPark() {
        // Active = 1, window in 1 → move to 2 → park.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 777)])
        let outcome = c.moveWindow(wid(10), to: 2)
        XCTAssertEqual(outcome,
                       .park(WindowRef(id: wid(10), pid: 777)))
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 2)
        XCTAssertEqual(c.windowMap[wid(10)]?.pid, 777,
                       "pid must survive workspace reassignment")
    }

    func testMoveIntoActiveIsRestore() {
        // Window starts in WS 2 (non-active). Move it to active=1.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 555)])
        _ = c.moveWindow(wid(10), to: 2)
        let outcome = c.moveWindow(wid(10), to: 1)
        XCTAssertEqual(outcome,
                       .restore(WindowRef(id: wid(10), pid: 555)))
    }

    func testMoveBetweenInactiveWorkspacesIsStateOnly() {
        // Active = 1. Window in WS 2 → move to WS 3 → invisible to
        // user, only the assignment changes.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.moveWindow(wid(10), to: 2)
        let outcome = c.moveWindow(wid(10), to: 3)
        XCTAssertEqual(outcome, .stateOnly)
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 3)
    }

    // MARK: - Anchor park bookkeeping

    func testShouldParkAnchorTrueWhenNotParked() {
        let c = seededCatalog()
        XCTAssertTrue(c.shouldParkAnchor(wid(10)))
    }

    func testShouldParkAnchorFalseAfterMark() {
        var c = seededCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        XCTAssertFalse(c.shouldParkAnchor(wid(10)),
                       "double-park guard")
    }

    func testConsumeAnchorRestoreReturnsAndClearsPosition() {
        var c = seededCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        XCTAssertEqual(c.consumeAnchorRestore(wid(10)),
                       .init(x: 5, y: 7))
        XCTAssertFalse(c.anchorParked.contains(wid(10)))
        XCTAssertNil(c.originalPositions[wid(10)])
    }

    func testConsumeAnchorRestoreReturnsNilForNonParked() {
        var c = seededCatalog()
        XCTAssertNil(c.consumeAnchorRestore(wid(10)),
                     "defensive against double-restore")
    }

    // MARK: - drop (closeWindow eviction)

    func testDropClearsAllTracesForWindow() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        c.drop(wid(10))
        XCTAssertNil(c.windowMap[wid(10)])
        XCTAssertFalse(c.anchorParked.contains(wid(10)))
        XCTAssertNil(c.originalPositions[wid(10)])
    }

    func testDropIsIdempotent() {
        // Two paths: drop on a never-known id, and drop twice on
        // the same id. Both must leave the catalog in an empty
        // / consistent state (no crash, no stale entries).
        var c = seededCatalog()
        c.drop(wid(10))
        XCTAssertNil(c.windowMap[wid(10)])
        XCTAssertFalse(c.anchorParked.contains(wid(10)))

        _ = c.reconcile(live: [window(20)])
        c.drop(wid(20))
        c.drop(wid(20))
        XCTAssertNil(c.windowMap[wid(20)])
        XCTAssertEqual(c.windowMap.count, 0)
    }

    // MARK: - Snapshot (0-based wire convention)

    func testSnapshotTranslatesIndexTo0Based() {
        let c = seededCatalog()
        let snap = c.snapshot(
            live: [], focused: nil,
            activeRect: .zero)
        XCTAssertEqual(snap.map(\.index), [0, 1, 2, 3, 4],
                       "snapshot must emit 0-based indexes")
    }

    func testSnapshotMarksActiveWorkspace() {
        var c = seededCatalog()
        _ = c.setActive(3)
        let snap = c.snapshot(
            live: [], focused: nil,
            activeRect: .zero)
        XCTAssertEqual(snap.filter(\.isActive).map(\.index), [2],
                       "0-based index 2 = 1-based 3")
    }

    func testSnapshotPlacesWindowsInAssignedWorkspace() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.moveWindow(wid(20), to: 3)
        let snap = c.snapshot(
            live: [window(10), window(20)], focused: nil,
            activeRect: .zero)
        XCTAssertEqual(snap[0].windows.map(\.id), [wid(10)])
        XCTAssertEqual(snap[2].windows.map(\.id), [wid(20)])
        XCTAssertEqual(snap[1].windows.count, 0)
    }

    func testSnapshotStampsFocusedFlag() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        let snap = c.snapshot(
            live: [window(10), window(20)],
            focused: wid(20),
            activeRect: .zero)
        let allWindows = snap.flatMap(\.windows)
        XCTAssertEqual(allWindows.first { $0.id == wid(20) }?.isFocused,
                       true)
        XCTAssertEqual(allWindows.first { $0.id == wid(10) }?.isFocused,
                       false)
    }

    func testSnapshotSkipsWindowsNotInMap() {
        // Live windows that reconcile hasn't accepted (off-screen on
        // first sight, marked pre-existing at startup / Space change,
        // etc.) are filtered out of the per-WS snapshot. Previously
        // they fell back to `activeIndex` — that surfaced as the
        // "145 windows in WS1" bug after the `.optionAll` switch.
        var c = seededCatalog()
        _ = c.setActive(2)
        let snap = c.snapshot(
            live: [window(99)], focused: nil,
            activeRect: .zero)
        XCTAssertEqual(snap.flatMap(\.windows).count, 0)
    }

    // MARK: - Phase γ.1 — layout modes + floating + tile

    private let displayRect = CGRect(x: 0, y: 0,
                                     width: 1600, height: 900)

    func testDefaultModeIsFloatForUnsetWorkspace() {
        XCTAssertEqual(seededCatalog().mode(of: 1), "float")
    }

    func testSetModeBspCreatesTreeFromCurrentMembers() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        XCTAssertEqual(c.mode(of: 1), "bsp")
        let frames = c.tiledFrames(for: 1, in: displayRect)
        XCTAssertEqual(Set(frames.keys), [wid(10), wid(20)])
    }

    func testSetModeFloatDiscardsTree() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        XCTAssertNotNil(c.layoutTrees[1])
        _ = c.setMode(workspace: 1, to: "float", in: displayRect)
        XCTAssertNil(c.layoutTrees[1])
        XCTAssertEqual(c.tiledFrames(for: 1, in: displayRect), [:])
    }

    func testSetModeLowercasesInput() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "BSP", in: displayRect)
        XCTAssertEqual(c.mode(of: 1), "bsp")
    }

    func testReconcileAutoInsertsNewWindowsIntoActiveBspTree() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        let frames = c.tiledFrames(for: 1, in: displayRect)
        XCTAssertEqual(Set(frames.keys), [wid(10), wid(20)])
    }

    func testReconcileSkipsFloatingWindowsFromTree() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.toggleFloat(wid(10))
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        XCTAssertTrue(c.tiledFrames(for: 1, in: displayRect).isEmpty)
    }

    func testToggleFloatRemovesFromTreeAndReinserts() {
        var c = seededCatalog()
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
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        c.drop(wid(10))
        XCTAssertEqual(Set(c.tiledFrames(for: 1, in: displayRect).keys),
                       [wid(20)])
    }

    func testReconcileGoneSweepHealsTree() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        _ = c.reconcile(live: [window(20)],
                        focused: nil, activeRect: displayRect)
        XCTAssertEqual(Set(c.tiledFrames(for: 1, in: displayRect).keys),
                       [wid(20)])
    }

    func testMoveWindowBetweenBspWorkspacesMaintainsBothTrees() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.setMode(workspace: 2, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        let outcome = c.moveWindow(wid(20), to: 2,
                                   in: displayRect)
        XCTAssertEqual(outcome,
                       .park(WindowRef(id: wid(20), pid: 1000)))
        XCTAssertEqual(Set(c.tiledFrames(for: 1, in: displayRect).keys),
                       [wid(10)])
        XCTAssertEqual(Set(c.tiledFrames(for: 2, in: displayRect).keys),
                       [wid(20)])
    }

    func testToggleOrientationDelegatesToOwningTree() {
        var c = seededCatalog()
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
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        XCTAssertEqual(c.tiledFrames(for: 1, in: displayRect), [:])
    }

    func testSnapshotPicksModePerWorkspace() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 2, to: "bsp", in: displayRect)
        let snap = c.snapshot(
            live: [], focused: nil,
            activeRect: .zero)
        XCTAssertEqual(snap[0].layoutMode, "float",
                       "WS 1 unset → float")
        XCTAssertEqual(snap[1].layoutMode, "bsp",
                       "WS 2 set to bsp")
    }

    // MARK: - Phase γ.2 — stack mode

    func testSetModeStackCreatesOrderFromCurrentMembers() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(20), window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        // Members sort by id (deterministic) → [10, 20].
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10), wid(20)])
    }

    func testSetModeStackSkipsFloatingMembers() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.toggleFloat(wid(20))
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10)])
    }

    func testStackOrderEmptyForNonStackMode() {
        let c = seededCatalog()
        XCTAssertEqual(c.stackOrder(of: 1), [])
    }

    func testReconcileNewWindowBecomesStackTop() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        // New window 20 must land at index 0 (Q7c).
        XCTAssertEqual(c.stackOrder(of: 1).first, wid(20))
    }

    func testCycleStackNextRotatesLeft() {
        var c = seededCatalog()
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
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        let top = c.cycleStack(workspace: 1, direction: .prev)
        XCTAssertEqual(top, wid(30))
        XCTAssertEqual(c.stackOrder(of: 1),
                       [wid(30), wid(10), wid(20)])
    }

    func testCycleStackSingleMemberIsNoop() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        XCTAssertNil(c.cycleStack(workspace: 1, direction: .next))
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10)])
    }

    func testCycleStackEmptyIsNoop() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        XCTAssertNil(c.cycleStack(workspace: 1, direction: .next))
        XCTAssertEqual(c.stackOrder(of: 1), [],
                       "empty order must stay empty post-cycle")
    }

    func testDropEvictsFromStackOrder() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        c.drop(wid(10))
        XCTAssertEqual(c.stackOrder(of: 1), [wid(20)])
    }

    func testToggleFloatRemovesFromStackAndReadds() {
        var c = seededCatalog()
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
        var c = seededCatalog()
        _ = c.setMode(workspace: 2, to: "stack",
                      in: displayRect)
        _ = c.reconcile(live: [window(10)])
        // 10 is in WS 1 (active default). Move into WS 2 stack.
        _ = c.moveWindow(wid(10), to: 2, in: displayRect)
        XCTAssertEqual(c.stackOrder(of: 2), [wid(10)])
    }

    func testSetModeFlipWithFiveMembersPreservesAllAcrossBspStackBsp() {
        // Mode flipping a populated WS shouldn't drop members.
        // BSP → Stack → BSP with 5 windows: every id survives,
        // and the final BSP tree contains the same id set.
        var c = seededCatalog()
        _ = c.reconcile(live: (10...14).map { window($0) })
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        let bspIDs = Set(c.tiledFrames(for: 1, in: displayRect).keys)
        XCTAssertEqual(bspIDs.count, 5)
        _ = c.setMode(workspace: 1, to: "stack", in: displayRect)
        XCTAssertEqual(Set(c.stackOrder(of: 1)),
                       Set((10...14).map(wid)),
                       "stack must inherit all bsp members")
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        let bspIDs2 = Set(c.tiledFrames(for: 1, in: displayRect).keys)
        XCTAssertEqual(bspIDs2, bspIDs,
                       "round-trip bsp→stack→bsp preserves the "
                       + "id set in the tree")
    }

    func testSetModeFlipReplacesLayoutKind() {
        var c = seededCatalog()
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

    // MARK: - Theme B — tall / stateless-engine shared order

    func testSetModeTallSeedsSharedOrderFromMembers() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(20), window(10)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        // Stateless engines reuse the stack order; seeded id-sorted.
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10), wid(20)])
        XCTAssertNil(c.layoutTrees[1], "tall must discard any tree")
    }

    func testReconcileNewWindowBecomesTallMaster() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        // New window lands at index 0 = master.
        XCTAssertEqual(c.stackOrder(of: 1).first, wid(20))
    }

    func testPromoteToMasterMovesChosenWindowToFront() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        XCTAssertEqual(c.stackOrder(of: 1),
                       [wid(10), wid(20), wid(30)])
        XCTAssertTrue(c.promoteToMaster(wid(30), workspace: 1))
        XCTAssertEqual(c.stackOrder(of: 1),
                       [wid(30), wid(10), wid(20)])
    }

    func testPromoteToMasterAlreadyMasterIsNoop() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        XCTAssertFalse(c.promoteToMaster(wid(10), workspace: 1),
                       "already at index 0 → no change")
        XCTAssertEqual(c.stackOrder(of: 1), [wid(10), wid(20)])
    }

    func testPromoteToMasterUnknownWindowIsNoop() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        XCTAssertFalse(c.promoteToMaster(wid(99), workspace: 1))
    }

    func testOrderedMembersReflectsSharedOrder() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        _ = c.promoteToMaster(wid(30), workspace: 1)
        XCTAssertEqual(c.orderedMembers(of: 1),
                       [wid(30), wid(10), wid(20)])
    }

    func testTallDropEvictsFromSharedOrder() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        c.drop(wid(10))
        XCTAssertEqual(c.stackOrder(of: 1), [wid(20)])
    }

    // MARK: - Theme B — master knobs (ratio / count)

    func testDefaultParamsAreNeutral() {
        let c = seededCatalog()
        XCTAssertEqual(c.params(of: 1).masterRatio, 0.5)
        XCTAssertEqual(c.params(of: 1).masterCount, 1)
    }

    func testAdjustMasterRatioNudgesAndClamps() {
        var c = seededCatalog()
        XCTAssertTrue(c.adjustMasterRatio(workspace: 1, delta: 0.05))
        XCTAssertEqual(c.params(of: 1).masterRatio, 0.55, accuracy: 1e-9)
        // Drive up to the 0.95 clamp; the boundary nudge returns false.
        for _ in 0..<20 { _ = c.adjustMasterRatio(workspace: 1, delta: 0.05) }
        XCTAssertEqual(c.params(of: 1).masterRatio, 0.95, accuracy: 1e-9)
        XCTAssertFalse(c.adjustMasterRatio(workspace: 1, delta: 0.05),
                       "no change at the clamp → false (skip re-tile)")
    }

    func testAdjustMasterCountNudgesAndClampsAtOne() {
        var c = seededCatalog()
        XCTAssertTrue(c.adjustMasterCount(workspace: 1, delta: 1))
        XCTAssertEqual(c.params(of: 1).masterCount, 2)
        XCTAssertTrue(c.adjustMasterCount(workspace: 1, delta: -1))
        XCTAssertEqual(c.params(of: 1).masterCount, 1)
        XCTAssertFalse(c.adjustMasterCount(workspace: 1, delta: -1),
                       "clamped at 1 → no change")
    }

    func testParamsPersistAcrossModeFlip() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)   // → 0.6
        _ = c.setMode(workspace: 1, to: "grid", in: displayRect)
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        XCTAssertEqual(c.params(of: 1).masterRatio, 0.6, accuracy: 1e-9,
                       "ratio remembered across a mode round-trip")
    }

    func testEngineFramesReflectAdjustedRatio() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "tall", in: displayRect)
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)   // 0.5 → 0.6
        let frames = c.engineFrames(for: 1, in: displayRect)
        // Master (lower id = order[0]) gets 0.6 * 1600 = 960 wide.
        XCTAssertEqual(frames[wid(10)]?.width ?? 0, 960, accuracy: 1e-9)
    }

    // MARK: - Phase γ.3 — autoFloat reconcile hint

    func testReconcileAutoFloatMarksNewWindowFloating() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)],
                        autoFloat: [wid(10)])
        XCTAssertTrue(c.isFloating(wid(10)))
    }

    func testReconcileAutoFloatSkipsTreeInsert() {
        // BSP active WS. A new auto-floating window must NOT
        // enter the tree.
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10)],
                        focused: nil, activeRect: displayRect,
                        autoFloat: [wid(10)])
        XCTAssertTrue(c.isFloating(wid(10)))
        XCTAssertTrue(c.tiledFrames(for: 1, in: displayRect).isEmpty)
    }

    func testReconcileAutoFloatSkipsStackInsert() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "stack", in: displayRect)
        _ = c.reconcile(live: [window(10)],
                        focused: nil, activeRect: displayRect,
                        autoFloat: [wid(10)])
        XCTAssertTrue(c.isFloating(wid(10)))
        XCTAssertEqual(c.stackOrder(of: 1), [])
    }

    func testReconcileAutoFloatIsNoopForKnownWindow() {
        // autoFloat hint must NOT flip floating state on a
        // window the catalog already knows about — user's
        // toggleFloat decision stays authoritative.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        XCTAssertFalse(c.isFloating(wid(10)))
        // Subsequent reconcile with autoFloat set should NOT
        // promote a known-non-floating window to floating.
        _ = c.reconcile(live: [window(10)],
                        autoFloat: [wid(10)])
        XCTAssertFalse(c.isFloating(wid(10)),
                       "autoFloat is a first-sight hint, not a "
                       + "policy override")
    }

    func testReconcileAutoFloatTakesEffectInNonActiveWorkspace() {
        // Per Phase γ.3: autoFloat applies to every new window
        // regardless of which WS landed it. If the user opens a
        // dialog while not on WS 1 (e.g. they're on WS 3 and
        // window appears there), it should still auto-float.
        var c = seededCatalog()
        _ = c.setActive(3)
        _ = c.setMode(workspace: 3, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10)],
                        focused: nil, activeRect: displayRect,
                        autoFloat: [wid(10)])
        XCTAssertTrue(c.isFloating(wid(10)),
                      "autoFloat must work in non-WS-1 contexts")
        XCTAssertEqual(c.tiledFrames(for: 3, in: displayRect), [:],
                       "floating new window must skip the WS3 tree")
    }

    // MARK: - Misc state helpers

    func testClearParkedStateDropsAllHideFlags() {
        var c = seededCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 1, y: 2))
        c.clearParkedState(of: wid(10))
        XCTAssertFalse(c.anchorParked.contains(wid(10)))
        XCTAssertNil(c.originalPositions[wid(10)])
    }

    func testSnapshotStampsIsFloating() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.toggleFloat(wid(10))
        let snap = c.snapshot(
            live: [window(10), window(20)], focused: nil,
            activeRect: .zero)
        let allWindows = snap.flatMap(\.windows)
        XCTAssertEqual(allWindows.first { $0.id == wid(10) }?.isFloating,
                       true)
        XCTAssertEqual(allWindows.first { $0.id == wid(20) }?.isFloating,
                       false)
    }

    func testSnapshotUsesSeededNamesCompactedToContiguous() {
        // A sparse seed (1/3/5) compacts to contiguous positions; the
        // snapshot emits 0-based contiguous indices, names preserved
        // in order. (Dynamic model is position-based — sparsity can't
        // survive; names are the stable handle now.)
        var c = WorkspaceCatalog.init()
        c.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "dev")),
            (index: 3, config: WorkspaceConfig(name: "ide")),
            (index: 5, config: WorkspaceConfig(name: "sns")),
        ])
        let snap = c.snapshot(live: [], focused: nil, activeRect: .zero)
        XCTAssertEqual(snap.map(\.index), [0, 1, 2])
        XCTAssertEqual(snap.map(\.name), ["dev", "ide", "sns"])
    }
}
