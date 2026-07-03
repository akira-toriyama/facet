import Testing
import Foundation
@testable import FacetCore

/// `OverviewPendingDrop.landed` / `OverviewPendingSwap.landed` — the shared
/// grid + rail landing gates (PR8 DnD). Both are pure membership predicates:
/// the optimistic overlay clears only once the backend snapshot REFLECTS the
/// move ("don't clear on mouseUp — clear when the backend confirms",
/// [[grid-drag-state-lifecycle]]). They never read `committedAt` (the time
/// cap lives in the caller), so these tests pin only the membership logic.
/// Pure; CI-only (CLT can't run `swift test`).
struct OverviewLandingGateTests {

    // MARK: - fixtures

    private let t0 = Date(timeIntervalSince1970: 0)

    private func win(_ id: Int) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: "App", title: "",
               isFocused: false, isFloating: false, frame: nil)
    }

    private func ws(_ index: Int, _ ids: [Int]) -> Workspace {
        Workspace(index: index, name: "WS\(index)", isActive: false,
                  layoutMode: "bsp", windows: ids.map(win))
    }

    // MARK: - OverviewPendingDrop.landed

    @Test func dropNotLandedWhileStillInSource() {
        // Window 1 dropped onto WS 2 but the backend still shows it in WS 1.
        let drop = OverviewPendingDrop(id: WindowID(serverID: 1), dstWS: 2,
                                       committedAt: t0)
        let wss = [ws(1, [1]), ws(2, [])]
        #expect(!(drop.landed(in: wss)))
    }

    @Test func dropLandedWhenInDestination() {
        let drop = OverviewPendingDrop(id: WindowID(serverID: 1), dstWS: 2,
                                       committedAt: t0)
        let wss = [ws(1, []), ws(2, [1])]
        #expect(drop.landed(in: wss))
    }

    @Test func dropIgnoresPresenceInWrongWorkspace() {
        // The id reappears in WS 3 (not the destination) — NOT landed: the
        // gate matches the id *in `dstWS`*, not anywhere on the desktop.
        let drop = OverviewPendingDrop(id: WindowID(serverID: 1), dstWS: 2,
                                       committedAt: t0)
        let wss = [ws(1, []), ws(2, []), ws(3, [1])]
        #expect(!(drop.landed(in: wss)))
    }

    @Test func dropDestinationMissingIsNotLanded() {
        // No workspace carries index == dstWS → contains short-circuits false.
        let drop = OverviewPendingDrop(id: WindowID(serverID: 1), dstWS: 9,
                                       committedAt: t0)
        #expect(!(drop.landed(in: [ws(1, [1])])))
        #expect(!(drop.landed(in: [])))
    }

    // MARK: - OverviewPendingSwap.landed

    /// srcIDs=[1] should end in dstWS=2, dstIDs=[2] should end in srcWS=1.
    private func swap12() -> OverviewPendingSwap {
        OverviewPendingSwap(srcWS: 1, dstWS: 2, srcIDs: [WindowID(serverID: 1)],
                            dstIDs: [WindowID(serverID: 2)], committedAt: t0)
    }

    @Test func swapNotLandedBeforeBackendMoves() {
        // Both windows still sit in their original workspaces.
        let wss = [ws(1, [1]), ws(2, [2])]
        #expect(!(swap12().landed(in: wss)))
    }

    @Test func swapNotLandedWhenOnlyOneHalfMoved() {
        // src half landed (1 → WS 2) but dst half hasn't (2 not yet in WS 1).
        let half = [ws(1, []), ws(2, [1, 2])]
        #expect(!(swap12().landed(in: half)))
    }

    @Test func swapLandedWhenBothHalvesReflected() {
        let done = [ws(1, [2]), ws(2, [1])]
        #expect(swap12().landed(in: done))
    }

    @Test func swapMissingEitherWorkspaceIsNotLanded() {
        // The guard returns false if srcWS or dstWS is absent.
        #expect(!(swap12().landed(in: [ws(2, [1])])))      // no WS 1
        #expect(!(swap12().landed(in: [ws(1, [2])])))      // no WS 2
        #expect(!(swap12().landed(in: [])))
    }

    @Test func swapWithEmptyIDsLandsVacuously() {
        // `allSatisfy` on an empty list is true, so a no-id swap "lands" the
        // instant both workspaces resolve — an intentional edge of the gate.
        let empty = OverviewPendingSwap(srcWS: 1, dstWS: 2, srcIDs: [],
                                        dstIDs: [], committedAt: t0)
        #expect(empty.landed(in: [ws(1, []), ws(2, [])]))
        #expect(!(empty.landed(in: [ws(1, [])])))          // WS 2 missing
    }

    @Test func swapAllOfMultipleSourceIDsMustLand() {
        let multi = OverviewPendingSwap(
            srcWS: 1, dstWS: 2,
            srcIDs: [WindowID(serverID: 1), WindowID(serverID: 3)],
            dstIDs: [], committedAt: t0)
        // Only one of the two src ids reached WS 2 → not landed.
        #expect(!(multi.landed(in: [ws(1, [3]), ws(2, [1])])))
        // Both reached WS 2 → landed.
        #expect(multi.landed(in: [ws(1, []), ws(2, [1, 3])]))
    }
}
