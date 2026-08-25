// RailViewModel contract tests — the logic layer behind the SwiftUI rail:
// snapshot → cells derivation (degrade + section paths), the carousel
// browse cursor (seed / wrap / re-centre), the host-driven keyboard model
// (Tab slots / lifts / aim / commit), the three drag kinds with their
// landing gates + refresh suppression, scroll accumulation, the commit
// zoom funnel, and the `[border]` config mapping. Render behaviour is
// VM territory; everything here is deterministic state.

import Testing
import AppKit
import CoreGraphics
import Foundation
import FacetCore
import PaletteKit
import Palette
@testable import FacetViewRail

@MainActor
struct RailViewModelTests {

    // MARK: - Fixtures

    private func win(_ n: Int, focused: Bool = false,
                     frame: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 600),
                     mark: String? = nil) -> Window {
        Window(id: WindowID(serverID: n), pid: 100 + n, appName: "app\(n)",
               title: "w\(n)", isFocused: focused, isFloating: false,
               frame: frame, mark: mark)
    }

    private func ws(_ i: Int, name: String = "", active: Bool = false,
                    mode: String = "bsp", windows: [Window] = []) -> Workspace {
        Workspace(index: i, name: name.isEmpty ? "ws\(i)" : name,
                  isActive: active, layoutMode: mode, windows: windows)
    }

    private func makeVM(workspaces: [Workspace],
                        sections: [ProjectedSection] = []) -> RailViewModel {
        let vm = RailViewModel(palette: resolve(Theme.terminal.spec))
        vm.screenFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        vm.viewSize = CGSize(width: 1600, height: 1000)
        vm.reduceMotionCheck = { true }   // deterministic: no slide timers
        vm.apply(workspaces: workspaces, sections: sections)
        return vm
    }

    // MARK: - Cells derivation

    @Test func degradePathMirrorsWorkspaces() {
        let vm = makeVM(workspaces: [
            ws(0, windows: [win(1), win(2)]),
            ws(1, active: true, mode: "stack"),
        ])
        #expect(vm.cells.map(\.id) == ["ws:0", "ws:1"])
        #expect(vm.cells[0].caption == "1 (ws0)")
        #expect(vm.cells[0].thumbs.count == 2)
        #expect(vm.cells[1].isActive)
        #expect(vm.cells[1].mode == "stack")
        #expect(vm.windowHomeWS[WindowID(serverID: 1)] == 0)
    }

    @Test func sectionPathTakesProjectionOrderAndLensFloor() {
        let wss = [ws(0, windows: [win(1)]), ws(1, active: true)]
        let secs = [
            ProjectedSection(id: "ws:1", label: "beta", windows: [],
                             sourceWorkspaceIndex: 1),
            ProjectedSection(id: "lens", label: "Web", windows: [win(1)],
                             sourceWorkspaceIndex: nil, sectionType: .matched),
            ProjectedSection(id: "ws:0", label: "alpha", windows: [win(1)],
                             sourceWorkspaceIndex: 0),
        ]
        let vm = makeVM(workspaces: wss, sections: secs)
        #expect(vm.cells.map(\.caption) == ["1 (beta)", "2 (Web)", "3 (alpha)"])
        // Lens floor: wsIndex −1, no layout engine, never the highlight.
        #expect(vm.cells[1].wsIndex == -1)
        #expect(vm.cells[1].mode == "")
        #expect(!vm.cells[1].isActive)
        // Home resolves through the UNFILTERED snapshot, not the lens cell.
        #expect(vm.windowHomeWS[WindowID(serverID: 1)] == 0)
    }

    // MARK: - Browse cursor (seed / wrap / re-centre)

    @Test func cursorSeedsToActiveCell() {
        let vm = makeVM(workspaces: [ws(0), ws(1, active: true), ws(2)])
        #expect(vm.selectedSectionID == "ws:1")
        #expect(vm.heroCell?.id == "ws:1")
    }

    @Test func arrowsWrapOverAllSectionsAndResetWindowCursor() {
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)]),
                                     ws(1), ws(2)])
        vm.kbCycleWindow(forward: true)
        #expect(vm.kbWindowIdx == 0)
        vm.kbMoveSelection(dx: -1)                // wrap backwards
        #expect(vm.selectedSectionID == "ws:2")
        #expect(vm.kbWindowIdx == -1)             // reset on rotate
        vm.kbMoveSelection(dx: 1)
        vm.kbMoveSelection(dx: 1)
        #expect(vm.selectedSectionID == "ws:1")
    }

    @Test func externalActivateRecentresOnlyWhenCursorOnActive() {
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1), ws(2)])
        // Cursor at rest on the active section → a CLI switch re-centres.
        vm.apply(workspaces: [ws(0), ws(1), ws(2, active: true)], sections: [])
        #expect(vm.selectedSectionID == "ws:2")
        // Mid-browse (cursor parked elsewhere) → never yanked.
        vm.kbMoveSelection(dx: -1)
        #expect(vm.selectedSectionID == "ws:1")
        vm.apply(workspaces: [ws(0, active: true), ws(1), ws(2)], sections: [])
        #expect(vm.selectedSectionID == "ws:1")
    }

    @Test func strandedCursorSnapsToActive() {
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1)])
        vm.kbMoveSelection(dx: 1)
        #expect(vm.selectedSectionID == "ws:1")
        vm.apply(workspaces: [ws(0, active: true)], sections: [])   // ws:1 vanished
        #expect(vm.selectedSectionID == "ws:0")
    }

    // MARK: - Keyboard window slots + lifts

    @Test func tabCyclesReadingOrderSlots() {
        let vm = makeVM(workspaces: [
            ws(0, active: true, windows: [
                win(1, frame: CGRect(x: 800, y: 0, width: 700, height: 500)),
                win(2, frame: CGRect(x: 0, y: 0, width: 700, height: 500)),
            ])])
        vm.kbCycleWindow(forward: true)
        // Reading order starts at the left window (win 2), despite z-order.
        #expect(vm.kbSelectedThumb?.thumb.id == WindowID(serverID: 2))
        vm.kbCycleWindow(forward: true)
        #expect(vm.kbSelectedThumb?.thumb.id == WindowID(serverID: 1))
        vm.kbCycleWindow(forward: true)
        #expect(vm.kbWindowIdx == -1)             // back to the whole-WS slot
    }

    @Test func spaceLiftsWorkspaceOnHeaderSlotAndWindowOnWindowSlot() {
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)]),
                                     ws(1)])
        vm.kbSpaceLift()                          // header slot → swap lift
        #expect(vm.workspaceGhost != nil)
        #expect(vm.windowGhost == nil)
        vm.kbEscape()                             // cancel
        #expect(vm.workspaceGhost == nil)
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()                          // window slot → move lift
        #expect(vm.windowGhost != nil)
        #expect(vm.hiddenThumbID == WindowID(serverID: 1))
    }

    @Test func lensCellRefusesLifts() {
        let secs = [
            ProjectedSection(id: "lens", label: "Web", windows: [win(1)],
                             sourceWorkspaceIndex: nil, sectionType: .matched),
            ProjectedSection(id: "ws:0", label: "alpha", windows: [],
                             sourceWorkspaceIndex: 0),
        ]
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)])],
                        sections: secs)
        // Park the cursor on the lens cell.
        while vm.selectedSectionID != "lens" { vm.kbMoveSelection(dx: 1) }
        vm.kbSpaceLift()                          // whole-WS swap → refused
        #expect(vm.workspaceGhost == nil)
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()                          // window lift → refused
        #expect(vm.windowGhost == nil)
    }

    @Test func liftedArrowsAimOnlyAtOtherWorkspaces() {
        let secs = [
            ProjectedSection(id: "ws:0", label: "a", windows: [],
                             sourceWorkspaceIndex: 0),
            ProjectedSection(id: "lens", label: "Web", windows: [],
                             sourceWorkspaceIndex: nil, sectionType: .matched),
            ProjectedSection(id: "ws:1", label: "b", windows: [],
                             sourceWorkspaceIndex: 1),
        ]
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1)], sections: secs)
        vm.kbSpaceLift()                          // lift ws:0's contents
        vm.kbMoveSelection(dx: 1)                 // aim at the lens
        #expect(vm.selectedSectionID == "lens")
        #expect(vm.dropHighlight(vm.cells[1]) == nil)   // lens: no valid drop
        vm.kbMoveSelection(dx: 1)                 // aim at ws:1
        #expect(vm.dropHighlight(vm.cells[2]) == .swap)
        vm.kbMoveSelection(dx: 1)                 // wrap home → own cell
        #expect(vm.selectedSectionID == "ws:0")
        #expect(vm.dropHighlight(vm.cells[0]) == nil)   // no self-drop
    }

    @Test func swapCommitSourcesLiveWorkspaceWindows() {
        // The frameless window has no thumb but MUST still swap.
        let frameless = win(9, frame: nil)
        var swapped: (src: Int, dst: Int, srcIDs: [WindowID], dstIDs: [WindowID])?
        let vm = makeVM(workspaces: [
            ws(0, active: true, windows: [win(1), frameless]),
            ws(1, windows: [win(2)]),
        ])
        vm.onSwap = { swapped = ($0, $1, $2, $3) }
        vm.kbSpaceLift()
        vm.kbMoveSelection(dx: 1)
        vm.kbCommit()
        #expect(swapped?.src == 0)
        #expect(swapped?.dst == 1)
        #expect(swapped?.srcIDs.contains(WindowID(serverID: 9)) == true)
        #expect(swapped?.dstIDs == [WindowID(serverID: 2)])
    }

    @Test func returnWithoutTargetCancelsLift() {
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)]),
                                     ws(1)])
        var swaps = 0
        vm.onSwap = { _, _, _, _ in swaps += 1 }
        vm.kbSpaceLift()
        vm.kbCommit()                             // aimed home → cancel
        #expect(swaps == 0)
        #expect(vm.workspaceGhost == nil)
    }

    @Test func commitPicksWindowAtItsHomeWorkspace() {
        var pick: RailPick?
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)]),
                                     ws(1)])
        vm.onPick = { pick = $0 }
        vm.kbCycleWindow(forward: true)
        vm.kbCommit()
        guard case .window(let home, let pid, let id)? = pick else {
            Issue.record("expected a window pick"); return
        }
        #expect(home == 0)
        #expect(pid == 101)
        #expect(id == WindowID(serverID: 1))
    }

    @Test func escapeLadder() {
        var dismissed = 0
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)])])
        vm.onDismiss = { dismissed += 1 }
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()
        vm.kbEscape()                             // 1: cancel the lift
        #expect(vm.windowGhost == nil)
        #expect(vm.kbWindowIdx == 0)
        vm.kbEscape()                             // 2: clear the Tab slot
        #expect(vm.kbWindowIdx == -1)
        #expect(dismissed == 0)
        vm.kbEscape()                             // 3: dismiss
        #expect(dismissed == 1)
    }

    @Test func tabReadingOrderIsRowMajorForStackedWindows() {
        // Two rows: top A(1) C(3), bottom B(2). The unit-normalized rects
        // collapsed `readingOrder`'s row band to the whole square (pure
        // x-sort: A, B, C) — the fix scales hits back to screen size.
        let vm = makeVM(workspaces: [
            ws(0, active: true, windows: [
                win(1, frame: CGRect(x: 0, y: 0, width: 700, height: 400)),
                win(2, frame: CGRect(x: 0, y: 500, width: 700, height: 400)),
                win(3, frame: CGRect(x: 800, y: 0, width: 700, height: 400)),
            ])])
        var order: [WindowID] = []
        for _ in 0..<3 {
            vm.kbCycleWindow(forward: true)
            if let s = vm.kbSelectedThumb { order.append(s.thumb.id) }
        }
        #expect(order == [WindowID(serverID: 1), WindowID(serverID: 3),
                          WindowID(serverID: 2)])
    }

    @Test func pointerTapInClippedMarginResolvesAsBackdrop() {
        // 10 sections, 7 visible: cells rotate past the viewport but stay
        // hit-testable in SwiftUI — the tap router must resolve a click on
        // a clipped-out cell as the backdrop it looks like (dismiss), and
        // one on a visible cell as its pick.
        var dismissed = 0
        var picked: RailPick?
        let vm = makeVM(workspaces: (0..<10).map { ws($0, active: $0 == 0) })
        vm.onDismiss = { dismissed += 1 }
        vm.onPick = { picked = $0 }
        let lay = vm.layout
        let off = lay.placements.first {
            !lay.stripRect.intersects($0.cellRect) && !$0.isWrapGhost
        }
        #expect(off != nil)
        if let off {
            vm.pointerTap(at: CGPoint(x: off.cellRect.midX, y: off.cellRect.midY))
        }
        #expect(dismissed == 1)
        #expect(picked == nil)
        vm.pointerTap(at: stripPoint(vm, cellID: "ws:1"))
        guard case .workspace(let w)? = picked else {
            Issue.record("expected a workspace pick"); return
        }
        #expect(w == 1)
        #expect(dismissed == 1)
    }

    @Test func pointerDragEndFallbackNeverDoubleCommits() {
        // The monitor's post-up fallback fires after the healthy onEnded —
        // with the landing gate armed it must stand down, not re-commit.
        var moves = 0
        let w = win(1)
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [w]),
                                     ws(1), ws(2)])
        vm.onMoveWindow = { _, _, _, _ in moves += 1 }
        let cell = vm.cells[0]
        let start = thumbPoint(vm, cellID: "ws:0", thumbIndex: 0)
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0, location: start,
                            startLocation: start)
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0,
                            location: stripPoint(vm, cellID: "ws:1"),
                            startLocation: start)
        vm.thumbDragEnded()
        #expect(moves == 1)
        vm.pointerDragEndFallback()               // the async monitor hop
        #expect(moves == 1)
    }

    // MARK: - Landing gates + suppression

    @Test func windowDropGatesUntilBackendAck() {
        var moved: (src: Int, dst: Int, id: WindowID)?
        let w = win(1)
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [w]), ws(1)])
        vm.onMoveWindow = { src, dst, _, id in moved = (src, dst, id) }
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()
        vm.kbMoveSelection(dx: 1)
        vm.kbCommit()
        #expect(moved?.dst == 1)
        // Gate armed: the ghost + hidden thumb persist, refreshes defer.
        #expect(vm.hiddenThumbID == w.id)
        vm.apply(workspaces: [ws(0, active: true, windows: [w]), ws(1)],
                 sections: [])                     // NOT landed yet
        #expect(vm.hiddenThumbID == w.id)
        // Backend ack (the window now lives in ws 1) → gate clears.
        vm.apply(workspaces: [ws(0, active: true), ws(1, windows: [w])],
                 sections: [])
        #expect(vm.hiddenThumbID == nil)
        #expect(vm.windowGhost == nil)
    }

    @Test func duplicateReturnIsSwallowedWhileGatePending() {
        var moves = 0
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)]),
                                     ws(1)])
        vm.onMoveWindow = { _, _, _, _ in moves += 1 }
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()
        vm.kbMoveSelection(dx: 1)
        vm.kbCommit()
        vm.kbCommit()                             // second Return: swallowed
        #expect(moves == 1)
    }

    @Test func landingGateRefusesANewDragTakeover() {
        // The measured t-88qt takeover: drag A ws0→ws1 commits and arms the
        // gate; a SECOND press (on B, aiming ws:2) inside the ack window used
        // to skip the arm block, steer the OLD drag and re-commit A into ws:2
        // — B never moves, A moves twice. The old RailView's `drag == nil` +
        // pendingDown gate made that press fully inert; the fence restores it.
        var moves: [WindowID] = []
        // Distinct frames — identical rects leave the model order vs the
        // strip layout order unspecified and `thumbAt`'s start-point guard
        // then refuses the very first arm.
        let vm = makeVM(workspaces: [
            ws(0, active: true, windows: [
                win(1, frame: CGRect(x: 0, y: 0, width: 700, height: 350)),
                win(2, frame: CGRect(x: 800, y: 0, width: 700, height: 350)),
            ]),
            ws(1), ws(2)])
        vm.onMoveWindow = { _, _, _, id in moves.append(id) }
        let cell = vm.cells[0]
        let dragged = cell.thumbs[0]
        let start = thumbPoint(vm, cellID: "ws:0", thumbIndex: 0)
        vm.thumbDragChanged(cellID: cell.id, thumb: dragged, thumbIndex: 0,
                            location: start, startLocation: start)
        vm.thumbDragChanged(cellID: cell.id, thumb: dragged, thumbIndex: 0,
                            location: stripPoint(vm, cellID: "ws:1"),
                            startLocation: start)
        vm.thumbDragEnded()                       // → ws:1, gate arms
        #expect(moves == [dragged.id])
        let start2 = thumbPoint(vm, cellID: "ws:0", thumbIndex: 1)
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[1],
                            thumbIndex: 1, location: start2,
                            startLocation: start2)
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[1],
                            thumbIndex: 1,
                            location: stripPoint(vm, cellID: "ws:2"),
                            startLocation: start2)
        #expect(vm.drag?.targetCellID == "ws:1")  // old drag unsteered
        vm.thumbDragEnded()                       // second up: swallowed
        #expect(moves == [dragged.id])
        #expect(vm.hiddenThumbID == dragged.id)   // the ghost still stands in
    }

    @Test func pointerBusyDefersApplyUntilRelease() {
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1)])
        vm.pointerBusy = true
        vm.apply(workspaces: [ws(0, active: true)], sections: [])
        #expect(vm.cells.count == 2)              // frozen mid-press
        vm.pointerBusy = false
        #expect(vm.cells.count == 1)              // flushed on release
    }

    // MARK: - Pointer drags (window move + section reorder)

    private func stripPoint(_ vm: RailViewModel, cellID: String,
                            dx: CGFloat = 0) -> CGPoint {
        let pl = vm.placement(of: cellID)!
        return CGPoint(x: pl.cellRect.midX + dx, y: pl.cellRect.midY)
    }

    private func headerPoint(_ vm: RailViewModel, cellID: String) -> CGPoint {
        let pl = vm.placement(of: cellID)!
        return CGPoint(x: pl.headerRect.midX, y: pl.headerRect.midY)
    }

    private func thumbPoint(_ vm: RailViewModel, cellID: String,
                            thumbIndex: Int) -> CGPoint {
        let r = vm.stripThumbRect(cellID: cellID, thumbIndex: thumbIndex)!
        return CGPoint(x: r.midX, y: r.midY)
    }

    @Test func thumbDragTargetsOnlyOtherWorkspaceCellsInViewport() {
        // Odd count: all three cells sit fully inside the viewport (an even
        // full count half-clips both ends by design — the mirror peek).
        let w = win(1)
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [w]),
                                     ws(1), ws(2)])
        let cell = vm.cells[0]
        let start = thumbPoint(vm, cellID: "ws:0", thumbIndex: 0)
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0, location: start,
                            startLocation: start)
        #expect(vm.hiddenThumbID == w.id)
        // Over the source cell: no target.
        #expect(vm.drag?.targetCellID == nil)
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0,
                            location: stripPoint(vm, cellID: "ws:1"),
                            startLocation: start)
        #expect(vm.drag?.targetCellID == "ws:1")
        // Outside the strip viewport (the hero): no target.
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0,
                            location: CGPoint(x: vm.layout.heroRect.midX,
                                              y: vm.layout.heroRect.midY),
                            startLocation: start)
        #expect(vm.drag?.targetCellID == nil)
        var moved = false
        vm.onMoveWindow = { _, _, _, _ in moved = true }
        vm.thumbDragEnded()                       // no target → cancel
        #expect(!moved)
        #expect(vm.hiddenThumbID == nil)
    }

    @Test func headerDragReordersAtBoundary() {
        var reorder: (id: String, boundary: Int)?
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1), ws(2)])
        vm.onReorder = { reorder = ($0, $1) }
        // Drag ws:0's header over ws:2's far half → boundary 3.
        let start = headerPoint(vm, cellID: "ws:0")
        vm.headerDragChanged(cellID: "ws:0", location: start,
                             startLocation: start)
        #expect(vm.workspaceGhost?.cell.id == "ws:0")
        vm.headerDragChanged(cellID: "ws:0",
                             location: stripPoint(vm, cellID: "ws:2", dx: 10),
                             startLocation: start)
        #expect(vm.drag?.reorderBoundary == 3)
        #expect(vm.drag?.reorderLine != nil)
        vm.headerDragEnded()
        #expect(reorder?.id == "ws:0")
        #expect(reorder?.boundary == 3)
        #expect(vm.workspaceGhost == nil)
    }

    @Test func headerDragOwnSlotIsNoOp() {
        var reorders = 0
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1)])
        vm.onReorder = { _, _ in reorders += 1 }
        let start = headerPoint(vm, cellID: "ws:0")
        vm.headerDragChanged(cellID: "ws:0",
                             location: stripPoint(vm, cellID: "ws:0", dx: 10),
                             startLocation: start)
        #expect(vm.drag?.reorderBoundary == nil)  // own slot / own boundary
        vm.headerDragEnded()
        #expect(reorders == 0)
    }

    @Test func lensHeaderArmsReorderToo() {
        // Odd section count — an even full count half-clips both viewport
        // ends by design, putting the end cells' centres on the gate edge.
        let secs = [
            ProjectedSection(id: "ws:0", label: "a", windows: [],
                             sourceWorkspaceIndex: 0),
            ProjectedSection(id: "lens", label: "Web", windows: [],
                             sourceWorkspaceIndex: nil, sectionType: .matched),
            ProjectedSection(id: "ws:1", label: "b", windows: [],
                             sourceWorkspaceIndex: 1),
        ]
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1)], sections: secs)
        let start = headerPoint(vm, cellID: "lens")
        vm.headerDragChanged(cellID: "lens", location: start,
                             startLocation: start)
        #expect(vm.workspaceGhost?.cell.id == "lens")
        vm.headerDragEnded()
    }

    // MARK: - Scroll browse

    @Test func preciseScrollAccumulatesToSteps() {
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1), ws(2)])
        // 20 pt: below the 30 pt threshold — no rotation yet.
        vm.scrollRotate(deltaY: -20, precise: true,
                        gestureBegan: true, isMomentum: false)
        #expect(vm.selectedSectionID == "ws:0")
        // +15 pt more crosses it: down → next.
        vm.scrollRotate(deltaY: -15, precise: true,
                        gestureBegan: false, isMomentum: false)
        #expect(vm.selectedSectionID == "ws:1")
        // Momentum is ignored.
        vm.scrollRotate(deltaY: -90, precise: true,
                        gestureBegan: false, isMomentum: true)
        #expect(vm.selectedSectionID == "ws:1")
        // A notched wheel: one detent = one step, up → previous.
        vm.scrollRotate(deltaY: 1, precise: false,
                        gestureBegan: false, isMomentum: false)
        #expect(vm.selectedSectionID == "ws:0")
    }

    // MARK: - Commit zoom

    @Test func zoomPlaysOnlyForTheCentredHero() {
        let vm = makeVM(workspaces: [ws(0, active: true), ws(1)])
        vm.reduceMotionCheck = { false }
        vm.snapshotProvider = { _ in NSImage(size: CGSize(width: 4, height: 3)) }
        var performed = 0
        vm.commitSwitch(targetSectionID: "ws:1") { performed += 1 }
        #expect(performed == 1)                   // off-centre: immediate
        #expect(vm.zoom == nil)
        vm.commitSwitch(targetSectionID: "ws:0") { performed += 1 }
        #expect(performed == 1)                   // centred: zoom pending
        #expect(vm.zoom != nil)
        vm.finishZoom()
        #expect(performed == 2)                   // fires exactly once
        vm.finishZoom()
        #expect(performed == 2)
    }

    @Test func reduceMotionSkipsTheZoom() {
        let vm = makeVM(workspaces: [ws(0, active: true)])
        vm.snapshotProvider = { _ in NSImage(size: CGSize(width: 4, height: 3)) }
        var performed = 0
        vm.commitSwitch(targetSectionID: "ws:0") { performed += 1 }
        #expect(performed == 1)
        #expect(vm.zoom == nil)
    }

    @Test func teardownFiresAPendingZoomSwitch() {
        let vm = makeVM(workspaces: [ws(0, active: true)])
        vm.reduceMotionCheck = { false }
        vm.snapshotProvider = { _ in NSImage(size: CGSize(width: 4, height: 3)) }
        var performed = 0
        vm.commitSwitch(targetSectionID: "ws:0") { performed += 1 }
        vm.teardown()                             // closed mid-zoom
        #expect(performed == 1)
    }

    // MARK: - Hit tests (menus)

    @Test func hitTestsResolveHeroAndStripThumbs() {
        let w = win(1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [w]),
                                     ws(1), ws(2)])
        let hero = vm.layout.heroRect
        let hit = vm.thumbAt(CGPoint(x: hero.midX, y: hero.midY))
        #expect(hit?.thumb.id == w.id)
        let sp = stripPoint(vm, cellID: "ws:0")
        #expect(vm.thumbAt(sp)?.thumb.id == w.id)
        #expect(vm.stripCellAt(sp)?.id == "ws:0")
        let hp = vm.placement(of: "ws:1")!.headerRect
        #expect(vm.headerCellAt(CGPoint(x: hp.midX, y: hp.midY))?.id == "ws:1")
        // Outside the viewport nothing hits.
        #expect(vm.stripCellAt(CGPoint(x: 1, y: 1)) == nil)
    }

    // MARK: - Border mapping

    @Test func borderConfigMapsToEffectAndBreathing() {
        let vm = makeVM(workspaces: [ws(0, active: true)])
        vm.applyBorder(effectName: "off", glow: true, width: 2,
                       cycleSeconds: 6, cycleColors: false,
                       minWidth: nil, maxWidth: nil)
        #expect(vm.borderEffect == nil)
        #expect(!vm.borderGlow)
        vm.flashBorder()
        #expect(vm.borderFlashToken == 0)         // no-op when off
        vm.applyBorder(effectName: "neon", glow: true, width: 2,
                       cycleSeconds: 6, cycleColors: true,
                       minWidth: 1, maxWidth: 4)
        #expect(vm.borderEffect != nil)
        #expect(vm.borderGlow)
        #expect(vm.borderLineWidth == 1)
        #expect(vm.borderBreathTo == 4)
        #expect(vm.borderCyclesColors)
        vm.flashBorder()
        #expect(vm.borderFlashToken == 1)
    }
}
