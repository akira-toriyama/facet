import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure state-machine tests for the hide-reclaim pass
/// (`WorkspaceCatalog.reconcileHidden`): a window the user Cmd+H'd /
/// minimized (`isOnscreen=false`) gives up its tile slot but keeps its
/// `windowMap` assignment, and re-attaches at the tail when it returns
/// on-screen. No AX / AppKit / OS interaction — the point of having
/// `WorkspaceCatalog` extracted. Memory: `facet-hide-reclaim-decisions`.
final class HideReclaimTests: XCTestCase {

    // MARK: - Helpers

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }

    private func window(_ n: Int, pid: Int = 1000,
                        onscreen: Bool = true) -> Window {
        Window(id: wid(n), pid: pid, appName: "A",
               title: "w\(n)", isFocused: false,
               isFloating: false, frame: nil, isOnscreen: onscreen)
    }

    private var rect: CGRect { CGRect(x: 0, y: 0, width: 1000, height: 800) }

    private func seededCatalog(_ n: Int = 5) -> WorkspaceCatalog {
        var c = WorkspaceCatalog.init()
        c.seed(configs: (1...n).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        return c
    }

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

    func testFirstOffscreenTickOnlyArmsCandidate() {
        var c = twoWindowCatalog(mode: "tall")
        let r = c.reconcileHidden(liveByID: live(twenty: false),
                                  focused: nil, activeRect: rect)
        XCTAssertEqual(r.hidden, [])
        XCTAssertEqual(r.revealed, [])
        XCTAssertTrue(c.pendingHideCandidates.contains(wid(20)))
        XCTAssertFalse(c.hiddenMembers.contains(wid(20)))
        // Still tiled — slot not yet reclaimed.
        XCTAssertEqual(Set(c.orderedMembers(of: 1)), [wid(10), wid(20)])
    }

    func testBackOnscreenBeforeConfirmCancelsHide() {
        var c = twoWindowCatalog(mode: "tall")
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)   // arm
        let r = c.reconcileHidden(liveByID: live(twenty: true),
                                  focused: nil, activeRect: rect)  // recovered
        XCTAssertEqual(r.hidden, [])
        XCTAssertFalse(c.pendingHideCandidates.contains(wid(20)))
        XCTAssertFalse(c.hiddenMembers.contains(wid(20)))
        XCTAssertEqual(Set(c.orderedMembers(of: 1)), [wid(10), wid(20)])
    }

    // MARK: - Reclaim (stateless engine)

    func testSecondOffscreenTickReclaimsSlot() {
        var c = twoWindowCatalog(mode: "tall")
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)   // arm
        let r = c.reconcileHidden(liveByID: live(twenty: false),
                                  focused: nil, activeRect: rect)  // confirm
        XCTAssertEqual(r.hidden, [wid(20)])
        XCTAssertTrue(c.hiddenMembers.contains(wid(20)))
        // Detached from the layout order…
        XCTAssertEqual(c.orderedMembers(of: 1), [wid(10)])
        // …but still managed (WS assignment preserved for the return).
        XCTAssertEqual(c.windowMap[wid(20)]?.workspace, 1)
    }

    func testReclaimedSlotIsFilledByRemainingWindow() {
        var c = twoWindowCatalog(mode: "tall")
        // Before: tall 1-master / 1-stack → master gets left half.
        let before = c.engineFrames(for: 1, in: rect)
        XCTAssertEqual(before[wid(10)]?.width ?? 0, 500, accuracy: 0.5)
        // Hide 20 (two ticks).
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        let after = c.engineFrames(for: 1, in: rect)
        XCTAssertNil(after[wid(20)])                       // no slot
        XCTAssertEqual(after[wid(10)]?.width ?? 0, 1000, accuracy: 0.5)
    }

    // MARK: - Reveal

    func testRevealReattachesAtTail() {
        var c = twoWindowCatalog(mode: "tall")
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        XCTAssertEqual(c.orderedMembers(of: 1), [wid(10)])   // hidden
        let r = c.reconcileHidden(liveByID: live(twenty: true),
                                  focused: nil, activeRect: rect)
        XCTAssertEqual(r.revealed, [wid(20)])
        XCTAssertFalse(c.hiddenMembers.contains(wid(20)))
        // Back in the layout, appended at the tail (10 keeps master).
        XCTAssertEqual(c.orderedMembers(of: 1), [wid(10), wid(20)])
    }

    // MARK: - Reclaim (bsp tree)

    func testBspReclaimRemovesAndReinsertsTreeNode() {
        var c = twoWindowCatalog(mode: "bsp")
        XCTAssertNotNil(c.tiledFrames(for: 1, in: rect)[wid(20)])
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        let hidden = c.tiledFrames(for: 1, in: rect)
        XCTAssertNil(hidden[wid(20)])                       // node removed
        XCTAssertNotNil(hidden[wid(10)])
        XCTAssertEqual(hidden[wid(10)]?.width ?? 0, 1000, accuracy: 0.5)
        // Reveal re-inserts into the tree.
        _ = c.reconcileHidden(liveByID: live(twenty: true),
                              focused: nil, activeRect: rect)
        XCTAssertNotNil(c.tiledFrames(for: 1, in: rect)[wid(20)])
    }

    // MARK: - Exclusions (facet's own park / floating)

    func testAnchorParkedWindowIsNotTreatedAsHidden() {
        var c = twoWindowCatalog(mode: "tall")
        // facet parks at the on-screen sliver; defend even if its
        // isOnscreen read ever drops to false.
        c.markAnchorParked(wid(20), originalPosition: .zero)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        XCTAssertFalse(c.hiddenMembers.contains(wid(20)))
        XCTAssertFalse(c.pendingHideCandidates.contains(wid(20)))
    }

    func testFloatingWindowIsNotReclaimed() {
        var c = seededCatalog()
        _ = c.reconcile(live: [window(10), window(20)],
                        autoFloat: [wid(20)])
        _ = c.setMode(workspace: 1, to: "tall", in: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        XCTAssertFalse(c.hiddenMembers.contains(wid(20)))
    }

    // MARK: - Cleanup

    func testForgettingHiddenWindowClearsState() {
        var c = twoWindowCatalog(mode: "tall")
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        _ = c.reconcileHidden(liveByID: live(twenty: false),
                              focused: nil, activeRect: rect)
        XCTAssertTrue(c.hiddenMembers.contains(wid(20)))
        c.drop(wid(20))
        XCTAssertFalse(c.hiddenMembers.contains(wid(20)))
        XCTAssertFalse(c.pendingHideCandidates.contains(wid(20)))
        XCTAssertNil(c.windowMap[wid(20)])
    }
}
