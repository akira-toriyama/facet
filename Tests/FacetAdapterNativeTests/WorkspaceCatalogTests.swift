import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure state-machine tests for the native adapter's
/// self-managed workspace state. Every test runs without AX
/// permission, AppKit, or any OS interaction — that's the point
/// of having extracted `WorkspaceCatalog` out of `NativeAdapter`.
struct WorkspaceCatalogTests {

    // MARK: - Initial state

    @Test func initialActiveIs1() {
        #expect(seededCatalog().activeIndex == 1)
    }

    @Test func initialMapsAndSetsAreEmpty() {
        let c = seededCatalog()
        #expect(c.windowMap.isEmpty)
        #expect(c.anchorParked.isEmpty)
        #expect(c.originalPositions.isEmpty)
    }

    // MARK: - Reconcile

    @Test func reconcileAssignsNewWindowsToActive() {
        var c = seededCatalog()
        let r = c.reconcile(live: [window(10), window(20)])
        #expect(r.added == 2)
        #expect(r.removed == 0)
        #expect(Set(r.addedIDs) == [wid(10), wid(20)])
        #expect(r.removedIDs == [])
        #expect(c.windowMap[wid(10)]?.workspace == 1)
        #expect(c.windowMap[wid(20)]?.workspace == 1)
    }

