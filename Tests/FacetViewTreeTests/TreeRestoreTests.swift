// The 2026-08-16 restore bundle (t-fp94 rule: a migration never sheds a
// feature) — the degrade header SWAP (old mode-3), the holding-row lift veto
// (t-63h2 / t-jzbf), the M12 cursor re-anchor, the remembered cursor
// (kbSel-after-act parity), the optimistic ACTIVE-workspace claim, and the
// emphasized / dimmed row mapping (ledger L4 / M10).

import XCTest
import FacetCore
import FacetView
import ListCore
import ThemeKitUI
@testable import FacetViewTree

@MainActor
final class TreeRestoreTests: XCTestCase {

    private func win(_ id: Int, _ app: String, _ title: String,
                     focused: Bool = false, onscreen: Bool = true) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: focused, isFloating: false, frame: nil,
               isOnscreen: onscreen)
    }
    private func sec(_ id: String, _ label: String, _ type: ProjectedSectionType,
                     _ wins: [Window], src: Int?) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: wins,
                         sourceWorkspaceIndex: src, sectionType: type)
    }
    private func vm(_ sections: [ProjectedSection], active: Int? = nil,
                    sectionMode: Bool = true,
                    isolateDesktop: Bool = false) -> TreeViewModel {
        let m = TreeViewModel(palette: resolve(.terminal))
        m.apply(sections: sections, activeWorkspaceIndex: active,
                sectionMode: sectionMode, isolateDesktop: isolateDesktop)
        return m
    }

    /// ws0: [w1, w2] · ws1: [] (empty) · ws2: [w3]
    private var ladder: [ProjectedSection] {
        [sec("ws:0", "1", .workspace, [win(1, "Safari", "GitHub"),
                                       win(2, "Terminal", "zsh")], src: 0),
         sec("ws:1", "2", .workspace, [], src: 1),
         sec("ws:2", "3", .workspace, [win(3, "Mail", "Inbox")], src: 2)]
    }

    private func ctx(_ source: TreeItemID) -> ListCore.DragContext<TreeItemID> {
        ListCore.DragContext(sourceID: source, memberIDs: [source])
    }
    private func onto(_ id: TreeItemID) -> ListCore.DropTarget<TreeItemID> {
        ListCore.DropTarget(placement: .onto(id: id))
    }

    // MARK: - resolveTreeDrop: the degrade workspace swap (old mode-3)

    func testDegradeHeaderOntoAnotherSectionResolvesToASwap() {
        let secs = ladder
        // Onto the other section's HEADER, one of its ROWS, or the gap
        // inside it — the whole band is that workspace (wsBands parity).
        XCTAssertEqual(resolveTreeDrop(ctx(.header("ws:0")), onto(.header("ws:2")),
                                       sections: secs, sectionMode: false,
                                       isolateDesktop: false),
                       .swap(from: 0, to: 2))
        XCTAssertEqual(resolveTreeDrop(ctx(.header("ws:0")),
                                       onto(.window(group: 2, WindowID(serverID: 3))),
                                       sections: secs, sectionMode: false,
                                       isolateDesktop: false),
                       .swap(from: 0, to: 2))
        let gapInside = ListCore.DropTarget<TreeItemID>(
            placement: .between(beforeID: .window(group: 2, WindowID(serverID: 3))))
        XCTAssertEqual(resolveTreeDrop(ctx(.header("ws:0")), gapInside,
                                       sections: secs, sectionMode: false,
                                       isolateDesktop: false),
                       .swap(from: 0, to: 2))
    }

    func testDegradeHeaderOntoItsOwnSectionIsRefused() {
        XCTAssertNil(resolveTreeDrop(ctx(.header("ws:0")),
                                     onto(.window(group: 0, WindowID(serverID: 1))),
                                     sections: ladder, sectionMode: false,
                                     isolateDesktop: false))
    }

    func testSectionModeHeaderOntoIsStillARefusedPlacement() {
        // Section mode reorders (between only) — the swap gesture stays
        // by-workspace-only, exactly like the AppKit tree.
        XCTAssertNil(resolveTreeDrop(ctx(.header("ws:0")), onto(.header("ws:2")),
                                     sections: ladder, sectionMode: true,
                                     isolateDesktop: false))
    }

    // MARK: - TreeViewModel: degrade header lift walks the swap ladder

    func testDegradeHeaderLiftAimsThePerWorkspaceLadder() {
        let m = vm(ladder, sectionMode: false)
        m.parkCursor(on: .header("ws:0"))
        m.liftCursor()
        XCTAssertTrue(m.isKbDragging, "a degrade header lifts (for the swap)")
        guard let (c, seeded) = m.commitDrag() else { return XCTFail("no commit") }
        XCTAssertEqual(c.memberIDs, [.header("ws:0")], "the header lifts ALONE")
        XCTAssertEqual(seeded.placement, .onto(id: .header("ws:0")),
                       "the aim seeds on the lifted section itself")
        m.parkCursor(on: .header("ws:0"))
        m.liftCursor()
        m.aimDrag(1)
        XCTAssertEqual(m.commitDrag()?.1.placement, .onto(id: .header("ws:1")),
                       "one ↓ steps one workspace")
    }

    // MARK: - holding rows: display-only (t-63h2 / t-jzbf)

    private var isolate: [ProjectedSection] {
        [sec("section:0:dev", "dev", .matched, [win(1, "Safari", "G")], src: nil),
         sec("holding:1", "held", .holding, [win(2, "Notes", "n")], src: nil)]
    }

    func testHoldingRowNeverLifts() {
        let m = vm(isolate, isolateDesktop: true)
        let holding = TreeItemID.window(group: 1, WindowID(serverID: 2))
        XCTAssertTrue(m.isHoldingRow(holding))
        XCTAssertFalse(m.isHoldingRow(.window(group: 0, WindowID(serverID: 1))))
        m.parkCursor(on: holding)
        m.liftCursor()
        XCTAssertFalse(m.isKbDragging, "a holding row is not a drag source")
    }

    // MARK: - dragChunkMembers (the pointer dragChunk seam)

    func testChunkRuleFollowsTheRenderMode() {
        let m = vm(ladder, sectionMode: true)
        XCTAssertEqual(m.dragChunkMembers(for: .header("ws:0")),
                       [.header("ws:0"),
                        .window(group: 0, WindowID(serverID: 1)),
                        .window(group: 0, WindowID(serverID: 2))],
                       "section mode: a header drags its whole section (reorder)")
        m.apply(sections: ladder, sectionMode: false)
        XCTAssertEqual(m.dragChunkMembers(for: .header("ws:0")), [],
                       "degrade: the header lifts alone (swap aims .onto)")
        XCTAssertEqual(m.dragChunkMembers(
                           for: .window(group: 0, WindowID(serverID: 1))), [],
                       "a window row always travels alone")
    }

    // MARK: - sectionMemberIDs (the dropBand membership)

    func testSectionMemberIDsCoverHeaderAndRows() {
        let m = vm(ladder)
        XCTAssertEqual(m.sectionMemberIDs(ordinal: 0),
                       [.header("ws:0"),
                        .window(group: 0, WindowID(serverID: 1)),
                        .window(group: 0, WindowID(serverID: 2))])
        XCTAssertEqual(m.sectionMemberIDs(ordinal: 1), [.header("ws:1")])
        XCTAssertEqual(m.sectionMemberIDs(ordinal: 9), [])
    }

    // MARK: - M12: the cursor re-anchors when its row vanishes

    func testCursorReanchorsAtTheVanishedRowsPosition() {
        let m = vm(ladder)
        let w1 = TreeItemID.window(group: 0, WindowID(serverID: 1))
        m.parkCursor(on: w1)                        // row index 1
        var gone = ladder
        gone[0] = sec("ws:0", "1", .workspace,
                      [win(2, "Terminal", "zsh")], src: 0)   // w1 closed
        m.apply(sections: gone)
        XCTAssertEqual(m.highlight, .window(group: 0, WindowID(serverID: 2)),
                       "the row that slid into the vanished slot takes the cursor")
    }

    func testCursorStillDropsWhenTheWholeTreeEmpties() {
        let m = vm(ladder)
        m.parkCursor(on: .header("ws:0"))
        m.apply(sections: [])
        XCTAssertNil(m.highlight)
    }

    // MARK: - remembered cursor (kbSel-after-act parity)

    func testRememberedCursorSeedsTheNextNavEntryOnce() {
        let m = vm(ladder)
        m.rememberCursor(.header("ws:1"))
        m.seedCursor()
        XCTAssertEqual(m.highlight, .header("ws:1"),
                       "nav re-entry resumes on the acted-on row")
        m.clearCursor()
        m.seedCursor()
        XCTAssertEqual(m.highlight, .header("ws:0"),
                       "the memory is consumed (and clearCursor wipes it)")
    }

    // MARK: - optimistic ACTIVE-workspace claim (empty-header click feedback)

    func testActiveClaimPaintsTheHeaderBeforeTheBackendLands() {
        let m = vm(ladder, active: 0)
        m.setOptimistic(nil, activeWorkspace: 1)    // empty ws — no row to fill
        let hdr = m.rows.first { $0.id == .header("ws:1") }
        XCTAssertEqual(hdr?.primary.hasSuffix("●"), true,
                       "the clicked workspace's header paints active NOW")
        XCTAssertEqual(hdr?.emphasized, true)
        XCTAssertEqual(m.rows.first { $0.id == .header("ws:0") }?.emphasized,
                       false, "the previous active header stands down")
        // A racing projection that still says ws0 arrives inside the hold —
        // the claim must win (the same race the row claim protects against).
        m.apply(sections: ladder, activeWorkspaceIndex: 0)
        XCTAssertEqual(m.rows.first { $0.id == .header("ws:1") }?.emphasized,
                       true, "the active claim beats the stale projection")
    }

    // MARK: - emphasized / dimmed mapping into sill items (L4 / M10)

    func testFocusedRowMapsToAnEmphasizedItem() {
        let focused = [sec("ws:0", "1", .workspace,
                           [win(1, "Safari", "G", focused: true),
                            win(2, "Terminal", "z")], src: 0)]
        let m = vm(focused, active: 0)
        let w1 = TreeItemID.window(group: 0, WindowID(serverID: 1))
        XCTAssertEqual(m.listItems.first { $0.id == w1 }?.isEmphasized, true,
                       "the focused window keeps its accent-semibold mark (L4)")
        XCTAssertEqual(m.listItems.first {
            $0.id == .window(group: 0, WindowID(serverID: 2))
        }?.isEmphasized, false)
        // The claim moves — the emphasis follows without a projection.
        let w2 = TreeItemID.window(group: 0, WindowID(serverID: 2))
        m.setOptimistic(w2)
        XCTAssertEqual(m.listItems.first { $0.id == w2 }?.isEmphasized, true)
        XCTAssertEqual(m.listItems.first { $0.id == w1 }?.isEmphasized, false)
    }

    func testHiddenWindowMapsToADimmedItem() {
        let m = vm([sec("ws:0", "1", .workspace,
                        [win(1, "Safari", "G", onscreen: false),
                         win(2, "Terminal", "z")], src: 0)])
        XCTAssertEqual(m.listItems.first {
            $0.id == .window(group: 0, WindowID(serverID: 1))
        }?.isDimmed, true, "hidden (Cmd+H'd) rows read faded — M10")
        XCTAssertEqual(m.listItems.first {
            $0.id == .window(group: 0, WindowID(serverID: 2))
        }?.isDimmed, false)
    }

    func testActiveHeaderMapsToAnEmphasizedItem() {
        let m = vm(ladder, active: 2)
        XCTAssertEqual(m.listItems.first { $0.id == .header("ws:2") }?.isEmphasized,
                       true, "the active workspace header is accent + semibold")
        XCTAssertEqual(m.listItems.first { $0.id == .header("ws:0") }?.isEmphasized,
                       false)
    }
}
