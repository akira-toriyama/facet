import CoreGraphics
import Testing
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
struct WindowScratchpadTests {

    // MARK: - Helpers

    private let rect = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - stash

    @Test func stashShelvesForcesFloatingAndMarksStashed() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        let stashed = c.stashWindow("term", id: wid(10))
        #expect(stashed)
        #expect(c.window(forScratchpad: "term") == wid(10))
        #expect(c.scratchpad(forWindow: wid(10)) == "term")
        #expect(c.isStashed(wid(10)))
        #expect(c.isFloating(wid(10)),
                      "a stashed window is force-floating (overlay)")
    }

    @Test func stashUnknownWindowIsNoOp() {
        var c = seededCatalog()
        let stashed = c.stashWindow("term", id: wid(99))
        #expect(!stashed,
                       "stashing an unmanaged window must no-op")
        #expect(c.window(forScratchpad: "term") == nil)
    }

    @Test func stashExcludesFromTiling() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.stashWindow("term", id: wid(10))
        #expect(c.nonFloatingMembers(of: 1) == [wid(20)],
                       "a stashed (floating, detached) window doesn't tile")
    }

    @Test func stashBijectionEvictsNamesOldWindow() {
        // Re-stashing the same name onto a different window un-shelves the
        // previous occupant (1:1 name ⇄ window).
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.stashWindow("term", id: wid(10))
        _ = c.stashWindow("term", id: wid(20))
        #expect(c.window(forScratchpad: "term") == wid(20))
        #expect(!c.isStashed(wid(10)),
                       "the evicted window is no longer stashed")
        #expect(c.scratchpad(forWindow: wid(10)) == nil)
    }

    @Test func stashBijectionMovesWindowsOldShelf() {
        // Stashing a window already on shelf "a" under name "b" leaves it
        // on "b" only (a window holds at most one shelf entry).
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("a", id: wid(10))
        _ = c.stashWindow("b", id: wid(10))
        #expect(c.window(forScratchpad: "a") == nil)
        #expect(c.window(forScratchpad: "b") == wid(10))
        #expect(c.scratchpad(forWindow: wid(10)) == "b")
    }

    // MARK: - XOR with sticky

    @Test func stashClearsSticky() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.setSticky(wid(10))
        _ = c.stashWindow("term", id: wid(10))
        #expect(!c.isSticky(wid(10)),
                       "stashing a sticky window drops sticky (XOR)")
        #expect(c.isStashed(wid(10)))
    }

    @Test func setStickyClearsScratchpad() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        c.setSticky(wid(10))
        #expect(c.scratchpad(forWindow: wid(10)) == nil,
                     "making a shelf window sticky drops the shelf (XOR)")
        #expect(!c.isStashed(wid(10)))
        #expect(c.isSticky(wid(10)))
    }

    // MARK: - Visibility predicate (the toggle branch)

    @Test func stashedWindowIsNotVisibleHere() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        #expect(!c.isScratchpadVisibleHere("term"),
                       "a stashed window isn't visible on any WS")
    }

    @Test func summonedWindowIsVisibleHereThenNotAfterSwitch() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        _ = c.summonScratchpad("term")             // onto WS1 (active)
        #expect(c.isScratchpadVisibleHere("term"),
                      "settled on the active WS → visible here")
        _ = c.setActive(2)
        #expect(!c.isScratchpadVisibleHere("term"),
                       "settled on WS1 but now on WS2 → not visible here")
    }

    @Test func visibleHereForUnsetShelfIsFalse() {
        let c = seededCatalog()
        #expect(!c.isScratchpadVisibleHere("nope"))
    }

    // MARK: - summon (settle)

    @Test func summonReHomesToActiveAndStaysFloating() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        _ = c.stashWindow("term", id: wid(10))
        _ = c.setActive(3)                         // user is on WS3
        let id = c.summonScratchpad("term")
        #expect(id == wid(10))
        #expect(c.windowMap[wid(10)]?.workspace == 3,
                       "summon re-homes the window to the active WS")
        #expect(!c.isStashed(wid(10)),
                       "a summoned window is settled, not stashed")
        #expect(c.isFloating(wid(10)),
                      "settle = floating overlay (Q2)")
    }

    @Test func summonUnsetShelfReturnsNil() {
        var c = seededCatalog()
        #expect(c.summonScratchpad("nope") == nil)
    }

    // MARK: - restash (toggle off)

    @Test func restashMarksStashedAgainAndDetaches() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        _ = c.summonScratchpad("term")
        let id = c.restashScratchpad("term")
        #expect(id == wid(10))
        #expect(c.isStashed(wid(10)))
        #expect(c.window(forScratchpad: "term") == wid(10),
                       "re-park keeps the shelf entry")
    }

    // MARK: - release

    @Test func releaseDropsShelfReHomesAndUnfloats() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        _ = c.stashWindow("term", id: wid(10))
        _ = c.setActive(2)                         // user on WS2
        let id = c.releaseScratchpad("term", focused: wid(10), in: rect)
        #expect(id == wid(10))
        #expect(c.window(forScratchpad: "term") == nil,
                     "release drops the shelf entry")
        #expect(!c.isStashed(wid(10)))
        #expect(!c.isFloating(wid(10)),
                       "release lands it as a normal (non-floating) window")
        #expect(c.windowMap[wid(10)]?.workspace == 2,
                       "release re-homes to the active WS (Q4)")
    }

    @Test func releaseUnsetShelfReturnsNil() {
        var c = seededCatalog()
        #expect(c.releaseScratchpad("nope") == nil)
    }

    // MARK: - Float-exit = scratchpad-exit (Q13)

    @Test func toggleFloatOnSettledScratchpadReleasesIt() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        _ = c.summonScratchpad("term")             // settled, floating on WS1
        c.toggleFloat(wid(10), focused: wid(10), in: rect)
        #expect(c.scratchpad(forWindow: wid(10)) == nil,
                     "float-exit releases the shelf (Q13)")
        #expect(!c.isFloating(wid(10)),
                       "...and lands it as a tiled window")
    }

    // MARK: - WS-switch plan excludes stashed (the correctness point)

    @Test func switchPlanExcludesStashedFromParkAndRestore() {
        // A stashed window is already parked on the shelf and must stay
        // parked through every switch — it must appear in neither the
        // park list (don't double-park) nor, crucially, the restore list
        // (restoring it would un-hide the shelf when its home WS reopens).
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])  // both home = WS1
        _ = c.stashWindow("term", id: wid(10))
        let plan = c.setActive(2)
        let parked = Set((plan?.toPark ?? []).map(\.id))
        #expect(!parked.contains(wid(10)),
                       "a stashed window must not be in the park list")
        #expect(parked.contains(wid(20)),
                      "a normal window still parks on leave")
        let back = c.setActive(1)
        let restored = Set((back?.toRestore ?? []).map(\.id))
        #expect(!restored.contains(wid(10)),
                       "a stashed window must NEVER be restored")
        #expect(restored.contains(wid(20)),
                      "a normal window restores on return")
    }

    // MARK: - Not movable while stashed

    @Test func stashedWindowRejectsMoveToWorkspace() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        _ = c.stashWindow("term", id: wid(10))
        let outcome = c.moveWindow(wid(10), to: 3)
        #expect(outcome == .rejected,
                       "a stashed window lives on the shelf — can't move it")
        #expect(c.windowMap[wid(10)]?.workspace == 1,
                       "the rejected move must not relocate its home WS")
    }

    // MARK: - Prune on close

    @Test func scratchpadPrunedWhenWindowCloses() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        c.drop(wid(10))                            // forgetWindow
        #expect(c.window(forScratchpad: "term") == nil,
                     "closing the window prunes its shelf entry")
        #expect(!c.isStashed(wid(10)))
    }

    // MARK: - status names

    @Test func stashedNamesListsStashedOnlyNotSettled() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.stashWindow("hidden", id: wid(10))
        _ = c.stashWindow("shown", id: wid(20))
        _ = c.summonScratchpad("shown")            // now settled
        #expect(c.stashedScratchpadNames() == ["hidden"],
                       "status lists stashed (hidden) shelves only")
    }

    // MARK: - Snapshot

    @Test func snapshotOmitsStashedAndStampsSettled() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.stashWindow("term", id: wid(10))
        // Stashed: absent from the tree entirely.
        let s1 = c.snapshot(live: [window(10), window(20)],
                            focused: nil, activeRect: rect)
        let ws1 = s1.first { $0.index == 0 }
        #expect(ws1?.windows.first { $0.id == wid(10) } == nil,
                     "a stashed window is filtered out of the snapshot")
        #expect(ws1?.windows.first { $0.id == wid(20) } != nil)
        // Settled: present with its shelf name stamped.
        _ = c.summonScratchpad("term")
        let s2 = c.snapshot(live: [window(10), window(20)],
                            focused: nil, activeRect: rect)
        let w10 = s2.first { $0.index == 0 }?
            .windows.first { $0.id == wid(10) }
        #expect(w10?.scratchpad == "term",
                       "a settled scratchpad window carries its shelf name")
    }

    // MARK: - Orthogonal to marks

    @Test func scratchpadAndMarkCoexist() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        _ = c.stashWindow("term", id: wid(10))
        c.setMark("a", to: wid(10))
        #expect(c.scratchpad(forWindow: wid(10)) == "term")
        #expect(c.mark(forWindow: wid(10)) == "a",
                       "a window can be both stashed and marked")
    }
}
