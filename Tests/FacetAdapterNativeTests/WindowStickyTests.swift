import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for sticky windows in `WorkspaceCatalog`
/// (`facet window --toggle-sticky`). Sticky = pinned visible across
/// every facet workspace in the mac desktop, built on two reused
/// invariants: park-exempt (`shouldParkAnchor`) + force-floating
/// (`floatingWindows`). All AX side-effects live in the adapter; here
/// we cover the catalog state machine without AX / AppKit / OS.
struct WindowStickyTests {

    // MARK: - setSticky

    @Test func setStickyMarksAndForcesFloating() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.setSticky(wid(10))
        #expect(c.isSticky(wid(10)))
        #expect(c.isFloating(wid(10)),
                      "a sticky window is force-floating (Q2)")
    }

    @Test func setStickyUnknownWindowIsNoOp() {
        var c = seededCatalog()
        c.setSticky(wid(99))                   // never reconciled
        #expect(!c.isSticky(wid(99)))
        #expect(!c.isFloating(wid(99)))
    }

    @Test func setStickyIsIdempotent() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.setSticky(wid(10))
        c.setSticky(wid(10))
        #expect(c.isSticky(wid(10)))
    }

    @Test func stickyExcludedFromTiling() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.setSticky(wid(10))
        #expect(c.nonFloatingMembers(of: 1) == [wid(20)],
                       "the sticky (floating) window must not tile")
    }

    // MARK: - Park exemption (the visibility chokepoint)

    @Test func stickyWindowIsParkExempt() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.setSticky(wid(10))
        #expect(!c.shouldParkAnchor(wid(10)),
                       "sticky windows are never parked on a WS switch")
        #expect(c.shouldParkAnchor(wid(20)),
                      "a normal, unparked window still parks")
    }

    @Test func switchPlanExcludesStickyFromParkAndRestore() {
        // The WS-switch plan must omit sticky windows from both lists —
        // they stay on-screen, so parking/restoring them is wrong (and
        // would make the adapter's park/restore counts lie).
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])  // both home = WS1
        c.setSticky(wid(10))
        let plan = c.setActive(2)
        #expect(plan != nil)
        let parked = Set((plan?.toPark ?? []).map(\.id))
        #expect(!parked.contains(wid(10)),
                       "sticky window must not be in the park list")
        #expect(parked.contains(wid(20)),
                      "a normal window still parks on leave")
        // Returning to WS1 must not try to restore the sticky window.
        let back = c.setActive(1)
        let restored = Set((back?.toRestore ?? []).map(\.id))
        #expect(!restored.contains(wid(10)),
                       "sticky window must not be in the restore list")
        #expect(restored.contains(wid(20)),
                      "a normal window restores on return")
    }

    // MARK: - clearSticky

    @Test func clearStickyDropsStateAndUnfloats() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.setSticky(wid(10))
        c.clearSticky(wid(10))
        #expect(!c.isSticky(wid(10)))
        #expect(!c.isFloating(wid(10)),
                       "clearing sticky drops the forced float")
    }

    @Test func clearStickyLandsInActiveWorkspaceNotHome() {
        // Q4: clearing sticky re-homes the window to the WS the user is
        // looking at, not its original home — the window in front of
        // them must never vanish.
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        c.setSticky(wid(10))
        _ = c.setActive(3)                         // user is now on WS3
        c.clearSticky(wid(10))
        #expect(c.windowMap[wid(10)]?.workspace == 3,
                       "unstuck window lands in the active WS (Q4)")
    }

    @Test func clearStickyOnNonStickyIsNoOp() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.clearSticky(wid(10))                     // never was sticky
        #expect(!c.isSticky(wid(10)))
        #expect(c.windowMap[wid(10)]?.workspace == 1,
                       "a no-op clear must not move the window")
    }

    // MARK: - Float-exit = sticky-exit (Q13)

    @Test func toggleFloatOnStickyClearsStickyAndReHomes() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        c.setSticky(wid(10))
        _ = c.setActive(3)
        c.toggleFloat(wid(10))                     // float-exit = sticky-exit
        #expect(!c.isSticky(wid(10)),
                       "toggling float off a sticky window unsticks it")
        #expect(!c.isFloating(wid(10)),
                       "...and lands it as a tiled (non-floating) window")
        #expect(c.windowMap[wid(10)]?.workspace == 3,
                       "...in the active WS (same landing as Q4)")
    }

    // MARK: - Not movable to a single WS

    @Test func stickyWindowRejectsMoveToWorkspace() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])        // home = WS1
        c.setSticky(wid(10))
        let outcome = c.moveWindow(wid(10), to: 3)
        #expect(outcome == .rejected,
                       "a sticky window is in every WS — can't move to one")
        #expect(c.windowMap[wid(10)]?.workspace == 1,
                       "the rejected move must not relocate its home WS")
    }

    // MARK: - Prune on close

    @Test func stickyPrunedWhenWindowCloses() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.setSticky(wid(10))
        c.drop(wid(10))                            // forgetWindow
        #expect(!c.isSticky(wid(10)),
                       "closing the window must prune its sticky state")
    }

    // MARK: - Snapshot stamp

    @Test func snapshotStampsIsSticky() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        c.setSticky(wid(10))
        let wss = c.snapshot(live: [window(10), window(20)],
                             focused: nil,
                             activeRect: CGRect(x: 0, y: 0,
                                                width: 1440, height: 900))
        let ws1 = wss.first { $0.index == 0 }       // WS1 → 0-based
        let w10 = ws1?.windows.first { $0.id == wid(10) }
        let w20 = ws1?.windows.first { $0.id == wid(20) }
        #expect(w10?.isSticky == true)
        #expect(w20?.isSticky == false)
    }

    // MARK: - Orthogonal to marks

    @Test func stickyAndMarkCoexist() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10)])
        c.setSticky(wid(10))
        c.setMark("a", to: wid(10))
        #expect(c.isSticky(wid(10)))
        #expect(c.mark(forWindow: wid(10)) == "a",
                       "a window can be both sticky and marked")
    }
}
