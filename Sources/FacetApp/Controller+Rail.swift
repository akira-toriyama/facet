// Workspace rail lifecycle — the SwiftUI rail's shell (sill WindowShell),
// monitors, show / hide / toggle, and the pre-show tree-panel state dance.
//
// The keyboard model follows the tree's load-bearing invariant: the local
// monitor swallows every nav key and drives the `RailViewModel`; no
// SwiftUI key handling or focus ever engages. The browse arrows map to
// the strip's axis (←/→ for a top/bottom rail, ↑/↓ for left/right); the
// cross-axis arrows pass through, inert. The scroll monitor rotates the
// carousel (the panel is nonactivating, so a view responder chain never
// sees the wheel); the mouse monitor keeps `pointerBusy` true across any
// press and catches right-clicks for the shared context menus.

import AppKit
import SwiftUI
import FacetCore
import FacetAccessibility
import FacetView
import FacetViewRail
import ThemeKit

extension Controller {

    func toggleRail() {
        if isRailVisible { hideRail() } else { showRail() }
    }

    func showRail(edge: RailEdge? = nil) {
        let edge = edge ?? config.effectiveRailEdge
        Log.debug("showRail request (isVisible=\(isRailVisible) edge=\(edge.rawValue))")
        if isRailVisible { return }
        guard let scr = NSScreen.main else { return }
        // No snapshot yet (cold start): fetch then re-enter so the rail
        // never paints empty. Bail if the fetch comes back empty (e.g. an
        // unmanaged mac desktop under opt-in config) so we don't spin.
        if lastWorkspaces.isEmpty {
            let bk = backend
            cliQueue.async {
                let wss = bk.workspaces()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.lastWorkspaces = wss
                        if wss.isEmpty { return }   // nothing to show
                        self.showRail(edge: edge)   // forward the requested edge
                    }
                }
            }
            return
        }

        // -- View model (live-fed inputs + callbacks) --
        let vm = RailViewModel(palette: railPaletteBox.pal)
        vm.config = RailConfig(
            edge: edge,                              // M9-3: docked edge
            cellsTarget: config.effectiveRailCells,  // visible-cell cap
            stripPercent: config.effectiveRailStrip) // band size (% short edge)
        vm.screenFrame = scr.frame
        vm.viewSize = scr.frame.size
        vm.onDismiss = { [weak self] in self?.hideRail() }
        vm.onPick = { [weak self, bk = backend] pick in
            guard let self else { return }
            // Route every pick through the validated `activateSection`
            // throughline — never `bk.switchWorkspace` directly. The
            // dismiss runs in parallel so the overlay clears as the
            // switch lands.
            switch pick {
            case .workspace(let ws):
                self.activateSection(.workspace(ws + 1), autoFocus: true)
            case .window(let home, let pid, let id):
                // `home` is the WINDOW's home WS (0-based), resolved via
                // the VM's windowHomeWS rather than the cell it was drawn
                // in. Guard home >= 0 so an unresolvable window focuses
                // without a bogus `.workspace(0)`.
                if home >= 0 {
                    self.activateSection(.workspace(home + 1), autoFocus: false)
                }
                cliQueue.async {
                    let win = Window(id: id, pid: pid, appName: "",
                                     title: "", isFocused: false,
                                     isFloating: false, frame: nil)
                    Focus.assert(win, backend: bk)
                }
            }
            self.hideRail()
        }
        vm.onMoveWindow = { [weak self] src, dst, _, id in
            self?.overviewMoveWindow(id, from: src, to: dst)
        }
        vm.onSwap = { [weak self] src, dst, srcIDs, dstIDs in
            self?.overviewSwap(from: src, to: dst, srcIDs: srcIDs, dstIDs: dstIDs)
        }
        vm.onReorder = { [weak self] sectionID, boundary in
            self?.reorderSection(move: sectionID, toBoundary: boundary)
        }
        vm.apply(workspaces: lastWorkspaces, sections: lastSections)

        // -- Shell (sill floor-2: the window is AppKit, the content SwiftUI) --
        let host = NSHostingView(rootView: RailContentView(model: vm))
        let panel = makeWindowShell(WindowShellSpec(
            keyMode: .always,           // Esc / arrows / Space / Return need key
            chrome: .borderless,
            nonactivating: true,
            level: NSWindow.Level(
                rawValue: NSWindow.Level.statusBar.rawValue + 2),   // above tree
            collectionBehavior: [.canJoinAllSpaces, .stationary,
                                 .fullScreenAuxiliary],
            clickThrough: false,
            hasShadow: false,
            isOpaque: false,
            backgroundColor: .clear))
        panel.setFrame(scr.frame, display: false)
        host.frame = NSRect(origin: .zero, size: scr.frame.size)
        panel.contentView = host
        vm.snapshotProvider = { [weak host] rect in host?.snapshotRegion(rect) }

        // -- Hide tree panel, remember pre-show state --
        treeWasHidden = userHidden
        loadingWantsActive = false
        if panelHost.isVisible { panelHost.hide() }

        // -- Present + fade in (sill ShellFade), then take key --
        ShellFade(duration: overviewFadeIn).fadeIn(panel)
        panel.makeKey()

        installRailMonitors(edge: edge)

        railOverlay = panel
        railVM = vm
        railHosting = host
        // Screen-edge neon border for the overview + an entrance flash.
        applyBorderFromConfig()
        vm.flashBorder()

        // Kick off captures. The rail paints captures only — cells show
        // the subtle fill until the shared winPreview cache lands images.
        startOverviewCaptures()
    }

    func hideRail() {
        Log.debug("hideRail")
        guard let overlay = railOverlay else { return }
        if let m = railKbMonitor { NSEvent.removeMonitor(m); railKbMonitor = nil }
        if let m = railScrollMonitor { NSEvent.removeMonitor(m); railScrollMonitor = nil }
        if let m = railMouseMonitor { NSEvent.removeMonitor(m); railMouseMonitor = nil }
        let vm = railVM
        vm?.cancelDrag()             // explicit cancel if a drag is mid-flight
        vm?.clearThumbnails()
        let restoreTree = !treeWasHidden
        // Drop the references synchronously — `apply` must stop feeding the
        // closing rail and `isRailVisible` must read false immediately (a
        // quick hide→show within the fade window builds a fresh overlay).
        railOverlay = nil
        railVM = nil
        railHosting = nil
        // Closed mid-zoom → the pending switch still fires; also settles
        // the slide timer + crossfade snapshot.
        vm?.teardown()
        ShellFade(duration: overviewFadeOut).fadeOut(overlay)
        DispatchQueue.main.asyncAfter(deadline: .now() + overviewFadeOut) { [weak self] in
            if restoreTree { self?.refresh() }      // re-shows the panel
        }
    }

    // MARK: - Monitors

    private func installRailMonitors(edge: RailEdge) {
        // The shared overview verbs (Esc / Return / Space / Tab / 'm') +
        // the rail's 1-D browse along the strip's axis — ALL consumed here.
        // The PopupMenu-open guard passes events to the menu's monitor.
        railKbMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] e in
            guard let self, let vm = self.railVM else { return e }
            if PopupMenu.shared.isOpen { return e }
            let shift = e.modifierFlags.contains(.shift)
            let horizontal = edge.axis == .horizontal
            switch e.keyCode {
            case 53:     vm.kbEscape();                     return nil
            case 36, 76: vm.kbCommit();                     return nil
            case 49:     vm.kbSpaceLift();                  return nil
            case 48:     vm.kbCycleWindow(forward: !shift); return nil
            case 46:     self.railKbContextMenu();          return nil
            case 123 where horizontal:  vm.kbMoveSelection(dx: -1); return nil  // ← prev
            case 124 where horizontal:  vm.kbMoveSelection(dx:  1); return nil  // → next
            case 126 where !horizontal: vm.kbMoveSelection(dx: -1); return nil  // ↑ prev
            case 125 where !horizontal: vm.kbMoveSelection(dx:  1); return nil  // ↓ next
            default:     return e
            }
        }
        // Scroll-wheel browse (⑦): down = next, up = previous, on every
        // edge. Consumed so it never leaks to the app behind the overlay.
        railScrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] e in
            guard let vm = self?.railVM else { return e }
            vm.scrollRotate(deltaY: e.scrollingDeltaY,
                            precise: e.hasPreciseScrollingDeltas,
                            gestureBegan: e.phase.contains(.began),
                            isMomentum: e.momentumPhase != [])
            return nil
        }
        // Pointer bookkeeping + the right-click catch. `pointerBusy`
        // freezes snapshot application across ANY press in the overlay.
        railMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]
        ) { [weak self] e in
            guard let self, let vm = self.railVM,
                  let panel = self.railOverlay, e.window === panel else { return e }
            // The up-release bookkeeping runs BEFORE the PopupMenu guard: a
            // menu opening mid-press (the `m` key) would otherwise swallow
            // the up event and latch `pointerBusy` — freezing snapshot
            // application for the rail's whole lifetime.
            if e.type == .leftMouseUp {
                // Release AFTER SwiftUI finishes this turn's gesture
                // handling, and end a pointer drag whose gesture died
                // without an onEnded (the monitor always sees the up).
                DispatchQueue.main.async { [weak self] in
                    self?.railVM?.pointerDragEndFallback()
                    self?.railVM?.pointerBusy = false
                }
                NSCursor.arrow.set()      // the old mouseUp defer
                return e
            }
            if PopupMenu.shared.isOpen { return e }
            switch e.type {
            case .leftMouseDown:
                vm.pointerBusy = true
            case .rightMouseDown:
                vm.settleSlide()          // hit tests vs the eased offset
                self.railRightClick(e)
                return nil
            default:
                break
            }
            return e
        }
    }

    // MARK: - Context menus (③ — the SAME shared PopupMenu the tree /
    // grid show; the host catches what SwiftUI cannot)

    /// Right-click: WS header → layout-engine picker; window thumb (hero
    /// or strip) → window-ops menu. Lens headers stay click-only.
    private func railRightClick(_ e: NSEvent) {
        guard let vm = railVM, let host = railHosting,
              let win = railOverlay, !vm.isDragging else { return }
        let p = host.convert(e.locationInWindow, from: nil)
        let scr = win.convertPoint(toScreen: e.locationInWindow)
        if let cell = vm.headerCellAt(p) {
            guard cell.sectionType == .workspace else { return }
            ViewContextMenu.showLayout(at: scr, backend: backend,
                                       workspaceIndex: cell.wsIndex,
                                       workspaces: lastWorkspaces,
                                       header: cell.caption,
                                       palette: railPaletteBox.pal)
            return
        }
        if let (cell, thumb, _) = vm.thumbAt(p) {
            // Window ops target the window's HOME WS (resolved), never the
            // cell's `wsIndex` — a lens cell reports −1, no menu then.
            let home = vm.windowHomeWS[thumb.id] ?? cell.wsIndex
            guard home >= 0 else { return }
            ViewContextMenu.showWindow(
                at: scr, backend: backend, workspaceIndex: home,
                workspaces: lastWorkspaces, pid: thumb.pid, windowID: thumb.id,
                title: "", palette: railPaletteBox.pal
            ) { [weak self] ops, w, ws in
                self?.runWindowOps(ops, on: w, workspaceIndex: ws)
            }
        }
    }

    /// Keyboard 'm': context menu for the centred WS — the header (layout
    /// picker) when no hero window is cursored, else that window's ops.
    private func railKbContextMenu() {
        guard let vm = railVM, let host = railHosting,
              let win = railOverlay, let cell = vm.selectedCell else { return }
        func screenPt(_ r: CGRect) -> NSPoint {
            win.convertPoint(toScreen:
                host.convert(NSPoint(x: r.minX + 12, y: r.minY), to: nil))
        }
        if vm.kbWindowIdx == -1 {
            guard cell.sectionType == .workspace,
                  let hr = vm.placement(of: cell.id)?.headerRect else { return }
            ViewContextMenu.showLayout(at: screenPt(hr), backend: backend,
                                       workspaceIndex: cell.wsIndex,
                                       workspaces: lastWorkspaces,
                                       header: cell.caption,
                                       palette: railPaletteBox.pal)
        } else if let s = vm.kbSelectedThumb,
                  let tr = vm.heroThumbRect(thumbIndex: s.thumbIndex)
                    ?? vm.stripThumbRect(cellID: s.cell.id,
                                         thumbIndex: s.thumbIndex) {
            let home = vm.windowHomeWS[s.thumb.id] ?? cell.wsIndex
            guard home >= 0 else { return }
            ViewContextMenu.showWindow(
                at: screenPt(tr), backend: backend, workspaceIndex: home,
                workspaces: lastWorkspaces, pid: s.thumb.pid,
                windowID: s.thumb.id, title: "", palette: railPaletteBox.pal
            ) { [weak self] ops, w, ws in
                self?.runWindowOps(ops, on: w, workspaceIndex: ws)
            }
        }
    }
}