    @Test func reconcileRecordsPidFromLiveWindow() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 4242)])
        #expect(c.windowMap[wid(10)]?.pid == 4242)
    }

    @Test func reconcileRefreshesPidWhenItChangesUnderTheSameID() {
        // Defensive: if a wsid is ever reused after its owner dies,
        // the fresh pid should win so subsequent AX calls don't
        // target a stale (or now-different) process.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 1000)])
        _ = c.reconcile(live: [window(10, pid: 2000)])
        #expect(c.windowMap[wid(10)]?.pid == 2000)
    }

    @Test func reconcileNewWindowsLandInCurrentActive() {
        // Switch to WS 3 first; new windows should land in 3.
        var c = seededCatalog()
        _ = c.setActive(3)
        _ = c.reconcile(live: [window(10)])
        #expect(c.windowMap[wid(10)]?.workspace == 3)
    }

    @Test func reconcileDropsGoneWindows() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        let r = c.reconcile(live: [window(10)])
        #expect(r.added == 0)
        #expect(r.removed == 1)
        #expect(r.addedIDs == [])
        #expect(r.removedIDs == [wid(20)],
                       "removed IDs surface the gone window")
        #expect(c.windowMap[wid(20)] == nil)
    }

    // MARK: - Trusted-new fast-path (two-tick gate)

    @Test func twoTickGateDefersUntrustedNewWindow() {
        // Under requireConfirm a new on-screen window waits for a
        // SECOND sighting before joining the map (swallows the
        // cross-mac-desktop `isOnscreen` flip during a mac-desktop switch).
        var c = seededCatalog()
        let r1 = c.reconcile(live: [window(10)], requireConfirm: true)
        #expect(r1.added == 0)
        #expect(r1.removed == 0)
        #expect(r1.addedIDs == [])
        #expect(c.windowMap[wid(10)] == nil)
        let r2 = c.reconcile(live: [window(10)], requireConfirm: true)
        #expect(r2.added == 1)
        #expect(r2.addedIDs == [wid(10)])
        #expect(c.windowMap[wid(10)]?.workspace == 1)
    }

    @Test func trustedNewWindowSkipsGate() {
        // A genuinely-new window (kAXWindowCreated → trusted) joins on
        // the FIRST sighting even under requireConfirm — this is the
        // add-latency win.
        var c = seededCatalog()
        let r = c.reconcile(live: [window(10)],
                            trusted: [wid(10)],
                            requireConfirm: true)
        #expect(r.added == 1)
        #expect(r.addedIDs == [wid(10)])
        #expect(c.windowMap[wid(10)]?.workspace == 1)
    }

    @Test func ignoreKeepsWindowUnmanaged() {
        // Config `action="ignore"` window never enters the map, and
        // stays out on later reconciles (marked examined) even once
        // the ignore hint is no longer supplied.
        var c = seededCatalog()
        let r = c.reconcile(live: [window(10), window(20)],
                            ignore: [wid(20)])
        #expect(r.added == 1)
        #expect(c.windowMap[wid(10)]?.workspace == 1)
        #expect(c.windowMap[wid(20)] == nil)
        let r2 = c.reconcile(live: [window(10), window(20)])
        #expect(r2.added == 0)
        #expect(c.windowMap[wid(20)] == nil)
    }

    @Test func deferredWindowSkippedButReProbedLater() {
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
        #expect(r1.added == 1, "only the resolved window joins")
        #expect(r1.addedIDs == [wid(10)])
        #expect(c.windowMap[wid(10)]?.workspace == 1)
        #expect(c.windowMap[wid(20)] == nil,
                     "deferred window skipped even when trusted")
        // Next tick: AX resolved → no longer deferred → adopted. Proves
        // the defer did NOT mark it examined (contrast: `ignore` does).
        let r2 = c.reconcile(live: [window(10), window(20)])
        #expect(r2.added == 1)
        #expect(r2.addedIDs == [wid(20)])
        #expect(c.windowMap[wid(20)]?.workspace == 1)
    }

    // MARK: - Layout insertion (append, not master)

    @Test func newWindowAppendsToStackNotMaster() {
        // A window joining a master-stack layout appends to the END of
        // the per-WS order (joins the stack) rather than seizing the
        // master slot (order[0]). The first-seen window stays master;
        // master is taken only by the explicit promoteToMaster.
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        _ = c.reconcile(live: [window(10)])
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        #expect(c.stackOrders[1] == [wid(10), wid(20), wid(30)],
                       "new windows append; first-seen stays master")
    }

    @Test func moveWindowIntoMasterStackAppendsBehindMaster() {
        // Moving a window into a populated master-stack WS appends it
        // behind the existing master — a move-in must not displace the
        // destination WS's established master either.
        var c = seededCatalog()
        _ = c.setMode(workspace: 2, to: "master-left", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)])      // both → WS1
        _ = c.setActive(2)
        _ = c.reconcile(live: [window(10), window(20), window(30)]) // 30 → WS2
        #expect(c.stackOrders[2] == [wid(30)])
        _ = c.moveWindow(wid(10), to: 2, in: displayRect)
        _ = c.moveWindow(wid(20), to: 2, in: displayRect)
        #expect(c.stackOrders[2] == [wid(30), wid(10), wid(20)],
                       "moved-in windows append behind the dest master")
    }

    @Test func newWindowInStackModeTakesTop() {
        // Stack ("one at a time") shows order[0] and parks the rest, so
        // a newly-opened window must take the TOP (index 0) — you see
        // what you just opened. (Contrast: the master-stack engines
        // append so a new window never seizes the master.)
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "stack", in: displayRect)
        _ = c.reconcile(live: [window(10)])
        _ = c.reconcile(live: [window(10), window(20)])
        #expect(c.stackOrders[1] == [wid(20), wid(10)],
                       "newest is the visible stack top")
    }

    @Test func trustedDoesNotOverrideOffScreenDefer() {
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
        #expect(r.added == 0)
        #expect(r.removed == 0)
        #expect(r.addedIDs == [])
        #expect(c.windowMap[wid(10)] == nil)
    }

    @Test func reconcileDoesNotMovePreexistingWindow() {
        // Window assigned to WS 3 must stay there even after
        // active flips back to 1 and reconcile runs.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.moveWindow(wid(10), to: 3)
        _ = c.setActive(2)
        _ = c.reconcile(live: [window(10)])
        #expect(c.windowMap[wid(10)]?.workspace == 3,
                       "reconcile must not reassign existing windows")
    }

    @Test func reconcileSweepsParkedSetsAndOriginalPositions() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.markAnchorParked(wid(10), originalPosition: .init(x: 1, y: 2))
        c.markAnchorParked(wid(20), originalPosition: .init(x: 3, y: 4))
        // wid(10) disappears (e.g. user closed the window).
        _ = c.reconcile(live: [window(20)])
        #expect(!c.anchorParked.contains(wid(10)))
        #expect(c.originalPositions[wid(10)] == nil)
        // wid(20) still alive → park state preserved.
        #expect(c.anchorParked.contains(wid(20)))
        #expect(c.originalPositions[wid(20)] != nil)
    }

    // MARK: - pid lookup

    @Test func pidForUnknownWindowIsNil() {
        #expect(seededCatalog().pid(for: wid(10)) == nil)
    }

    @Test func pidForKnownWindowMatchesLiveValue() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 1234)])
        #expect(c.pid(for: wid(10)) == 1234)
    }

    // MARK: - isValid (contiguous live set)

    @Test func isValidAcceptsLiveRange() {
        let c = seededCatalog()           // 5 contiguous workspaces
        #expect(c.isValid(1))
        #expect(c.isValid(5))
    }

    @Test func isValidRejectsBeyondCount() {
        let c = seededCatalog(3)          // positions 1...3
        #expect(c.isValid(3))
        #expect(!c.isValid(4),
                       "the live set is contiguous 1...count")
    }

    @Test func isValidRejectsZeroAndNegative() {
        let c = seededCatalog()
        #expect(!c.isValid(0))
        #expect(!c.isValid(-1))
    }

    // MARK: - activeWorkspacePredicateWindows (t-63h2 lens-desktop park lock-step)

    /// The park predicate must see the SAME management state the tree does.
    /// Before t-63h2 the park side overlaid ONLY tags, so `floating` / `mark`
    /// read false/nil and a lens `match` on those fields parked the wrong set.
    @Test func predicateWindowsCarryFullManagementState() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setFloating(wid(10), true)
        c.setMark("hero", to: wid(20))

        let ws = c.activeWorkspacePredicateWindows(
            live: [window(10), window(20)], focused: wid(20))
        let w10 = ws.first { $0.id == wid(10) }
        let w20 = ws.first { $0.id == wid(20) }
        // Raw live windows report isFloating from the fixture (false) and no
        // mark; the overlay replaces them with the catalog's authoritative
        // state — the whole point of the fix.
        #expect(w10?.isFloating == true, "catalog float overlaid, not the raw live false")
        #expect(w20?.mark == "hero", "catalog mark overlaid, not the raw live nil")
        #expect(w20?.isFocused == true, "focused id overlaid")
        #expect(w10?.mark == nil)
    }

    /// The lock-step guarantee end-to-end: a lens `match='floating'` parks
    /// exactly the NON-floating windows (the tree's non-members), not — as the
    /// old tags-only overlay did — every window on the desktop.
    @Test func floatingLensParksExactlyTheNonFloating() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setFloating(wid(20), true)     // 20 is the lens member

        let ws = c.activeWorkspacePredicateWindows(
            live: [window(10), window(20), window(30)], focused: nil)
        guard case .success(let lens) = FacetFilter.parse("floating") else {
            Issue.record("filter parse failed"); return
        }
        let parked = IsolatePark.parkSet(
            windows: ws, inWorkspaceNamed: c.workspaceName(c.activeIndex),
            lens: lens, sticky: c.everywhereWindows)
        #expect(Set(parked) == [wid(10), wid(30)],
                "only the non-floating windows park; the floating member stays")
    }

    // MARK: - setActive

    @Test func setActiveReturnsNilForCurrentWorkspace() {
        var c = seededCatalog()
        #expect(c.setActive(1) == nil,
                     "switching to current must be a no-op")
        #expect(c.activeIndex == 1)
    }

    @Test func setActiveReturnsNilForInvalidTarget() {
        var c = seededCatalog(3)
        #expect(c.setActive(6) == nil, "beyond the live count")
        #expect(c.activeIndex == 1, "rejected switch must not mutate")
    }

    @Test func setActiveReturnsSwitchPlanWithCorrectSets() {
        // Three windows: 10 in WS1, 20 in WS2, 30 in WS2.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 100),
                               window(20, pid: 200),
                               window(30, pid: 300)])
        _ = c.moveWindow(wid(20), to: 2)
        _ = c.moveWindow(wid(30), to: 2)
        // Switching 1 → 2: 10 should park, {20, 30} should restore.
        let plan = c.setActive(2)
        #expect(plan?.oldActive == 1)
        #expect(plan?.newActive == 2)
        #expect(plan?.toPark == [WindowRef(id: wid(10), pid: 100)])
        #expect(Set(plan?.toRestore ?? []) ==
                       [WindowRef(id: wid(20), pid: 200),
                        WindowRef(id: wid(30), pid: 300)])
        #expect(c.activeIndex == 2)
    }

    @Test func switchPlanCarriesPidFromCatalog() {
        // Specifically asserting the pid threading — even if pid
        // wasn't passed into setActive, the plan must include it
        // so the adapter can dispatch AX directly.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 9999)])
        let plan = c.setActive(2)
        #expect(plan?.toPark.first?.pid == 9999)
    }

    // MARK: - moveWindow

    @Test func moveWindowRejectsUnknownWindow() {
        var c = seededCatalog()
        let outcome = c.moveWindow(wid(99), to: 2)
        #expect(outcome == .rejected)
    }

    @Test func moveWindowRejectsInvalidTarget() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])
        // Target beyond the live workspace count is rejected.
        let outcome = c.moveWindow(wid(10), to: 99)
        #expect(outcome == .rejected)
        #expect(c.windowMap[wid(10)]?.workspace == 1,
                       "rejected move must not mutate")
    }

    @Test func moveWindowRejectsAlreadyOnTarget() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        let outcome = c.moveWindow(wid(10), to: 1)
        #expect(outcome == .rejected)
    }

    @Test func moveAwayFromActiveIsPark() {
        // Active = 1, window in 1 → move to 2 → park.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 777)])
        let outcome = c.moveWindow(wid(10), to: 2)
        #expect(outcome ==
                       .park(WindowRef(id: wid(10), pid: 777)))
        #expect(c.windowMap[wid(10)]?.workspace == 2)
        #expect(c.windowMap[wid(10)]?.pid == 777,
                       "pid must survive workspace reassignment")
    }

    @Test func moveIntoActiveIsRestore() {
        // Window starts in WS 2 (non-active). Move it to active=1.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10, pid: 555)])
        _ = c.moveWindow(wid(10), to: 2)
        let outcome = c.moveWindow(wid(10), to: 1)
        #expect(outcome ==
                       .restore(WindowRef(id: wid(10), pid: 555)))
    }

    @Test func moveBetweenInactiveWorkspacesIsStateOnly() {
        // Active = 1. Window in WS 2 → move to WS 3 → invisible to
        // user, only the assignment changes.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.moveWindow(wid(10), to: 2)
        let outcome = c.moveWindow(wid(10), to: 3)
        #expect(outcome == .stateOnly)
        #expect(c.windowMap[wid(10)]?.workspace == 3)
    }

    // MARK: - Anchor park bookkeeping

    @Test func shouldParkAnchorTrueWhenNotParked() {
        let c = seededCatalog()
        #expect(c.shouldParkAnchor(wid(10)))
    }

    @Test func shouldParkAnchorFalseAfterMark() {
        var c = seededCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        #expect(!c.shouldParkAnchor(wid(10)),
                       "double-park guard")
    }

    @Test func consumeAnchorRestoreReturnsAndClearsPosition() {
        var c = seededCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        #expect(c.consumeAnchorRestore(wid(10)) ==
                       .init(x: 5, y: 7))
        #expect(!c.anchorParked.contains(wid(10)))
        #expect(c.originalPositions[wid(10)] == nil)
    }

    @Test func consumeAnchorRestoreReturnsNilForNonParked() {
        var c = seededCatalog()
        #expect(c.consumeAnchorRestore(wid(10)) == nil,
                     "defensive against double-restore")
    }

    // MARK: - drop (closeWindow eviction)

    @Test func dropClearsAllTracesForWindow() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.markAnchorParked(wid(10), originalPosition: .init(x: 5, y: 7))
        c.drop(wid(10))
        #expect(c.windowMap[wid(10)] == nil)
        #expect(!c.anchorParked.contains(wid(10)))
        #expect(c.originalPositions[wid(10)] == nil)
    }

    @Test func dropIsIdempotent() {
        // Two paths: drop on a never-known id, and drop twice on
        // the same id. Both must leave the catalog in an empty
        // / consistent state (no crash, no stale entries).
        var c = seededCatalog()
        c.drop(wid(10))
        #expect(c.windowMap[wid(10)] == nil)
        #expect(!c.anchorParked.contains(wid(10)))

        _ = c.reconcile(live: [window(20)])
        c.drop(wid(20))
        c.drop(wid(20))
        #expect(c.windowMap[wid(20)] == nil)
        #expect(c.windowMap.count == 0)
    }

    // MARK: - Snapshot (0-based wire convention)

    @Test func snapshotTranslatesIndexTo0Based() {
        let c = seededCatalog()
        let snap = c.snapshot(
            live: [], focused: nil,
            activeRect: .zero)
        #expect(snap.map(\.index) == [0, 1, 2, 3, 4],
                       "snapshot must emit 0-based indexes")
    }

    @Test func snapshotMarksActiveWorkspace() {
        var c = seededCatalog()
        _ = c.setActive(3)
        let snap = c.snapshot(
            live: [], focused: nil,
            activeRect: .zero)
        #expect(snap.filter(\.isActive).map(\.index) == [2],
                       "0-based index 2 = 1-based 3")
    }

    @Test func snapshotPlacesWindowsInAssignedWorkspace() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.moveWindow(wid(20), to: 3)
        let snap = c.snapshot(
            live: [window(10), window(20)], focused: nil,
            activeRect: .zero)
        #expect(snap[0].windows.map(\.id) == [wid(10)])
        #expect(snap[2].windows.map(\.id) == [wid(20)])
        #expect(snap[1].windows.count == 0)
    }

    @Test func snapshotStampsFocusedFlag() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        let snap = c.snapshot(
            live: [window(10), window(20)],
            focused: wid(20),
            activeRect: .zero)
        let allWindows = snap.flatMap(\.windows)
        #expect(allWindows.first { $0.id == wid(20) }?.isFocused ==
                       true)
        #expect(allWindows.first { $0.id == wid(10) }?.isFocused ==
                       false)
    }

    @Test func snapshotSkipsWindowsNotInMap() {
        // Live windows that reconcile hasn't accepted (off-screen on
        // first sight, marked pre-existing at startup / mac-desktop change,
        // etc.) are filtered out of the per-WS snapshot. Previously
        // they fell back to `activeIndex` — that surfaced as the
        // "145 windows in WS1" bug after the `.optionAll` switch.
        var c = seededCatalog()
        _ = c.setActive(2)
        let snap = c.snapshot(
            live: [window(99)], focused: nil,
            activeRect: .zero)
        #expect(snap.flatMap(\.windows).count == 0)
    }

    // MARK: - Phase γ.1 — layout modes + floating + tile

    private let displayRect = CGRect(x: 0, y: 0,
                                     width: 1600, height: 900)

    @Test func defaultModeIsFloatForUnsetWorkspace() {
        #expect(seededCatalog().mode(of: 1) == "float")
    }

    @Test func setModeBspCreatesTreeFromCurrentMembers() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        #expect(c.mode(of: 1) == "bsp")
        let frames = c.tiledFrames(for: 1, in: displayRect)
        #expect(Set(frames.keys) == [wid(10), wid(20)])
    }

    @Test func setModeFloatDiscardsTree() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        #expect(c.layoutTrees[1] != nil)
        _ = c.setMode(workspace: 1, to: "float", in: displayRect)
        #expect(c.layoutTrees[1] == nil)
        #expect(c.tiledFrames(for: 1, in: displayRect) == [:])
    }

    @Test func setModeLowercasesInput() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "BSP", in: displayRect)
        #expect(c.mode(of: 1) == "bsp")
    }

    @Test func reconcileAutoInsertsNewWindowsIntoActiveBspTree() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        let frames = c.tiledFrames(for: 1, in: displayRect)
        #expect(Set(frames.keys) == [wid(10), wid(20)])
    }

    @Test func reconcileSkipsFloatingWindowsFromTree() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.toggleFloat(wid(10))
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        #expect(c.tiledFrames(for: 1, in: displayRect).isEmpty)
    }

    @Test func toggleFloatRemovesFromTreeAndReinserts() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        c.toggleFloat(wid(20))
        #expect(Set(c.tiledFrames(for: 1, in: displayRect).keys) ==
                       [wid(10)])
        #expect(c.isFloating(wid(20)))
        c.toggleFloat(wid(20), focused: wid(10), in: displayRect)
        #expect(Set(c.tiledFrames(for: 1, in: displayRect).keys) ==
                       [wid(10), wid(20)])
    }

    @Test func dropAlsoEvictsFromTree() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        c.drop(wid(10))
        #expect(Set(c.tiledFrames(for: 1, in: displayRect).keys) ==
                       [wid(20)])
    }

    @Test func reconcileGoneSweepHealsTree() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        _ = c.reconcile(live: [window(20)],
                        focused: nil, activeRect: displayRect)
        #expect(Set(c.tiledFrames(for: 1, in: displayRect).keys) ==
                       [wid(20)])
    }

    @Test func moveWindowBetweenBspWorkspacesMaintainsBothTrees() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.setMode(workspace: 2, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        let outcome = c.moveWindow(wid(20), to: 2,
                                   in: displayRect)
        #expect(outcome ==
                       .park(WindowRef(id: wid(20), pid: 1000)))
        #expect(Set(c.tiledFrames(for: 1, in: displayRect).keys) ==
                       [wid(10)])
        #expect(Set(c.tiledFrames(for: 2, in: displayRect).keys) ==
                       [wid(20)])
    }

    @Test func toggleOrientationDelegatesToOwningTree() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        let before = c.tiledFrames(for: 1, in: displayRect)
        #expect(before[wid(10)]?.width == 800,
                       "starts vertical-split")
        c.toggleOrientation(of: wid(10))
        let after = c.tiledFrames(for: 1, in: displayRect)
        #expect(after[wid(10)]?.width == 1600,
                       "horizontal-split after flip")
    }

    @Test func tiledFramesEmptyForFloatMode() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        #expect(c.tiledFrames(for: 1, in: displayRect) == [:])
    }

    @Test func snapshotPicksModePerWorkspace() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 2, to: "bsp", in: displayRect)
        let snap = c.snapshot(
            live: [], focused: nil,
            activeRect: .zero)
        #expect(snap[0].layoutMode == "float",
                       "WS 1 unset → float")
        #expect(snap[1].layoutMode == "bsp",
                       "WS 2 set to bsp")
    }

    // MARK: - Phase γ.2 — stack mode

    @Test func setModeStackCreatesOrderFromCurrentMembers() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(20), window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        // Members sort by id (deterministic) → [10, 20].
        #expect(c.stackOrder(of: 1) == [wid(10), wid(20)])
    }

    @Test func setModeStackSkipsFloatingMembers() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.toggleFloat(wid(20))
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        #expect(c.stackOrder(of: 1) == [wid(10)])
    }

    @Test func stackOrderEmptyForNonStackMode() {
        let c = seededCatalog()
        #expect(c.stackOrder(of: 1) == [])
    }

    @Test func reconcileNewWindowBecomesStackTop() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        // New window 20 must land at index 0 (Q7c).
        #expect(c.stackOrder(of: 1).first == wid(20))
    }

    @Test func cycleStackNextRotatesLeft() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        #expect(c.stackOrder(of: 1) ==
                       [wid(10), wid(20), wid(30)])
        let top = c.cycleStack(workspace: 1, direction: .next)
        #expect(top == wid(20))
        #expect(c.stackOrder(of: 1) ==
                       [wid(20), wid(30), wid(10)])
    }

    @Test func cycleStackPrevRotatesRight() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        let top = c.cycleStack(workspace: 1, direction: .prev)
        #expect(top == wid(30))
        #expect(c.stackOrder(of: 1) ==
                       [wid(30), wid(10), wid(20)])
    }

    @Test func cycleStackSingleMemberIsNoop() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        #expect(c.cycleStack(workspace: 1, direction: .next) == nil)
        #expect(c.stackOrder(of: 1) == [wid(10)])
    }

    @Test func cycleStackEmptyIsNoop() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        #expect(c.cycleStack(workspace: 1, direction: .next) == nil)
        #expect(c.stackOrder(of: 1) == [],
                       "empty order must stay empty post-cycle")
    }

    @Test func dropEvictsFromStackOrder() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        c.drop(wid(10))
        #expect(c.stackOrder(of: 1) == [wid(20)])
    }

    @Test func toggleFloatRemovesFromStackAndReadds() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "stack",
                      in: displayRect)
        c.toggleFloat(wid(20))
        #expect(c.stackOrder(of: 1) == [wid(10)])
        // Unfloat → returns to stack at top.
        c.toggleFloat(wid(20), focused: nil, in: displayRect)
        #expect(c.stackOrder(of: 1).first == wid(20))
    }

    @Test func moveWindowIntoStackPutsItOnTop() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 2, to: "stack",
                      in: displayRect)
        _ = c.reconcile(live: [window(10)])
        // 10 is in WS 1 (active default). Move into WS 2 stack.
        _ = c.moveWindow(wid(10), to: 2, in: displayRect)
        #expect(c.stackOrder(of: 2) == [wid(10)])
    }

    @Test func setModeFlipWithFiveMembersPreservesAllAcrossBspStackBsp() {
        // Mode flipping a populated WS shouldn't drop members.
        // BSP → Stack → BSP with 5 windows: every id survives,
        // and the final BSP tree contains the same id set.
        var c = seededCatalog()
        _ = c.reconcile(live: (10...14).map { window($0) })
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        let bspIDs = Set(c.tiledFrames(for: 1, in: displayRect).keys)
        #expect(bspIDs.count == 5)
        _ = c.setMode(workspace: 1, to: "stack", in: displayRect)
        #expect(Set(c.stackOrder(of: 1)) ==
                       Set((10...14).map(wid)),
                       "stack must inherit all bsp members")
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        let bspIDs2 = Set(c.tiledFrames(for: 1, in: displayRect).keys)
        #expect(bspIDs2 == bspIDs,
                       "round-trip bsp→stack→bsp preserves the id set in the tree")
    }

    @Test func setModeFlipReplacesLayoutKind() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        // BSP → stack: tree gone, order built.
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        #expect(c.layoutTrees[1] != nil)
        _ = c.setMode(workspace: 1, to: "stack", in: displayRect)
        #expect(c.layoutTrees[1] == nil)
        #expect(c.stackOrder(of: 1).sorted { $0.serverID < $1.serverID } ==
                       [wid(10), wid(20)])
        // Stack → BSP: order gone, tree built.
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        #expect(c.stackOrders[1] == nil)
        #expect(c.layoutTrees[1] != nil)
    }

    // MARK: - Theme B — tall / stateless-engine shared order

    @Test func setModeTallSeedsSharedOrderFromMembers() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(20), window(10)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        // Stateless engines reuse the stack order; seeded id-sorted.
        #expect(c.stackOrder(of: 1) == [wid(10), wid(20)])
        #expect(c.layoutTrees[1] == nil, "tall must discard any tree")
    }

    @Test func reconcileNewWindowDoesNotSeizeTallMaster() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        _ = c.reconcile(live: [window(10), window(20)],
                        focused: nil, activeRect: displayRect)
        // New window APPENDS — the established master (10) keeps the
        // slot; the newcomer joins the stack. Master is taken only by
        // the explicit promoteToMaster.
        #expect(c.stackOrder(of: 1) == [wid(10), wid(20)])
        #expect(c.stackOrder(of: 1).first == wid(10),
                       "first-seen window keeps the master slot")
    }

    @Test func promoteToMasterMovesChosenWindowToFront() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        #expect(c.stackOrder(of: 1) ==
                       [wid(10), wid(20), wid(30)])
        let promoted = c.promoteToMaster(wid(30), workspace: 1)
        #expect(promoted)
        #expect(c.stackOrder(of: 1) ==
                       [wid(30), wid(10), wid(20)])
    }

    @Test func promoteToMasterAlreadyMasterIsNoop() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        let promoted = c.promoteToMaster(wid(10), workspace: 1)
        #expect(!promoted,
                       "already at index 0 → no change")
        #expect(c.stackOrder(of: 1) == [wid(10), wid(20)])
    }

    @Test func promoteToMasterUnknownWindowIsNoop() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        let promoted = c.promoteToMaster(wid(99), workspace: 1)
        #expect(!promoted)
    }

    @Test func orderedMembersReflectsSharedOrder() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20), window(30)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        _ = c.promoteToMaster(wid(30), workspace: 1)
        #expect(c.orderedMembers(of: 1) ==
                       [wid(30), wid(10), wid(20)])
    }

    @Test func tallDropEvictsFromSharedOrder() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        c.drop(wid(10))
        #expect(c.stackOrder(of: 1) == [wid(20)])
    }

    // MARK: - Theme B — master knobs (ratio / count)

    @Test func defaultParamsAreNeutral() {
        let c = seededCatalog()
        #expect(c.params(of: 1).masterRatio == 0.5)
        #expect(c.params(of: 1).masterCount == 1)
    }

    @Test func adjustMasterRatioNudgesAndClamps() {
        var c = seededCatalog()
        let nudged = c.adjustMasterRatio(workspace: 1, delta: 0.05)
        #expect(nudged)
        #expect(abs(c.params(of: 1).masterRatio - 0.55) < 1e-9)
        // Drive up to the 0.95 clamp; the boundary nudge returns false.
        for _ in 0..<20 { _ = c.adjustMasterRatio(workspace: 1, delta: 0.05) }
        #expect(abs(c.params(of: 1).masterRatio - 0.95) < 1e-9)
        let clamped = c.adjustMasterRatio(workspace: 1, delta: 0.05)
        #expect(!clamped,
                       "no change at the clamp → false (skip re-tile)")
    }

    @Test func adjustMasterCountNudgesAndClampsAtOne() {
        var c = seededCatalog()
        let bumped = c.adjustMasterCount(workspace: 1, delta: 1)
        #expect(bumped)
        #expect(c.params(of: 1).masterCount == 2)
        let lowered = c.adjustMasterCount(workspace: 1, delta: -1)
        #expect(lowered)
        #expect(c.params(of: 1).masterCount == 1)
        let clamped = c.adjustMasterCount(workspace: 1, delta: -1)
        #expect(!clamped,
                       "clamped at 1 → no change")
    }

    @Test func paramsPersistAcrossModeFlip() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)   // → 0.6
        _ = c.setMode(workspace: 1, to: "grid", in: displayRect)
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        #expect(abs(c.params(of: 1).masterRatio - 0.6) < 1e-9,
                       "ratio remembered across a mode round-trip")
    }

    @Test func engineFramesReflectAdjustedRatio() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: "master-left", in: displayRect)
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)   // 0.5 → 0.6
        let frames = c.engineFrames(for: 1, in: displayRect)
        // Master (lower id = order[0]) gets 0.6 * 1600 = 960 wide.
        #expect(abs((frames[wid(10)]?.width ?? 0) - 960) < 1e-9)
    }

    // MARK: - Phase γ.3 — autoFloat reconcile hint

    @Test func reconcileAutoFloatMarksNewWindowFloating() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)],
                        autoFloat: [wid(10)])
        #expect(c.isFloating(wid(10)))
    }

    @Test func reconcileAutoFloatSkipsTreeInsert() {
        // BSP active WS. A new auto-floating window must NOT
        // enter the tree.
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "bsp", in: displayRect)
        _ = c.reconcile(live: [window(10)],
                        focused: nil, activeRect: displayRect,
                        autoFloat: [wid(10)])
        #expect(c.isFloating(wid(10)))
        #expect(c.tiledFrames(for: 1, in: displayRect).isEmpty)
    }

    @Test func reconcileAutoFloatSkipsStackInsert() {
        var c = seededCatalog()
        _ = c.setMode(workspace: 1, to: "stack", in: displayRect)
        _ = c.reconcile(live: [window(10)],
                        focused: nil, activeRect: displayRect,
                        autoFloat: [wid(10)])
        #expect(c.isFloating(wid(10)))
        #expect(c.stackOrder(of: 1) == [])
    }

    @Test func reconcileAutoFloatIsNoopForKnownWindow() {
        // autoFloat hint must NOT flip floating state on a
        // window the catalog already knows about — user's
        // toggleFloat decision stays authoritative.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        #expect(!c.isFloating(wid(10)))
        // Subsequent reconcile with autoFloat set should NOT
        // promote a known-non-floating window to floating.
        _ = c.reconcile(live: [window(10)],
                        autoFloat: [wid(10)])
        #expect(!c.isFloating(wid(10)),
                       "autoFloat is a first-sight hint, not a policy override")
    }

    @Test func reconcileAutoFloatTakesEffectInNonActiveWorkspace() {
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
        #expect(c.isFloating(wid(10)),
                      "autoFloat must work in non-WS-1 contexts")
        #expect(c.tiledFrames(for: 3, in: displayRect) == [:],
                       "floating new window must skip the WS3 tree")
    }

    // MARK: - Misc state helpers

    @Test func clearParkedStateDropsAllHideFlags() {
        var c = seededCatalog()
        c.markAnchorParked(wid(10), originalPosition: .init(x: 1, y: 2))
        c.clearParkedState(of: wid(10))
        #expect(!c.anchorParked.contains(wid(10)))
        #expect(c.originalPositions[wid(10)] == nil)
    }

    @Test func snapshotStampsIsFloating() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.toggleFloat(wid(10))
        let snap = c.snapshot(
            live: [window(10), window(20)], focused: nil,
            activeRect: .zero)
        let allWindows = snap.flatMap(\.windows)
        #expect(allWindows.first { $0.id == wid(10) }?.isFloating ==
                       true)
        #expect(allWindows.first { $0.id == wid(20) }?.isFloating ==
                       false)
    }

    @Test func snapshotUsesSeededNamesCompactedToContiguous() {
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
        #expect(snap.map(\.index) == [0, 1, 2])
        #expect(snap.map(\.name) == ["dev", "ide", "sns"])
    }

    // MARK: - nil-ordinal seed-taint recovery (fix/desktop-n-nil-ordinal)

    @Test func holdsOnlyUnnamedSlotsDistinguishesStates() {
        // Fresh (unseeded) catalog: NOT degenerate (it can still seed).
        let fresh = WorkspaceCatalog()
        #expect(!fresh.holdsOnlyUnnamedSlots)

        // nil-ordinal seed → defaultWorkspaceCount empty-name slots: degenerate.
        var tainted = WorkspaceCatalog()
        tainted.seed(configs: (1...5).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        #expect(tainted.holdsOnlyUnnamedSlots)

        // A catalog with ≥1 real name: NOT degenerate.
        var named = WorkspaceCatalog()
        named.seed(configs: [(index: 1, config: WorkspaceConfig(name: "Dev"))])
        #expect(!named.holdsOnlyUnnamedSlots)
    }

    @Test func userRenameMakesCatalogIneligibleForReset() {
        // The recovery predicate must NOT fire after a runtime rename — the
        // user's mutation has to survive (config is only the read-only seed).
        var c = WorkspaceCatalog()
        c.seed(configs: (1...5).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        #expect(c.holdsOnlyUnnamedSlots)
        c.renameWorkspace(1, to: "Dev")
        #expect(!c.holdsOnlyUnnamedSlots,
                       "a renamed workspace makes the catalog non-degenerate")
    }

    @Test func freshReseedAfterNilOrdinalLandsNamesAndLayout() {
        // Documents the bug + the fix's recovery shape. `seed` is idempotent,
        // so a tainted catalog cannot self-correct — only the adapter's
        // discard-and-reseed (a FRESH catalog) restores names + layout.
        var tainted = WorkspaceCatalog()
        tainted.seed(configs: (1...5).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        // Idempotence guard: a second seed on the tainted catalog is a no-op.
        tainted.seed(configs: [(index: 1, config: WorkspaceConfig(name: "Dev"))])
        #expect(tainted.holdsOnlyUnnamedSlots,
                      "seed() alone cannot correct a tainted catalog")

        // The fix: discard (fresh catalog), then re-seed with the resolved
        // ordinal's named config — names AND per-WS layout land.
        var recovered = WorkspaceCatalog()
        recovered.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "Dev", layout: "bsp")),
            (index: 2, config: WorkspaceConfig(name: "Web")),
            (index: 3, config: WorkspaceConfig(name: "Notes")),
        ])
        #expect(recovered.workspaceNames == ["Dev", "Web", "Notes"])
        #expect(!recovered.holdsOnlyUnnamedSlots)
        #expect(recovered.mode(of: 1) == "bsp")
    }

    /// §B regression: a section desktop of UNNAMED workspaces seeded under a
    /// REAL ordinal is all-empty (`holdsOnlyUnnamedSlots`) yet must NOT be
    /// eligible for nil-ordinal recovery — `seededUnderNilOrdinal` is the
    /// discriminator. Without it the adapter recovery would re-fire every
    /// refresh and wipe activeIndex / windowMap / layout for the default config.
    @Test func realOrdinalUnnamedSeedIsNotTaintEligible() {
        var healthy = WorkspaceCatalog()
        healthy.seed(configs: (1...3).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        }, underNilOrdinal: false)
        #expect(healthy.holdsOnlyUnnamedSlots)     // all unnamed (§B default)
        #expect(!healthy.seededUnderNilOrdinal)    // but seeded under a real ordinal
        // → adapter recovery (flag && holdsOnlyUnnamedSlots) does NOT fire.

        var tainted = WorkspaceCatalog()
        tainted.seed(configs: (1...5).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        }, underNilOrdinal: true)
        #expect(tainted.seededUnderNilOrdinal)      // genuine nil-ordinal seed
        #expect(tainted.holdsOnlyUnnamedSlots)
    }
}
