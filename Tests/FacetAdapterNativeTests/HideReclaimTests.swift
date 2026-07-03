import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure state-machine tests for the hide-reclaim pass
/// (`WorkspaceCatalog.reconcileHidden`): a window the user Cmd+H'd /
/// minimized (`isOnscreen=false`) gives up its tile slot but keeps its
/// `windowMap` assignment, and re-attaches at the tail when it returns
/// on-screen. No AX / AppKit / OS interaction — the point of having
/// `WorkspaceCatalog` extracted. Memory: `facet-hide-reclaim-decisions`.
struct HideReclaimTests {

    // MARK: - Helpers

    private var rect: CGRect { CGRect(x: 0, y: 0, width: 1000, height: 800) }

    /// Catalog with windows 10 + 20 adopted into WS1 in `mode`.
    private func twoWindowCatalog(mode: String) -> WorkspaceCatalog {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)])
        _ = c.setMode(workspace: 1, to: mode, in: rect)
        return c
    }

    /// liveByID for windows 10 + 20 with 20 optionally off-screen.
    private func live(twenty onscreen: Bool) -> [WindowID: Window] {
        [wid(10): window(10), wid(20): window(20, onscreen: onscreen)]
    }

    // MARK: - Two-tick gate

    @Test func firstOffscreenTickOnlyArmsCandidate() {
        var c = twoWindowCatalog(mode: "master-left")
        let r = c.reconcileHidden(liveByID: live(twenty: false),
                                  focused: nil, activeRect: rect)
        #expect(r.hidden == [])
        #expect(r.revealed == [])
        #expect(c.pendingHideCandidates.contains(wid(20)))
        #expect(!c.hiddenMembers.contains(wid(20)))
        // Still tiled — slot not yet reclaimed.
        #expect(Set(c.orderedMembers(of: 1)) == [wid(10), wid(20)])
    }

    @Test func backOnscreenBeforeConfirmCancelsHide() {
        var c = twoWindowCatalog(mode: "master-left")
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)   // arm
        let r = c.reconcileHidden(liveByID: live(twenty: true),
                                  focused: nil, activeRect: rect)  // recovered
        #expect(r.hidden == [])
        #expect(!c.pendingHideCandidates.contains(wid(20)))
        #expect(!c.hiddenMembers.contains(wid(20)))
        #expect(Set(c.orderedMembers(of: 1)) == [wid(10), wid(20)])
    }

    // MARK: - Reclaim (stateless engine)

    @Test func secondOffscreenTickReclaimsSlot() {
        var c = twoWindowCatalog(mode: "master-left")
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)   // arm
        let r = c.reconcileHidden(liveByID: live(twenty: false),
                                  focused: nil, activeRect: rect)  // confirm
        #expect(r.hidden == [wid(20)])
        #expect(c.hiddenMembers.contains(wid(20)))
        // Detached from the layout order…
        #expect(c.orderedMembers(of: 1) == [wid(10)])
        // …but still managed (WS assignment preserved for the return).
        #expect(c.windowMap[wid(20)]?.workspace == 1)
    }

    @Test func reclaimedSlotIsFilledByRemainingWindow() {
        var c = twoWindowCatalog(mode: "master-left")
        // Before: tall 1-master / 1-stack → master gets left half.
        let before = c.engineFrames(for: 1, in: rect)
        #expect(abs((before[wid(10)]?.width ?? 0) - 500) < 0.5)
        // Hide 20 (two ticks).
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        let after = c.engineFrames(for: 1, in: rect)
        #expect(after[wid(20)] == nil)                       // no slot
        #expect(abs((after[wid(10)]?.width ?? 0) - 1000) < 0.5)
    }

    // MARK: - Reveal

    @Test func revealReattachesAtTail() {
        var c = twoWindowCatalog(mode: "master-left")
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        #expect(c.orderedMembers(of: 1) == [wid(10)])   // hidden
        let r = c.reconcileHidden(liveByID: live(twenty: true),
                                  focused: nil, activeRect: rect)
        #expect(r.revealed == [wid(20)])
        #expect(!c.hiddenMembers.contains(wid(20)))
        // Back in the layout, appended at the tail (10 keeps master).
        #expect(c.orderedMembers(of: 1) == [wid(10), wid(20)])
    }

    // MARK: - Reclaim (bsp tree)

    @Test func bspReclaimRemovesAndReinsertsTreeNode() {
        var c = twoWindowCatalog(mode: "bsp")
        #expect(c.tiledFrames(for: 1, in: rect)[wid(20)] != nil)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        let hidden = c.tiledFrames(for: 1, in: rect)
        #expect(hidden[wid(20)] == nil)                       // node removed
        #expect(hidden[wid(10)] != nil)
        #expect(abs((hidden[wid(10)]?.width ?? 0) - 1000) < 0.5)
        // Reveal re-inserts into the tree.
        _ = c.reconcileHidden(liveByID: live(twenty: true),
                              focused: nil, activeRect: rect)
        #expect(c.tiledFrames(for: 1, in: rect)[wid(20)] != nil)
    }

    // MARK: - Exclusions (facet's own park / floating)

    @Test func anchorParkedWindowIsNotTreatedAsHidden() {
        var c = twoWindowCatalog(mode: "master-left")
        // facet parks at the on-screen sliver; defend even if its
        // isOnscreen read ever drops to false.
        c.markAnchorParked(wid(20), originalPosition: .zero)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        #expect(!c.hiddenMembers.contains(wid(20)))
        #expect(!c.pendingHideCandidates.contains(wid(20)))
    }

    @Test func floatingWindowIsNotReclaimed() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)],
                        autoFloat: [wid(20)])
        _ = c.setMode(workspace: 1, to: "master-left", in: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        #expect(!c.hiddenMembers.contains(wid(20)))
    }

    // MARK: - Cleanup

    @Test func forgettingHiddenWindowClearsState() {
        var c = twoWindowCatalog(mode: "master-left")
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        #expect(c.hiddenMembers.contains(wid(20)))
        c.drop(wid(20))
        #expect(!c.hiddenMembers.contains(wid(20)))
        #expect(!c.pendingHideCandidates.contains(wid(20)))
        #expect(c.windowMap[wid(20)] == nil)
    }
}
