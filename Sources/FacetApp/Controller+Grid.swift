// Grid overview lifecycle — the SwiftUI grid's shell (sill WindowShell),
// monitors, show / hide / toggle, and the pre-show tree-panel state dance.
//
// The keyboard model follows the tree's load-bearing invariant: the local
// monitor swallows every nav key and drives the `GridViewModel`; sill's own
// key handling (and its focus ring) never engage. The mouse monitor keeps
// `pointerBusy` true across any press so a backend refresh can't shift the
// scaffold mid-gesture (the old `layoutSuppressed`, now observable from the
// outside because sill's reorder drag is internal to the kit), and catches
// right-clicks for the shared context menus SwiftUI cannot.

import AppKit
import SwiftUI
import FacetCore
import FacetAccessibility
import FacetView
import FacetViewGrid
import ThemeKit

extension Controller {

    func toggleGrid() {
        if isGridVisible { hideGrid() } else { showGrid() }
    }

    func showGrid() {
        Log.debug("showGrid request (isVisible=\(isGridVisible))")
        if isGridVisible { return }
        guard let scr = NSScreen.main else { return }
        // No snapshot yet (cold start, never queried): trigger an async fetch
        // and re-enter once it lands. Bail if the fetch comes back empty so we
        // don't spin re-fetching forever (mirrors showRail).
        if lastWorkspaces.isEmpty {
            let bk = backend
            cliQueue.async {
                let wss = bk.workspaces()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.lastWorkspaces = wss
                        if wss.isEmpty { return }   // nothing to show
                        self.showGrid()
                    }
                }
            }
            return
        }

        // -- View model (snapshot-on-show inputs + callbacks) --
        let vm = GridViewModel(palette: gridPaletteBox.pal)
        vm.config = GridConfig(
            cols: config.effectiveGridCols,
            labelPosition: config.effectiveGridLabelPosition)
        vm.screenFrame = scr.frame
        vm.onDismiss = { [weak self] in self?.hideGrid() }
        vm.onPick = { [weak self, bk = backend] pick in
            // Route every pick through the validated `activateSection`
            // throughline — never `bk.switchWorkspace` directly. The dismiss
            // runs in parallel so the overlay clears as the switch lands.
            switch pick {
            case .workspace(let ws):
                self?.activateSection(.workspace(ws + 1), autoFocus: true)
            case .window(let home, let pid, let id):
                if home >= 0 {
                    self?.activateSection(.workspace(home + 1), autoFocus: false)
                }
                cliQueue.async {
                    // Re-assert until the WM's post-switch default focus
                    // settles on our pick (title empty → serverID match).
                    let win = Window(
                        id: id, pid: pid, appName: "",
                        title: "", isFocused: false,
                        isFloating: false, frame: nil)
                    Focus.assert(win, backend: bk)
                }
            }
            self?.hideGrid()
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
        let host = NSHostingView(rootView: GridContentView(model: vm))
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
        // The grid is taking over the screen, so cancel any pending
        // loading-activate (else the tree's `apply` would enterActive +
        // re-show the panel under the grid once the skeleton settles).
        loadingWantsActive = false
        if panelHost.isVisible { panelHost.hide() }

        // -- Present + fade in (sill ShellFade), then take key --
        ShellFade(duration: overviewFadeIn).fadeIn(panel)
        panel.makeKey()

        // Initial keyboard selection: the active (lit) cell, header slot.
        vm.kbSeedToActiveCell()

        installGridMonitors()

        gridOverlay = panel
        gridVM = vm
        gridHosting = host
        // Screen-edge neon border for the overview + an entrance flash.
        applyBorderFromConfig()
        vm.flashBorder()

        // Kick off captures (snapshot-on-show). Cells paint app icons first
        // and progressively swap to real thumbnails as captures land.
        startOverviewCaptures()
    }

    /// Dismiss the grid overlay. `immediate` tears it down synchronously
    /// (no fade): used when switching to another view, where the grid must
    /// be gone *this turn* and `isGridVisible` false by the time the
    /// caller's panel logic runs. The caller owns what shows next, so the
    /// immediate path skips the tree-restore refresh.
    func hideGrid(immediate: Bool = false) {
        Log.debug("hideGrid\(immediate ? " (immediate)" : "")")
        guard let overlay = gridOverlay else { return }
        if let m = gridKbMonitor { NSEvent.removeMonitor(m); gridKbMonitor = nil }
        if let m = gridMouseMonitor { NSEvent.removeMonitor(m); gridMouseMonitor = nil }
        let vm = gridVM
        vm?.clearThumbnails()
        let restoreTree = !treeWasHidden
        // Drop the references synchronously — the fade is cosmetic, the
        // teardown is not: `apply` must stop feeding the closing grid and
        // `isGridVisible` must read false immediately (mirrors `hideRail`).
        gridOverlay = nil
        gridVM = nil
        gridHosting = nil
        // Closed mid-zoom → the pending switch still fires (the refs are
        // already nil, so the perform's own `hideGrid` is a no-op).
        vm?.finishZoomIfPending()
        if immediate {
            overlay.orderOut(nil)
            return
        }
        ShellFade(duration: overviewFadeOut).fadeOut(overlay)
        DispatchQueue.main.asyncAfter(deadline: .now() + overviewFadeOut) { [weak self] in
            if restoreTree { self?.refresh() }      // re-shows the panel
        }
    }

    // MARK: - Monitors

    private func installGridMonitors() {
        // The shared overview verbs (Esc / Return / Space / Tab / 'm') + the
        // grid's 2-D arrow nav — ALL consumed here (the tree invariant: sill
        // must never double-handle a key or engage its focus ring). The
        // PopupMenu-open guard passes events through to the menu's monitor.
        gridKbMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] e in
            guard let self, let vm = self.gridVM else { return e }
            if PopupMenu.shared.isOpen { return e }
            let shift = e.modifierFlags.contains(.shift)
            switch e.keyCode {
            case 53:     vm.kbEscape();                     return nil
            case 36, 76: vm.kbCommit();                     return nil
            case 49:     vm.kbSpaceLift();                  return nil
            case 48:     vm.kbCycleWindow(forward: !shift); return nil
            case 46:     self.gridKbContextMenu();          return nil
            case 123:    vm.kbMove(dx: -1, dy: 0);          return nil
            case 124:    vm.kbMove(dx: 1, dy: 0);           return nil
            case 126:    vm.kbMove(dx: 0, dy: -1);          return nil
            case 125:    vm.kbMove(dx: 0, dy: 1);           return nil
            default:     return e
            }
        }
        // Pointer bookkeeping + the right-click catch. `pointerBusy` freezes
        // snapshot application across ANY press in the overlay — the only
        // observable envelope around sill's internal reorder drag.
        gridMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]
        ) { [weak self] e in
            guard let self, let vm = self.gridVM,
                  let panel = self.gridOverlay, e.window === panel else { return e }
            // A context menu is up: every click belongs to the menu's own
            // monitor (dismiss / pick) — don't freeze the snapshot for it and
            // don't open a second menu over it (the key monitor's twin guard).
            if PopupMenu.shared.isOpen { return e }
            switch e.type {
            case .leftMouseDown:
                vm.pointerBusy = true
            case .leftMouseUp:
                // Release AFTER SwiftUI finishes this turn's gesture handling
                // so the flush can't reshuffle cells under the drop — and end
                // a pointer drag whose SwiftUI gesture died without an
                // onEnded (the monitor always sees the up; the gesture may
                // not). By this async hop the healthy path has already
                // committed and cleared `drag`, so the fallback is a no-op.
                DispatchQueue.main.async { [weak self] in
                    self?.gridVM?.pointerDragEndFallback()
                    self?.gridVM?.pointerBusy = false
                }
            case .rightMouseDown:
                self.gridRightClick(e)
                return nil
            default:
                break
            }
            return e
        }
    }

    // MARK: - Context menus (③ — the SAME shared PopupMenu the tree shows;
    // the host catches what SwiftUI cannot)

    /// Right-click: WS header → layout-engine picker; window thumb →
    /// window-ops menu. Lens headers stay click-only (no layout of their own).
    private func gridRightClick(_ e: NSEvent) {
        guard let vm = gridVM, let host = gridHosting,
              let win = gridOverlay else { return }
        let p = host.convert(e.locationInWindow, from: nil)
        let scr = win.convertPoint(toScreen: e.locationInWindow)
        if let cell = vm.headerCellAt(point: p) {
            guard cell.sectionType == .workspace else { return }
            ViewContextMenu.showLayout(at: scr, backend: backend,
                                       workspaceIndex: cell.wsIndex,
                                       workspaces: lastWorkspaces,
                                       header: cell.caption,
                                       palette: gridPaletteBox.pal)
            return
        }
        if let (cell, thumb, _) = vm.thumbAt(point: p) {
            // Window ops target the window's HOME WS (resolved), never the
            // cell's `wsIndex` — a lens cell reports −1.
            ViewContextMenu.showWindow(
                at: scr, backend: backend,
                workspaceIndex: vm.windowHomeWS[thumb.id] ?? cell.wsIndex,
                workspaces: lastWorkspaces, pid: thumb.pid, windowID: thumb.id,
                title: "", palette: gridPaletteBox.pal
            ) { [weak self] ops, w, ws in
                self?.runWindowOps(ops, on: w, workspaceIndex: ws)
            }
        }
    }

    /// Keyboard 'm': open the context menu for the kb-selected slot — the WS
    /// header (layout picker) or a window thumb (window ops), anchored to
    /// that cell. No-op without a selection.
    private func gridKbContextMenu() {
        guard let vm = gridVM, let host = gridHosting,
              let win = gridOverlay, let cell = vm.kbCursorCell else { return }
        func screenPt(_ r: CGRect) -> NSPoint {
            win.convertPoint(toScreen:
                host.convert(NSPoint(x: r.minX + 12, y: r.minY), to: nil))
        }
        if vm.kbWindowIdx == -1 {
            guard cell.sectionType == .workspace,
                  let hr = vm.headerFrames[cell.id] else { return }
            ViewContextMenu.showLayout(at: screenPt(hr), backend: backend,
                                       workspaceIndex: cell.wsIndex,
                                       workspaces: lastWorkspaces,
                                       header: cell.caption,
                                       palette: gridPaletteBox.pal)
        } else if let s = vm.kbSelectedThumb,
                  let tr = vm.thumbAbsRect(cellID: s.cell.id,
                                           thumbIndex: s.thumbIndex) {
            ViewContextMenu.showWindow(
                at: screenPt(tr), backend: backend,
                workspaceIndex: vm.windowHomeWS[s.thumb.id] ?? s.cell.wsIndex,
                workspaces: lastWorkspaces, pid: s.thumb.pid,
                windowID: s.thumb.id, title: "", palette: gridPaletteBox.pal
            ) { [weak self] ops, w, ws in
                self?.runWindowOps(ops, on: w, workspaceIndex: ws)
            }
        }
    }
}
