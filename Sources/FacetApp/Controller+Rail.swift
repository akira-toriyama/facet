// Workspace rail lifecycle — overlay construction (carousel cells,
// pick / move / swap callbacks, keyboard + scroll monitors) and
// show / hide / toggle. Extracted unchanged from Controller.swift
// (#182 phase 3) — same-module extension, no logic change. Stored
// state stays on the primary declaration (Controller.swift).

import AppKit
import FacetCore
import FacetAccessibility
import FacetView
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
        // an unmanaged mac desktop under opt-in `[[desktop.N.section]]`
        // config) so we don't spin re-fetching forever.
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
        let overlay = OverviewPanel.fullScreen(scr.frame)

        let rv = RailView(frame: NSRect(origin: .zero, size: scr.frame.size))
        seedOverviewCommon(rv, paletteBox: railPaletteBox,
                           screenFrame: scr.frame,
                           onDismiss: { [weak self] in self?.hideRail() })
        // -- Rail-specific inputs --
        rv.edge = edge                              // M9-3: docked edge
        rv.cellsTarget = config.effectiveRailCells  // upper bound on visible cells
        rv.stripPercent = config.effectiveRailStrip // strip band size (% short edge)
        rv.selectedWS = rv.activeIndex      // browse cursor starts on the active WS
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
        overlay.contentView = rv

        // Hide the tree panel while the rail is up (it would otherwise
        // sit behind the backdrop); restore on dismiss like the grid.
        treeWasHidden = userHidden
        if panelHost.isVisible { panelHost.hide() }

        presentOverview(overlay, view: rv)

        // Keyboard: the shared overview verbs (Esc / Return / Space /
        // Tab / 'm') + the rail's browse along the strip's axis (←/→ for
        // a top/bottom rail, ↑/↓ for left/right). The cross-axis arrows
        // pass through (inert) so they don't fight the browse. The
        // overlay is key, so this local monitor fires.
        railKbMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] e in
            guard let self, let rv = self.railView else { return e }
            // A context menu ('m') is up: let its own monitor handle keys
            // (Esc closes JUST the menu) — don't run rail nav or close the
            // whole overlay (③).
            if PopupMenu.shared.isOpen { return e }
            let shift = e.modifierFlags.contains(.shift)
            if self.overviewCommonKey(e.keyCode, shift: shift, on: rv) { return nil }
            let horizontal = rv.edge.axis == .horizontal
            switch e.keyCode {
            case 123 where horizontal: rv.kbMoveSelection(dx: -1); return nil  // ← prev
            case 124 where horizontal: rv.kbMoveSelection(dx:  1); return nil  // → next
            case 126 where !horizontal: rv.kbMoveSelection(dx: -1); return nil  // ↑ prev
            case 125 where !horizontal: rv.kbMoveSelection(dx:  1); return nil  // ↓ next
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
        startOverviewCaptures()
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
            ctx.duration = overviewFadeOut
            overlay.animator().alphaValue = 0
        }) { [weak self] in
            overlay.orderOut(nil)
            if restoreTree { self?.refresh() }   // re-shows the tree panel
        }
    }
}
