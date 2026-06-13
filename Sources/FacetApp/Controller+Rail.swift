// Workspace rail lifecycle — overlay construction (carousel cells,
// pick / move / swap callbacks, keyboard + scroll monitors) and
// show / hide / toggle. Extracted unchanged from Controller.swift
// (#182 phase 3) — same-module extension, no logic change. Stored
// state stays on the primary declaration (Controller.swift).

import AppKit
import FacetCore
import FacetAccessibility
import FacetView
import FacetViewGrid
import FacetViewRail

extension Controller {

    // MARK: - Rail lifecycle

    func toggleRail() {
        if isRailVisible { hideRail() } else { showRail() }
    }

    func showRail(edge: RailEdge? = nil) {
        let edge = edge ?? config.effectiveRailEdge
        Log.debug("showRail request (isVisible=\(isRailVisible) edge=\(edge.rawValue))")
        if isRailVisible { return }
        guard let scr = NSScreen.main else { return }
        // No snapshot yet (cold start): fetch then re-enter so the rail
        // never paints empty. Bail if the fetch comes back empty (e.g.
        // an unmanaged mac desktop under opt-in `[desktop.N]` config) so
        // we don't spin re-fetching forever.
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

        // Full-screen takeover: a near-black backdrop hides the desktop,
        // the active workspace shows large in the centre, every
        // workspace lines the bottom as a small mini-screen.
        let overlay = RailOverlay(
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

        let rv = RailView(frame: NSRect(origin: .zero, size: scr.frame.size))
        rv.paletteBox = railPaletteBox          // PR-B: rail's own [rail].theme
        rv.autoresizingMask = [.width, .height]
        rv.screenFrame = scr.frame
        rv.edge = edge                              // M9-3: docked edge
        rv.cellsTarget = config.effectiveRailCells  // upper bound on visible cells
        rv.stripPercent = config.effectiveRailStrip // strip band size (% short edge)
        rv.workspaces = lastWorkspaces
        rv.activeIndex = lastWorkspaces.first(where: { $0.isActive })?.index
        rv.selectedWS = rv.activeIndex      // browse cursor starts on the active WS
        // ③ Context menu: header layout picker + window-ops menu.
        rv.backend = backend
        rv.onRunWindowOps = { [weak self] ops, window, ws in
            self?.runWindowOps(ops, on: window, workspaceIndex: ws)
        }
        rv.onPick = { [weak self] ws in
            guard let self else { return }
            // Commit-on-click (grid-like): dispatch the switch off-main
            // and dismiss in parallel so the overlay clears immediately;
            // the workspace-switch lands as it fades out. autoFocus lets
            // the backend focus the destination's last-touched window.
            cliQueue.async {
                self.backend.switchWorkspace(toIndex: ws, autoFocus: true)
            }
            self.hideRail()
        }
        rv.onDismiss = { [weak self] in self?.hideRail() }
        // Click a specific window thumbnail → switch to its WS AND focus
        // THAT window (grid parity). Unlike onPick (which uses
        // autoFocus = the WS's last-touched window), this omits
        // autoFocus then Focus.asserts the picked window. Dispatch
        // off-main + dismiss in parallel, like the grid's onPick.window.
        rv.onPickWindow = { [weak self, bk = backend] ws, pid, id in
            guard let self else { return }
            cliQueue.async {
                bk.switchWorkspace(toIndex: ws)
                let win = Window(id: id, pid: pid, appName: "",
                                 title: "", isFocused: false,
                                 isFloating: false, frame: nil)
                Focus.assert(win, backend: bk)
            }
            self.hideRail()
        }
        // Drag a window onto another WS cell → move it there. The
        // overlay STAYS OPEN (no hideRail) so the user sees the result.
        // Reuses the grid's onDrop body shape.
        rv.onMoveWindow = { [weak self, bk = backend] src, dst, _, id in
            guard src != dst else { return }
            cliQueue.async {
                bk.moveWindow(id, toWorkspaceIndex: dst)
                let wss = bk.workspaces()
                let titles = AXTitles.resolve(wss)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(wss, titles)
                        self?.refreshRailThumbnails(forWSIndices: [src, dst], in: wss)
                    }
                }
            }
        }
        // Drag a header onto another cell → swap the two WS' contents
        // (N+M moveWindow calls; the WM indices stay put).
        rv.onSwap = { [weak self, bk = backend] src, dst, srcIDs, dstIDs in
            guard src != dst else { return }
            cliQueue.async {
                for id in srcIDs { bk.moveWindow(id, toWorkspaceIndex: dst) }
                for id in dstIDs { bk.moveWindow(id, toWorkspaceIndex: src) }
                let wss = bk.workspaces()
                let titles = AXTitles.resolve(wss)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(wss, titles)
                        self?.refreshRailThumbnails(forWSIndices: [src, dst], in: wss)
                    }
                }
            }
        }
        overlay.contentView = rv

        // Hide the tree panel while the rail is up (it would otherwise
        // sit behind the backdrop); restore on dismiss like the grid.
        treeWasHidden = userHidden
        if panelHost.isVisible { panelHost.hide() }

        overlay.alphaValue = 0
        overlay.makeKeyAndOrderFront(nil)
        rv.layoutCells()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = gridFadeIn
            overlay.animator().alphaValue = 1
        }

        // Keyboard: browse along the strip's axis (←/→ for a top/bottom
        // rail, ↑/↓ for left/right), Return commits, Esc dismisses (the
        // overlay is key, so a local monitor fires). The cross-axis
        // arrows pass through (inert) so they don't fight the browse.
        railKbMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] e in
            guard let rv = self?.railView else { return e }
            // A context menu ('m') is up: let its own monitor handle keys
            // (Esc closes JUST the menu) — don't run rail nav or close the
            // whole overlay (③).
            if PopupMenu.shared.isOpen { return e }
            let shift = e.modifierFlags.contains(.shift)
            let horizontal = rv.edge.axis == .horizontal
            switch e.keyCode {
            case 53:     rv.kbEscape();                     return nil  // Esc → cancel/close
            case 36, 76: rv.kbCommit();                     return nil  // Return → commit
            case 49:     rv.kbSpaceLift();                  return nil  // Space → lift
            case 48:     rv.kbCycleWindow(forward: !shift); return nil  // Tab / Shift-Tab
            case 123 where horizontal: rv.kbMoveSelection(dx: -1); return nil  // ← prev
            case 124 where horizontal: rv.kbMoveSelection(dx:  1); return nil  // → next
            case 126 where !horizontal: rv.kbMoveSelection(dx: -1); return nil  // ↑ prev
            case 125 where !horizontal: rv.kbMoveSelection(dx:  1); return nil  // ↓ next
            case 46:     rv.kbContextMenu();                return nil  // 'm' (③)
            default:     return e
            }
        }

        // Scroll-wheel browse (⑦): a monitor (not a view override) so it
        // fires for the nonactivating panel — scroll DOWN = next, UP =
        // previous, on every edge. Consumed so it never leaks to the app
        // behind the overlay.
        railScrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] e in
            guard let rv = self?.railView else { return e }
            rv.scrollRotate(e)
            return nil
        }

        railOverlay = overlay
        railView = rv
        // Neon border framing the strip band + an entrance flash.
        applyBorderFromConfig()
        rv.flashBorder()

        // Request every window in every workspace from the shared
        // `winPreview`, which the Controller's thumbnail timer keeps
        // warm in the background — so on open the cells paint real
        // thumbnails from the cache immediately (no app-icon flash).
        // The rail is a full-screen modal that HIDES the tree, so the
        // tree's `bump()` can't cancel these in-flight captures while
        // it's up (no separate instance needed). Snapshot-on-show.
        if #available(macOS 14.0, *), let wp = winPreview as? WindowPreview {
            for ws in lastWorkspaces {
                for win in ws.windows {
                    let id = win.id
                    wp.request(id) { [weak self] img, _, gotID in
                        MainActor.assumeIsolated {
                            self?.railView?.setThumbnail(img, for: gotID)
                        }
                    }
                }
            }
        }
    }

    func hideRail() {
        Log.debug("hideRail")
        guard let overlay = railOverlay else { return }
        if let m = railKbMonitor {
            NSEvent.removeMonitor(m); railKbMonitor = nil
        }
        if let m = railScrollMonitor {
            NSEvent.removeMonitor(m); railScrollMonitor = nil
        }
        railView?.clearDrag()        // explicit cancel if a drag is mid-flight
        railView?.clearThumbnails()
        railView?.stopBorder()       // no orphaned border timer
        // Flip `isRailVisible` synchronously so a quick hide→show within
        // the fade window builds a fresh overlay instead of no-op'ing.
        let restoreTree = !treeWasHidden
        railOverlay = nil
        railView = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = gridFadeOut
            overlay.animator().alphaValue = 0
        }) { [weak self] in
            overlay.orderOut(nil)
            if restoreTree { self?.refresh() }   // re-shows the tree panel
        }
    }
}
