import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for scratchpad shelves in `WorkspaceCatalog`
/// (`facet scratchpad --stash/--toggle/--release=NAME`). A scratchpad
/// is a named hidden shelf (1:1 name ⇄ window, like marks) built on the
/// reused anchor-park + force-floating machinery: a *stashed* window is
/// parked off-screen and stays parked through every WS switch; a
/// *summoned* one settles onto the current WS as a floating overlay. All
/// AX side-effects live in the adapter; here we cover the catalog state
/// machine without AX / AppKit / OS.
final class WindowScratchpadTests: XCTestCase {

    // MARK: - Helpers

    private let rect = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - stash

    func testStashShelvesForcesFloatingAndMarksStashed() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        XCTAssertTrue(c.stashWindow("term", id: wid(10)))
        XCTAssertEqual(c.window(forScratchpad: "term"), wid(10))
        XCTAssertEqual(c.scratchpad(forWindow: wid(10)), "term")
        XCTAssertTrue(c.isStashed(wid(10)))
        XCTAssertTrue(c.isFloating(wid(10)),
                      "a stashed window is force-floating (overlay)")
    }

    func testStashUnknownWindowIsNoOp() {
        var c = seededCatalog()
        XCTAssertFalse(c.stashWindow("term", id: wid(99)),
                       "stashing an unmanaged window must no-op")
        XCTAssertNil(c.window(forScratchpad: "term"))
    }

    func testStashExcludesFromTiling() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.stashWindow("term", id: wid(10))
        XCTAssertEqual(c.nonFloatingMembers(of: 1), [wid(20)],
                       "a stashed (floating, detached) window doesn't tile")
    }

    func testStashBijectionEvictsNamesOldWindow() {
        // Re-stashing the same name onto a different window un-shelves the
        // previous occupant (1:1 name ⇄ window).
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.stashWindow("term", id: wid(10))
        _ = c.stashWindow("term", id: wid(20))
        XCTAssertEqual(c.window(forScratchpad: "term"), wid(20))
        XCTAssertFalse(c.isStashed(wid(10)),
                       "the evicted window is no longer stashed")
        XCTAssertNil(c.scratchpad(forWindow: wid(10)))
    }

    func testStashBijectionMovesWindowsOldShelf() {
        // Stashing a window already on shelf "a" under name "b" leaves it
        // on "b" only (a window holds at most one shelf entry).
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("a", id: wid(10))
        _ = c.stashWindow("b", id: wid(10))
        XCTAssertNil(c.window(forScratchpad: "a"))
        XCTAssertEqual(c.window(forScratchpad: "b"), wid(10))
        XCTAssertEqual(c.scratchpad(forWindow: wid(10)), "b")
    }

    // MARK: - XOR with sticky

    func testStashClearsSticky() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.setSticky(wid(10))
        _ = c.stashWindow("term", id: wid(10))
        XCTAssertFalse(c.isSticky(wid(10)),
                       "stashing a sticky window drops sticky (XOR)")
        XCTAssertTrue(c.isStashed(wid(10)))
    }

    func testSetStickyClearsScratchpad() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        c.setSticky(wid(10))
        XCTAssertNil(c.scratchpad(forWindow: wid(10)),
                     "making a shelf window sticky drops the shelf (XOR)")
        XCTAssertFalse(c.isStashed(wid(10)))
        XCTAssertTrue(c.isSticky(wid(10)))
    }

    // MARK: - Visibility predicate (the toggle branch)

    func testStashedWindowIsNotVisibleHere() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        XCTAssertFalse(c.isScratchpadVisibleHere("term"),
                       "a stashed window isn't visible on any WS")
    }

    func testSummonedWindowIsVisibleHereThenNotAfterSwitch() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        _ = c.summonScratchpad("term")             // onto WS1 (active)
        XCTAssertTrue(c.isScratchpadVisibleHere("term"),
                      "settled on the active WS → visible here")
        _ = c.setActive(2)
        XCTAssertFalse(c.isScratchpadVisibleHere("term"),
                       "settled on WS1 but now on WS2 → not visible here")
    }

    func testVisibleHereForUnsetShelfIsFalse() {
        let c = seededCatalog()
        XCTAssertFalse(c.isScratchpadVisibleHere("nope"))
    }

    // MARK: - summon (settle)

    func testSummonReHomesToActiveAndStaysFloating() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        _ = c.stashWindow("term", id: wid(10))
        _ = c.setActive(3)                         // user is on WS3
        let id = c.summonScratchpad("term")
        XCTAssertEqual(id, wid(10))
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 3,
                       "summon re-homes the window to the active WS")
        XCTAssertFalse(c.isStashed(wid(10)),
                       "a summoned window is settled, not stashed")
        XCTAssertTrue(c.isFloating(wid(10)),
                      "settle = floating overlay (Q2)")
    }

    func testSummonUnsetShelfReturnsNil() {
        var c = seededCatalog()
        XCTAssertNil(c.summonScratchpad("nope"))
    }

    // MARK: - restash (toggle off)

    func testRestashMarksStashedAgainAndDetaches() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        _ = c.summonScratchpad("term")
        let id = c.restashScratchpad("term")
        XCTAssertEqual(id, wid(10))
        XCTAssertTrue(c.isStashed(wid(10)))
        XCTAssertEqual(c.window(forScratchpad: "term"), wid(10),
                       "re-park keeps the shelf entry")
    }

    // MARK: - release

    func testReleaseDropsShelfReHomesAndUnfloats() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        _ = c.stashWindow("term", id: wid(10))
        _ = c.setActive(2)                         // user on WS2
        let id = c.releaseScratchpad("term", focused: wid(10), in: rect)
        XCTAssertEqual(id, wid(10))
        XCTAssertNil(c.window(forScratchpad: "term"),
                     "release drops the shelf entry")
        XCTAssertFalse(c.isStashed(wid(10)))
        XCTAssertFalse(c.isFloating(wid(10)),
                       "release lands it as a normal (non-floating) window")
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 2,
                       "release re-homes to the active WS (Q4)")
    }

    func testReleaseUnsetShelfReturnsNil() {
        var c = seededCatalog()
        XCTAssertNil(c.releaseScratchpad("nope"))
    }

    // MARK: - Float-exit = scratchpad-exit (Q13)

    func testToggleFloatOnSettledScratchpadReleasesIt() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        _ = c.summonScratchpad("term")             // settled, floating on WS1
        c.toggleFloat(wid(10), focused: wid(10), in: rect)
        XCTAssertNil(c.scratchpad(forWindow: wid(10)),
                     "float-exit releases the shelf (Q13)")
        XCTAssertFalse(c.isFloating(wid(10)),
                       "...and lands it as a tiled window")
    }

    // MARK: - WS-switch plan excludes stashed (the correctness point)

    func testSwitchPlanExcludesStashedFromParkAndRestore() {
        // A stashed window is already parked on the shelf and must stay
        // parked through every switch — it must appear in neither the
        // park list (don't double-park) nor, crucially, the restore list
        // (restoring it would un-hide the shelf when its home WS reopens).
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])  // both home = WS1
        _ = c.stashWindow("term", id: wid(10))
        let plan = c.setActive(2)
        let parked = Set((plan?.toPark ?? []).map(\.id))
        XCTAssertFalse(parked.contains(wid(10)),
                       "a stashed window must not be in the park list")
        XCTAssertTrue(parked.contains(wid(20)),
                      "a normal window still parks on leave")
        let back = c.setActive(1)
        let restored = Set((back?.toRestore ?? []).map(\.id))
        XCTAssertFalse(restored.contains(wid(10)),
                       "a stashed window must NEVER be restored")
        XCTAssertTrue(restored.contains(wid(20)),
                      "a normal window restores on return")
    }

    // MARK: - Not movable while stashed

    func testStashedWindowRejectsMoveToWorkspace() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        _ = c.stashWindow("term", id: wid(10))
        let outcome = c.moveWindow(wid(10), to: 3)
        XCTAssertEqual(outcome, .rejected,
                       "a stashed window lives on the shelf — can't move it")
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 1,
                       "the rejected move must not relocate its home WS")
    }

    // MARK: - Prune on close

    func testScratchpadPrunedWhenWindowCloses() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        c.drop(wid(10))                            // forgetWindow
        XCTAssertNil(c.window(forScratchpad: "term"),
                     "closing the window prunes its shelf entry")
        XCTAssertFalse(c.isStashed(wid(10)))
    }

    // MARK: - status names

    func testStashedNamesListsStashedOnlyNotSettled() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.stashWindow("hidden", id: wid(10))
        _ = c.stashWindow("shown", id: wid(20))
        _ = c.summonScratchpad("shown")            // now settled
        XCTAssertEqual(c.stashedScratchpadNames(), ["hidden"],
                       "status lists stashed (hidden) shelves only")
    }

    // MARK: - Snapshot

    func testSnapshotOmitsStashedAndStampsSettled() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.stashWindow("term", id: wid(10))
        // Stashed: absent from the tree entirely.
        let s1 = c.snapshot(live: [window(10), window(20)],
                            focused: nil, activeRect: rect)
        let ws1 = s1.first { $0.index == 0 }
        XCTAssertNil(ws1?.windows.first { $0.id == wid(10) },
                     "a stashed window is filtered out of the snapshot")
        XCTAssertNotNil(ws1?.windows.first { $0.id == wid(20) })
        // Settled: present with its shelf name stamped.
        _ = c.summonScratchpad("term")
        let s2 = c.snapshot(live: [window(10), window(20)],
                            focused: nil, activeRect: rect)
        let w10 = s2.first { $0.index == 0 }?
            .windows.first { $0.id == wid(10) }
        XCTAssertEqual(w10?.scratchpad, "term",
                       "a settled scratchpad window carries its shelf name")
    }

    // MARK: - Orthogonal to marks

    func testScratchpadAndMarkCoexist() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        c.setMark("a", to: wid(10))
        XCTAssertEqual(c.scratchpad(forWindow: wid(10)), "term")
        XCTAssertEqual(c.mark(forWindow: wid(10)), "a",
                       "a window can be both stashed and marked")
    }
}
