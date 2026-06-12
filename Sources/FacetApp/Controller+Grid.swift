// Grid overview lifecycle — overlay construction (cells, DnD
// callbacks, keyboard monitor), show / hide / toggle, and the
// pre-show tree-panel state dance. Extracted unchanged from
// Controller.swift (#182 phase 3) — same-module extension, no logic
// change. Stored state stays on the primary declaration
// (Controller.swift).

import AppKit
import FacetCore
import FacetAccessibility
import FacetView
import FacetViewGrid

extension Controller {

    // MARK: - Grid lifecycle

    func toggleGrid() {
        if isGridVisible { hideGrid() } else { showGrid() }
    }

    func showGrid() {
        Log.debug("showGrid request (isVisible=\(isGridVisible))")
        if isGridVisible { return }
        guard let scr = NSScreen.main else { return }
        // No snapshot yet (cold start, never queried): trigger an
        // async fetch and re-enter once it lands. Keeps the UX
        // consistent — pressing --view=grid always either shows or
        // no-ops, never shows an empty grid.
        if lastWorkspaces.isEmpty {
            let bk = backend
            cliQueue.async {
                let wss = bk.workspaces()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.lastWorkspaces = wss
                        self?.showGrid()
                    }
                }
            }
            return
        }

        // -- Build overlay --
        let overlay = GridOverlay(
            contentRect: scr.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        overlay.isFloatingPanel = true
        overlay.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 2)   // above tree
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .fullScreenAuxiliary]

        // Solid near-black backdrop (no vibrancy). The slight
        // transparency keeps a hint of desktop visible during the
        // fade so it reads as "overlay opening" not "screen blanked."
        let host = NSView(frame: NSRect(origin: .zero,
                                        size: scr.frame.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(gridBackdropAlpha).cgColor

        let gv = GridView(frame: host.bounds)
        gv.autoresizingMask = [.width, .height]
        gv.workspaces = lastWorkspaces
        gv.activeIndex = lastWorkspaces.first(where: {
            $0.isActive
        })?.index
        gv.screenFrame = scr.frame
        gv.config = GridConfig(
            cols: config.effectiveGridCols,
            labelPosition: config.effectiveGridLabelPosition)
        gv.onDismiss = { [weak self] in self?.hideGrid() }
        // ③ Context menu: header layout picker + window-ops menu.
        gv.backend = backend
        gv.onRunWindowOps = { [weak self] ops, window, ws in
            self?.runWindowOps(ops, on: window, workspaceIndex: ws)
        }
        gv.onDrop = { [weak self, bk = backend] src, dst, _, id in
            guard src != dst else { return }
            cliQueue.async {
                bk.moveWindow(id, toWorkspaceIndex: dst)
                let wss = bk.workspaces()
                let titles = AXTitles.resolve(wss)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(wss, titles)
                        self?.refreshGridThumbnails(
                            forWSIndices: [src, dst], in: wss)
                    }
                }
            }
        }
        gv.onSwap = { [weak self, bk = backend] src, dst, srcIDs, dstIDs in
            // Workspace-swap: trade contents of src ↔ dst. WM's
            // workspace index is left alone so each cell's grid
            // position (= user's bound hotkey) stays put — only
            // windows move. N+M moveWindow calls in sequence
            // off-main, then a single apply at the end so the grid
            // re-lays out in one pass.
            guard src != dst else { return }
            cliQueue.async {
                for id in srcIDs {
                    bk.moveWindow(id, toWorkspaceIndex: dst)
                }
                for id in dstIDs {
                    bk.moveWindow(id, toWorkspaceIndex: src)
                }
                let wss = bk.workspaces()
                let titles = AXTitles.resolve(wss)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(wss, titles)
                        self?.refreshGridThumbnails(
                            forWSIndices: [src, dst], in: wss)
                    }
                }
            }
        }
        gv.onPick = { [weak self, bk = backend] pick in
            // Dispatch the WM action off-main and dismiss in
            // parallel so the overlay clears immediately — the
            // workspace-switch animation lands as the overlay fades
            // out.
            switch pick {
            case .workspace(let ws):
                // Grid cell click without a specific window — let
                // the backend auto-focus the destination's
                // last-touched window (or activate Finder if empty).
                cliQueue.async {
                    bk.switchWorkspace(toIndex: ws, autoFocus: true)
                }
            case .window(let ws, let pid, let id):
                cliQueue.async {
                    bk.switchWorkspace(toIndex: ws)
                    // Re-assert until the WM's post-switch default
                    // focus settles on our pick. Title is empty —
                    // the grid doesn't surface titles, so focus
                    // falls back to serverID match.
                    let win = Window(
                        id: id, pid: pid, appName: "",
                        title: "", isFocused: false,
                        isFloating: false, frame: nil)
                    Focus.assert(win, backend: bk)
                }
            }
            self?.hideGrid()
        }
        host.addSubview(gv)
        overlay.contentView = host

        // -- Hide tree panel, remember pre-show state --
        treeWasHidden = userHidden
        if panelHost.isVisible { panelHost.hide() }

        // -- Present + fade in --
        overlay.alphaValue = 0
        overlay.makeKeyAndOrderFront(nil)
        gv.layoutCells()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = gridFadeIn
            overlay.animator().alphaValue = 1
        }

        // Initial keyboard selection: active workspace if visible,
        // else first cell.
        gv.kbSelectedWS = lastWorkspaces.first(where: {
            $0.isActive
        })?.index ?? lastWorkspaces.first?.index

        // -- Local key monitor for grid kb input --
        gridKbMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] e in
            guard let gv = self?.gridView else { return e }
            // A context menu ('m') is up: let its own monitor handle keys
            // (Esc closes JUST the menu, ↑↓/Enter navigate it) — don't run
            // grid nav or let Esc close the whole overlay (③).
            if PopupMenu.shared.isOpen { return e }
            let shift = e.modifierFlags.contains(.shift)
            switch e.keyCode {
            case 53:  gv.kbEscape();                       return nil
            case 36, 76:
                gv.kbCommit();                             return nil
            case 49:
                // Space lifts the selection — a window (move) or the
                // header slot (whole-WS swap). Theme A: no Shift; Tab
                // moves between the header and the windows.
                gv.kbSpaceLift();                          return nil
            case 48:
                gv.kbCycleWindow(forward: !shift);         return nil
            case 123: gv.kbMoveSelection(dx: -1, dy: 0);   return nil
            case 124: gv.kbMoveSelection(dx:  1, dy: 0);   return nil
            case 126: gv.kbMoveSelection(dx: 0, dy: -1);   return nil
            case 125: gv.kbMoveSelection(dx: 0, dy:  1);   return nil
            case 46:  gv.kbContextMenu();                  return nil  // 'm' (③)
            default:  return e
            }
        }

        gridOverlay = overlay
        gridView = gv
        gridBackdrop = host
        // Screen-edge neon border for the overview + an entrance flash.
        applyBorderFromConfig()
        gv.flashBorder()

        // Kick off captures for every window in every workspace.
        // Each capture is async + independent — cells paint with
        // app icons first and progressively swap to real thumbnails
        // as captures land. Snapshot-on-show: no refresh during
        // display.
        if #available(macOS 14.0, *),
           let wp = winPreview as? WindowPreview {
            for ws in lastWorkspaces {
                for win in ws.windows {
                    let id = win.id
                    wp.request(id) { [weak self] img, _, gotID in
                        MainActor.assumeIsolated {
                            self?.gridView?.setThumbnail(img, for: gotID)
                        }
                    }
                }
            }
        }
    }

    /// Dismiss the grid overlay. `immediate` tears it down
    /// synchronously (no fade): used when switching to another view,
    /// where the grid must be gone *this turn* — both so it doesn't
    /// ride a mac-desktop slide (the `--view=tree` chord binding
    /// fires right before the switch) and so `isGridVisible` is false
    /// by the time the caller's `showLoading` / panel logic runs. The
    /// caller owns what shows next, so the immediate path skips the
    /// tree-restore refresh.
    func hideGrid(immediate: Bool = false) {
        Log.debug("hideGrid\(immediate ? " (immediate)" : "")")
        guard let overlay = gridOverlay else { return }
        if let m = gridKbMonitor {
            NSEvent.removeMonitor(m); gridKbMonitor = nil
        }
        gridView?.clearThumbnails()
        gridView?.stopBorder()        // no orphaned border timer
        let restoreTree = !treeWasHidden
        if immediate {
            overlay.orderOut(nil)
            gridOverlay = nil; gridView = nil; gridBackdrop = nil
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = gridFadeOut
            overlay.animator().alphaValue = 0
        }) { [weak self] in
            guard let self else { return }
            overlay.orderOut(nil)
            self.gridOverlay = nil
            self.gridView = nil
            self.gridBackdrop = nil
            if restoreTree { self.refresh() }       // re-shows the panel
        }
    }
}
