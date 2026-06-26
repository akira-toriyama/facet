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
        // EX-2b: the browse cursor (selectedSectionID) is seeded by the
        // first layoutCells (its stranded-cursor repair snaps nil → the
        // active section) — no explicit seed here.
        rv.onPick = { [weak self, bk = backend] pick in
            guard let self else { return }
            // EX-2b: route every pick through the validated `activateSection`
            // throughline (updates the currentActiveSection mirror on main,
            // clears any active lens on a workspace pick) — never
            // `bk.switchWorkspace` directly. Mirrors the grid's onPick. The
            // dismiss runs in parallel so the overlay clears as the switch lands.
            switch pick {
            case .workspace(let ws):
                // ws is 0-based (cell.wsIndex == Workspace.index); ActiveSection
                // is 1-based → +1. autoFocus → the WS's last-touched window.
                self.activateSection(.workspace(ws + 1), autoFocus: true)
            case .lens(let sectionID):
                // §A: the pick carries the stable section id (`ProjectedSection.id`)
                // straight from the live-rendered cell — route to the id-core,
                // no ambiguous label→id lookup.
                self.activateLensID(sectionID,
                                    ordinal: self.currentMacDesktopOrdinal(),
                                    autoFocus: true)
            case .unassigned(let sectionID):
                // §G: an unassigned cell focuses its FIRST orphan window — no
                // lens toggle, no workspace switch (the unified focus helper,
                // shared with the grid pick + CLI --focus + tree header click).
                self.focusFirstWindow(inSectionID: sectionID)
            case .window(let home, let pid, let id):
                // `home` is the WINDOW's home WS (0-based), resolved via the
                // view's windowHomeWS — correct whether the thumb sat in a
                // workspace OR a lens cell. Switch there (clears any lens,
                // updates the mirror on main), then re-assert focus on the
                // pick. Guard home >= 0 so an unresolvable window focuses
                // without a bogus .workspace(0).
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
