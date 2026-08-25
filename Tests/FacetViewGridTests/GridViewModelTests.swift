// GridViewModel contract tests — the pure/logic layer behind the SwiftUI
// grid: snapshot → cells derivation (degrade + section paths), the
// host-driven keyboard model (cursor / window slots / lifts), the landing
// gates + refresh suppression the old `layoutCells` kept, and the `[border]`
// config mapping. Render behaviour is prism/VM territory; everything here is
// deterministic state.

import Testing
import AppKit
import CoreGraphics
import Foundation
import FacetCore
import FacetView
import PaletteKit
import Palette
@testable import FacetViewGrid

@MainActor
struct GridViewModelTests {

    // MARK: - Fixtures

    private func win(_ n: Int, ws: Int = 0, focused: Bool = false,
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
                        sections: [ProjectedSection] = []) -> GridViewModel {
        let vm = GridViewModel(palette: resolve(Theme.terminal.spec))
        vm.screenFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        vm.apply(workspaces: workspaces, sections: sections)
        return vm
    }

    /// Give every cell a fake reported frame so hit tests / anchors work
    /// without a live layout pass (cells side by side, 100 pt wide).
    private func seedFrames(_ vm: GridViewModel) {
        for (i, cell) in vm.cells.enumerated() {
            let f = CGRect(x: CGFloat(i) * 110, y: 0, width: 100, height: 100)
            vm.cellFrames[cell.id] = f
            vm.miniFrames[cell.id] = f.insetBy(dx: 0, dy: 20)
            vm.headerFrames[cell.id] = CGRect(x: f.minX, y: 0, width: 100, height: 20)
        }
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

    @Test func sectionPathTakesProjectionOrderAndDisplayIndexCaptions() {
        let wss = [ws(0, windows: [win(1)]), ws(1, active: true)]
        let secs = [
            ProjectedSection(id: "ws:1", label: "beta", windows: [],
                             sourceWorkspaceIndex: 1),
            ProjectedSection(id: "ws:0", label: "alpha", windows: [win(1)],
                             sourceWorkspaceIndex: 0),
        ]
        let vm = makeVM(workspaces: wss, sections: secs)
        // §D: caption index = the section's DISPLAY position, not its WS index.
        #expect(vm.cells.map(\.caption) == ["1 (beta)", "2 (alpha)"])
        #expect(vm.cells[0].isActive)          // ws1 is active
        #expect(vm.cells[1].thumbs.count == 1)
    }

    @Test func windowsWithoutFramesAreCulled() {
        let vm = makeVM(workspaces: [ws(0, windows: [win(1, frame: nil), win(2)])])
        #expect(vm.cells[0].thumbs.count == 1)
    }

    @Test func structuralEpochBumpsOnlyOnScaffoldChange() {
        let vm = makeVM(workspaces: [ws(0), ws(1)])
        let e0 = vm.structuralEpoch
        // Same scaffold, new window content → NO bump (thumbs may FLIP).
        vm.apply(workspaces: [ws(0, windows: [win(1)]), ws(1)], sections: [])
        #expect(vm.structuralEpoch == e0)
        // A third workspace changes the scaffold → bump (thumbs snap).
        vm.apply(workspaces: [ws(0), ws(1), ws(2)], sections: [])
        #expect(vm.structuralEpoch > e0)
    }

    // MARK: - Keyboard cursor

    @Test func seedLandsOnActiveCellHeaderSlot() {
        let vm = makeVM(workspaces: [ws(0), ws(1, active: true), ws(2)])
        vm.kbSeedToActiveCell()
        #expect(vm.kbCursorID == "ws:1")
        #expect(vm.kbWindowIdx == -1)
    }

    @Test func arrowMovesWrapAndResetWindowSlot() {
        let vm = makeVM(workspaces: (0..<3).map { ws($0, windows: [win(10 + $0)]) })
        vm.config = GridConfig(cols: 3)
        vm.kbSeedToActiveCell()          // no active → first
        #expect(vm.kbCursorID == "ws:0")
        vm.kbCycleWindow(forward: true)
        #expect(vm.kbWindowIdx == 0)
        vm.kbMove(dx: -1, dy: 0)         // wraps to the row's last cell
        #expect(vm.kbCursorID == "ws:2")
        #expect(vm.kbWindowIdx == -1)    // arrow lands on the header slot
    }

    @Test func tabCyclesHeaderAndWindows() {
        let vm = makeVM(workspaces: [ws(0, windows: [win(1), win(2)])])
        vm.kbSeedToActiveCell()
        vm.kbCycleWindow(forward: true)
        #expect(vm.kbWindowIdx == 0)
        vm.kbCycleWindow(forward: true)
        #expect(vm.kbWindowIdx == 1)
        vm.kbCycleWindow(forward: true)  // wraps back to the header slot
        #expect(vm.kbWindowIdx == -1)
    }

    @Test func cursorSurvivesRefreshAndReseedsWhenCellVanishes() {
        let vm = makeVM(workspaces: [ws(0), ws(1)])
        vm.kbSeedToActiveCell()
        vm.kbMove(dx: 1, dy: 0)
        #expect(vm.kbCursorID == "ws:1")
        vm.apply(workspaces: [ws(0), ws(1, windows: [win(9)])], sections: [])
        #expect(vm.kbCursorID == "ws:1")   // survives
        vm.apply(workspaces: [ws(0, active: true)], sections: [])
        #expect(vm.kbCursorID == "ws:0")   // vanished → reseed to active
    }

    // MARK: - Keyboard workspace swap (lift → aim → commit → landing gate)

    @Test func swapLiftAimsOnlyWorkspaceCellsAndTradesBothSets() {
        let a = win(1), b = win(2), c = win(3)
        let vm = makeVM(workspaces: [
            ws(0, windows: [a, b]),
            ws(1, windows: [c]),
        ])
        seedFrames(vm)
        var swapped: (src: Int, dst: Int, srcIDs: [WindowID], dstIDs: [WindowID])?
        vm.onSwap = { swapped = ($0, $1, $2, $3) }
        vm.kbSeedToActiveCell()
        vm.kbSpaceLift()                   // header slot → workspace lift
        #expect(vm.kitPreview?.dragSource == "ws:0")
        vm.kbMove(dx: 1, dy: 0)            // aim = cursor cell
        #expect(vm.kitPreview?.dropTargetID == "ws:1")
        vm.kbCommit()
        #expect(swapped?.src == 0)
        #expect(swapped?.dst == 1)
        #expect(swapped?.srcIDs == [a.id, b.id])
        #expect(swapped?.dstIDs == [c.id])
        // Landing gate: the pose persists until the backend reflects BOTH
        // halves; a half-landed refresh keeps it.
        vm.apply(workspaces: [ws(0, windows: [c]), ws(1, windows: [a])], sections: [])
        #expect(vm.kitPreview != nil)
        vm.apply(workspaces: [ws(0, windows: [c]), ws(1, windows: [a, b])], sections: [])
        #expect(vm.kitPreview == nil)      // landed → cleared
    }

    @Test func emptySwapCancelsInsteadOfCommitting() {
        let vm = makeVM(workspaces: [ws(0), ws(1)])
        seedFrames(vm)
        var swapFired = false
        vm.onSwap = { _, _, _, _ in swapFired = true }
        vm.kbSeedToActiveCell()
        vm.kbSpaceLift()
        vm.kbMove(dx: 1, dy: 0)
        vm.kbCommit()
        #expect(!swapFired)                // both empty → cancel, not a swap
        #expect(vm.kitPreview == nil)
    }

    @Test func liftFromLensHeaderRefused() {
        let secs = [
            ProjectedSection(id: "section:0:m", label: "m", windows: [win(1)],
                             sourceWorkspaceIndex: nil, sectionType: .matched),
            ProjectedSection(id: "ws:0", label: "a", windows: [],
                             sourceWorkspaceIndex: 0),
        ]
        let vm = makeVM(workspaces: [ws(0, windows: [win(1)])], sections: secs)
        seedFrames(vm)
        vm.kbSeedToActiveCell()            // first cell = the lens
        vm.kbSpaceLift()
        #expect(vm.kitPreview == nil)      // a lens header cannot lift
    }

    // MARK: - Keyboard window move

    @Test func windowLiftMovesAndGatesOnLanding() {
        let a = win(1)
        let vm = makeVM(workspaces: [ws(0, windows: [a]), ws(1)])
        seedFrames(vm)
        var moved: (src: Int, dst: Int, id: WindowID)?
        vm.onMoveWindow = { src, dst, _, id in moved = (src, dst, id) }
        vm.kbSeedToActiveCell()
        vm.kbCycleWindow(forward: true)    // select the window
        vm.kbSpaceLift()                   // lift it
        #expect(vm.hiddenThumbID == a.id)  // the ghost stands in
        vm.kbMove(dx: 1, dy: 0)
        vm.kbCommit()
        #expect(moved?.src == 0)
        #expect(moved?.dst == 1)
        #expect(moved?.id == a.id)
        // Not yet landed → the thumb stays hidden through a stale refresh.
        vm.apply(workspaces: [ws(0, windows: [a]), ws(1)], sections: [])
        #expect(vm.hiddenThumbID == a.id)
        vm.apply(workspaces: [ws(0), ws(1, windows: [a])], sections: [])
        #expect(vm.hiddenThumbID == nil)   // landed → revealed
    }

    @Test func escCancelsLiftThenClearsSlotThenDismisses() {
        let vm = makeVM(workspaces: [ws(0, windows: [win(1)])])
        seedFrames(vm)
        var dismissed = false
        vm.onDismiss = { dismissed = true }
        vm.kbSeedToActiveCell()
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()
        vm.kbEscape()                      // 1: cancel the lift
        #expect(vm.kitPreview == nil)
        #expect(!dismissed)
        #expect(vm.kbWindowIdx == 0)       // slot untouched by the cancel
        vm.kbEscape()                      // 2: clear the window slot
        #expect(vm.kbWindowIdx == -1)
        #expect(!dismissed)
        vm.kbEscape()                      // 3: dismiss
        #expect(dismissed)
    }

    // MARK: - Pointer thumb drag

    @Test func pointerThumbDragResolvesWorkspaceTargetsOnly() {
        let a = win(1)
        let secs = [
            ProjectedSection(id: "ws:0", label: "a", windows: [a],
                             sourceWorkspaceIndex: 0),
            ProjectedSection(id: "section:0:m", label: "m", windows: [a],
                             sourceWorkspaceIndex: nil, sectionType: .matched),
            ProjectedSection(id: "ws:1", label: "b", windows: [],
                             sourceWorkspaceIndex: 1),
        ]
        let vm = makeVM(workspaces: [ws(0, windows: [a]), ws(1)], sections: secs)
        seedFrames(vm)
        var moved = false
        vm.onMoveWindow = { _, _, _, _ in moved = true }
        let cell = vm.cells[0]
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0], thumbIndex: 0,
                            location: CGPoint(x: 50, y: 50))
        // Over the LENS cell (index 1, x 110…210): no target (no source WS).
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0], thumbIndex: 0,
                            location: CGPoint(x: 160, y: 50))
        #expect(vm.kitPreview?.dropTargetID == nil)
        // Over the second WORKSPACE cell (x 220…320): valid target.
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0], thumbIndex: 0,
                            location: CGPoint(x: 270, y: 50))
        #expect(vm.kitPreview?.dropTargetID == "ws:1")
        vm.thumbDragEnded()
        #expect(moved)
    }

    @Test func pointerDragOffCellsCancels() {
        let a = win(1)
        let vm = makeVM(workspaces: [ws(0, windows: [a]), ws(1)])
        seedFrames(vm)
        var moved = false
        vm.onMoveWindow = { _, _, _, _ in moved = true }
        let cell = vm.cells[0]
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0], thumbIndex: 0,
                            location: CGPoint(x: 999, y: 999))
        vm.thumbDragEnded()
        #expect(!moved)
        #expect(vm.hiddenThumbID == nil)
        #expect(vm.kitPreview == nil)
    }

    // MARK: - Refresh suppression (the old layoutSuppressed)

    @Test func pointerBusyBuffersApplyAndFlushesOnRelease() {
        let vm = makeVM(workspaces: [ws(0)])
        vm.pointerBusy = true
        vm.apply(workspaces: [ws(0), ws(1)], sections: [])
        #expect(vm.cells.count == 1)       // frozen mid-press
        vm.pointerBusy = false
        #expect(vm.cells.count == 2)       // flushed on release
    }

    @Test func liveDragBuffersApplyUntilCancel() {
        let a = win(1)
        let vm = makeVM(workspaces: [ws(0, windows: [a]), ws(1)])
        seedFrames(vm)
        vm.kbSeedToActiveCell()
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()
        vm.apply(workspaces: [ws(0, windows: [a]), ws(1), ws(2)], sections: [])
        #expect(vm.cells.count == 2)       // frozen mid-lift
        vm.kbEscape()                      // cancel flushes the buffer
        #expect(vm.cells.count == 3)
    }

    // MARK: - Zoom

    @Test func commitSwitchSkipsZoomUnderReduceMotion() {
        let vm = makeVM(workspaces: [ws(0)])
        seedFrames(vm)
        vm.reduceMotionCheck = { true }
        var performed = false
        vm.commitSwitch(target: "ws:0") { performed = true }
        #expect(performed)                 // instant — no zoom pose
    }

    @Test func teardownFiresPendingZoomExactlyOnce() {
        let vm = makeVM(workspaces: [ws(0)])
        seedFrames(vm)
        vm.reduceMotionCheck = { false }
        vm.snapshotProvider = { _ in NSImage(size: NSSize(width: 8, height: 8)) }
        var performs = 0
        vm.commitSwitch(target: "ws:0") { performs += 1 }
        #expect(performs == 0)             // pose armed, waiting on animation
        vm.finishZoomIfPending()
        vm.finishZoomIfPending()
        #expect(performs == 1)
    }

    // MARK: - Border mapping

    @Test func borderMapsOffAndBreathing() {
        let vm = makeVM(workspaces: [ws(0)])
        vm.applyBorder(effectName: "off", glow: true, width: 2,
                       cycleSeconds: 6, cycleColors: false,
                       minWidth: nil, maxWidth: nil)
        #expect(vm.borderEffect == nil)    // off → NO border (grid contract)
        let t0 = vm.borderFlashToken
        vm.flashBorder()
        #expect(vm.borderFlashToken == t0) // flash is a no-op when off
        vm.applyBorder(effectName: "neon", glow: false, width: 2,
                       cycleSeconds: 6, cycleColors: true,
                       minWidth: 1, maxWidth: 4)
        #expect(vm.borderEffect != nil)
        #expect(vm.borderLineWidth == 1)   // min/max set → breathes 1…4
        #expect(vm.borderBreathTo == 4)
        #expect(vm.borderCyclesColors)
        vm.flashBorder()
        #expect(vm.borderFlashToken == t0 + 1)
        vm.applyBorder(effectName: "neon", glow: false, width: 2,
                       cycleSeconds: 6, cycleColors: false,
                       minWidth: nil, maxWidth: nil)
        #expect(vm.borderLineWidth == 2)   // bare width → fixed, no breathing
        #expect(vm.borderBreathTo == 2)
    }

    // MARK: - Reorder passthrough

    @Test func reorderForwardsSectionAndBoundary() {
        let vm = makeVM(workspaces: [ws(0), ws(1)])
        var got: (String, Int)?
        vm.onReorder = { got = ($0, $1) }
        vm.commitReorder(sectionID: "ws:0", toBoundary: 2)
        #expect(got?.0 == "ws:0")
        #expect(got?.1 == 2)
    }

    // MARK: - Guards around the kit's private drag + gesture-death backstop

    @Test func reorderRefusedWhileHostDragLive() {
        let vm = makeVM(workspaces: [ws(0, windows: [win(1)]), ws(1)])
        seedFrames(vm)
        var got: (String, Int)?
        vm.onReorder = { got = ($0, $1) }
        vm.kbSeedToActiveCell()
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()                     // host drag live
        vm.commitReorder(sectionID: "ws:0", toBoundary: 2)
        #expect(got == nil)                  // a feedback-less reorder is refused
        vm.kbEscape()
        vm.commitReorder(sectionID: "ws:0", toBoundary: 2)
        #expect(got != nil)                  // normal path unaffected
    }

    @Test func pointerFallbackEndsAGestureDeadDrag() {
        let a = win(1)
        let vm = makeVM(workspaces: [ws(0, windows: [a]), ws(1)])
        seedFrames(vm)
        var moved = false
        vm.onMoveWindow = { _, _, _, _ in moved = true }
        let cell = vm.cells[0]
        // A drag whose gesture died after aiming at the second cell: only the
        // monitor's up arrives — the fallback must commit exactly once.
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0], thumbIndex: 0,
                            location: CGPoint(x: 160, y: 50))
        #expect(vm.kitPreview?.dropTargetID == "ws:1")
        vm.pointerDragEndFallback()
        #expect(moved)
        vm.pointerDragEndFallback()          // idempotent: drag is gone
        #expect(vm.hiddenThumbID == a.id)    // landing gate holds the reveal
    }

    @Test func fallbackNeverTouchesAKeyboardLift() {
        let vm = makeVM(workspaces: [ws(0, windows: [win(1)]), ws(1)])
        seedFrames(vm)
        vm.kbSeedToActiveCell()
        vm.kbSpaceLift()                     // keyboard workspace lift
        vm.pointerDragEndFallback()
        #expect(vm.kitPreview != nil)        // still lifted — keys own its end
    }

    @Test func kbLiftRefusedWhilePointerIsDown() {
        let vm = makeVM(workspaces: [ws(0, windows: [win(1)]), ws(1)])
        seedFrames(vm)
        vm.kbSeedToActiveCell()
        vm.pointerBusy = true                // the kit's own drag may be live
        vm.kbSpaceLift()
        #expect(vm.kitPreview == nil)        // no second, host drag
        vm.kbCycleWindow(forward: true)
        vm.kbSpaceLift()
        #expect(vm.kitPreview == nil)
        vm.pointerBusy = false
        vm.kbSpaceLift()                     // window slot lifts again
        #expect(vm.kitPreview != nil)
    }

    // MARK: - Regressions found by the rail migration review (2026-08-25)

    @Test func tabReadingOrderIsRowMajorForStackedWindows() {
        // Two rows: top A(1) C(3), bottom B(2). Unit-normalized hits
        // collapsed `readingOrder`'s row band to the whole square (pure
        // x-sort: A, B, C) — the fix scales hits back to screen size.
        let vm = makeVM(workspaces: [
            ws(0, active: true, windows: [
                win(1, frame: CGRect(x: 0, y: 0, width: 700, height: 350)),
                win(2, frame: CGRect(x: 0, y: 450, width: 700, height: 350)),
                win(3, frame: CGRect(x: 800, y: 0, width: 700, height: 350)),
            ])])
        vm.kbSeedToActiveCell()
        var order: [WindowID] = []
        for _ in 0..<3 {
            vm.kbCycleWindow(forward: true)
            if let s = vm.kbSelectedThumb { order.append(s.thumb.id) }
        }
        #expect(order == [WindowID(serverID: 1), WindowID(serverID: 3),
                          WindowID(serverID: 2)])
    }

    @Test func pointerDragEndFallbackNeverDoubleCommits() {
        // The monitor's post-up fallback fires after the healthy onEnded —
        // with the landing gate armed it must stand down, not re-commit a
        // second backend move.
        var moves = 0
        let w = win(1)
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [w]), ws(1)])
        seedFrames(vm)
        vm.onMoveWindow = { _, _, _, _ in moves += 1 }
        let cell = vm.cells[0]
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0, location: CGPoint(x: 50, y: 50))
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0, location: CGPoint(x: 160, y: 50))
        vm.thumbDragEnded()
        #expect(moves == 1)
        vm.pointerDragEndFallback()               // the async monitor hop
        #expect(moves == 1)
    }

    // MARK: - Landing-gate fences (t-88qt — the drag-takeover duplicate move)

    @Test func landingGateRefusesANewDragTakeover() {
        // The measured takeover: drag A ws0→ws1 commits and arms the gate; a
        // SECOND press (on B, aiming ws:2) inside the ack window used to skip
        // the arm block, steer the OLD drag and re-commit A into ws:2 — B
        // never moves, A moves twice. The fence refuses arm AND mutate.
        var moves: [WindowID] = []
        let vm = makeVM(workspaces: [ws(0, active: true,
                                        windows: [win(1), win(2)]),
                                     ws(1), ws(2)])
        seedFrames(vm)
        vm.onMoveWindow = { _, _, _, id in moves.append(id) }
        let cell = vm.cells[0]
        let dragged = cell.thumbs[0]
        vm.thumbDragChanged(cellID: cell.id, thumb: dragged, thumbIndex: 0,
                            location: CGPoint(x: 160, y: 50))
        vm.thumbDragEnded()                       // → ws:1, gate arms
        #expect(moves == [dragged.id])
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[1],
                            thumbIndex: 1, location: CGPoint(x: 270, y: 50))
        #expect(vm.kitPreview?.dropTargetID == "ws:1")   // old drag unsteered
        vm.thumbDragEnded()                       // second up: swallowed
        #expect(moves == [dragged.id])
        #expect(vm.hiddenThumbID == dragged.id)   // the ghost still stands in
    }

    @Test func duplicateReturnIsSwallowedWhileGatePending() {
        // The rail's Return fence, ported: kbCommit during the ack window
        // must not re-commit the armed drag.
        var moves = 0
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)]),
                                     ws(1)])
        seedFrames(vm)
        vm.onMoveWindow = { _, _, _, _ in moves += 1 }
        let cell = vm.cells[0]
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0, location: CGPoint(x: 160, y: 50))
        vm.thumbDragEnded()
        vm.kbCommit()                             // Return mid-gate: swallowed
        #expect(moves == 1)
    }

    @Test func rejectedMoveReleasesTheGateAtTheAckDeadline() async throws {
        // A backend that silently refuses the move (a sticky window etc.)
        // sends no changed snapshot — the deferred re-apply must give the
        // gate up at overviewDropAckTimeout instead of holding the ghost
        // until the 2 s poll (the rail's scheduleAckDeadline, ported).
        let vm = makeVM(workspaces: [ws(0, active: true, windows: [win(1)]),
                                     ws(1)])
        seedFrames(vm)
        vm.onMoveWindow = { _, _, _, _ in }
        let cell = vm.cells[0]
        vm.thumbDragChanged(cellID: cell.id, thumb: cell.thumbs[0],
                            thumbIndex: 0, location: CGPoint(x: 160, y: 50))
        vm.thumbDragEnded()
        #expect(vm.hiddenThumbID != nil)          // gate armed
        try await Task.sleep(for: .seconds(overviewDropAckTimeout + 0.4))
        #expect(vm.hiddenThumbID == nil)          // released, thumb revealed
        #expect(vm.kitPreview == nil)
    }
}
