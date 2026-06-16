// Wiring shared by the two overview surfaces — the full-screen grid
// (`Controller+Grid`) and the workspace rail (`Controller+Rail`). Both
// show paths were near-identical copies: build the `OverviewPanel`,
// seed the snapshot-on-show inputs, wire the context-menu / move / swap
// callbacks, fade in, kick off thumbnails. These helpers, typed on
// `some OverviewView` (FacetView), are the single home for that common
// surface; each show path keeps only its genuinely-different parts
// (grid's host backdrop + `GridPick`; the rail's edge / carousel /
// scroll-wheel browse). Same-module extension — stored state lives on
// the primary `Controller` declaration.

import AppKit
import FacetCore
import FacetAccessibility
import FacetView

extension Controller {

    // MARK: - Build / present

    /// Seed the inputs + callbacks both overview views share. The
    /// per-surface bits (palette box, dismiss target) come in as
    /// parameters; the view-specific inputs (grid `config`, rail
    /// `edge` / `cellsTarget` / cursors / pick callbacks) stay in each
    /// show path.
    func seedOverviewCommon(_ v: some OverviewView,
                            paletteBox: PaletteBox,
                            screenFrame: CGRect,
                            onDismiss: @escaping () -> Void) {
        v.paletteBox = paletteBox
        v.autoresizingMask = [.width, .height]
        v.workspaces = lastWorkspaces
        v.activeIndex = lastWorkspaces.first(where: { $0.isActive })?.index
        v.screenFrame = screenFrame
        // ③ Context menu: header layout picker + window-ops menu.
        v.backend = backend
        v.onDismiss = onDismiss
        v.onRunWindowOps = { [weak self] ops, window, ws in
            self?.runWindowOps(ops, on: window, workspaceIndex: ws)
        }
        // Drag a window thumbnail onto another WS cell → move it there.
        v.onMoveWindow = { [weak self] src, dst, _, id in
            self?.overviewMoveWindow(id, from: src, to: dst)
        }
        // Drag a cell header onto another → swap the two WS' contents
        // (N+M moveWindow calls; the WM indices stay put).
        v.onSwap = { [weak self] src, dst, srcIDs, dstIDs in
            self?.overviewSwap(from: src, to: dst, srcIDs: srcIDs, dstIDs: dstIDs)
        }
    }

    /// Present the overlay + fade it in (identical for both surfaces).
    func presentOverview(_ overlay: OverviewPanel, view: some OverviewView) {
        overlay.alphaValue = 0
        overlay.makeKeyAndOrderFront(nil)
        view.layoutCells()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = overviewFadeIn
            overlay.animator().alphaValue = 1
        }
    }

    // MARK: - Move / swap commits (backend round-trip)

    /// Move `id` to `dst` off-main, re-query, apply, then refresh the
    /// affected cells' thumbnails. Shared by the grid's drop and the
    /// rail's window-drag (`onMoveWindow`).
    func overviewMoveWindow(_ id: WindowID, from src: Int, to dst: Int) {
        guard src != dst else { return }
        let bk = backend
        cliQueue.async { [weak self] in
            bk.moveWindow(id, toWorkspaceIndex: dst)
            let wss = bk.workspaces()
            let titles = AXTitles.resolve(wss)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(wss, titles)
                    self?.refreshOverviewThumbnails(forWSIndices: [src, dst], in: wss)
                }
            }
        }
    }

    /// Trade the contents of `src` ↔ `dst`: fire N+M `moveWindow` calls
    /// (srcIDs → dst, then dstIDs → src) off-main, then a single apply.
    /// The WM's workspace index is never touched, so each cell's grid
    /// position (= the user's bound hotkey) stays put — only windows
    /// move. Shared by the grid + rail `onSwap`.
    func overviewSwap(from src: Int, to dst: Int,
                      srcIDs: [WindowID], dstIDs: [WindowID]) {
        guard src != dst else { return }
        let bk = backend
        cliQueue.async { [weak self] in
            for id in srcIDs { bk.moveWindow(id, toWorkspaceIndex: dst) }
            for id in dstIDs { bk.moveWindow(id, toWorkspaceIndex: src) }
            let wss = bk.workspaces()
            let titles = AXTitles.resolve(wss)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(wss, titles)
                    self?.refreshOverviewThumbnails(forWSIndices: [src, dst], in: wss)
                }
            }
        }
    }

    // MARK: - Thumbnails

    /// Snapshot-on-show capture kick-off: request every window in every
    /// workspace once. Cells paint app icons / placeholders first and
    /// swap to real thumbnails as captures land. Feeds whichever
    /// overview is on screen (the other ref is `nil` → skipped); grid
    /// and rail are mutually exclusive, so this matches feeding the one
    /// shown — same shape as `pushFreshThumbnails`.
    func startOverviewCaptures() {
        guard let wp = winPreview else { return }
        for ws in lastWorkspaces {
            for win in ws.windows {
                captureAndPushToOverview(win.id, wp)
            }
        }
    }

    /// Force a re-capture for every window in the listed workspace
    /// indices and feed the fresh images into whichever overview is up.
    /// Called after a DnD / swap so the cached thumbnails (stale crop /
    /// size after a BSP / stack reflow) refresh instead of waiting for
    /// the 5 s TTL. Pre-invalidates so a refresh tick firing before the
    /// 50 ms delay can't paint the stale cache. 50 ms is the empirical
    /// floor where the WM's reflow has committed but the drop still
    /// feels "right after"; under 30 ms grabs the pre-move frame on BSP.
    func refreshOverviewThumbnails(forWSIndices indices: [Int],
                                   in wss: [Workspace]) {
        guard let wp = winPreview,
              gridView != nil || railView != nil else { return }
        let want = Set(indices)
        let ids: [WindowID] = wss
            .filter { want.contains($0.index) }
            .flatMap { $0.windows.map(\.id) }
        for id in ids { wp.invalidate(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            for id in ids { self.captureAndPushToOverview(id, wp) }
        }
    }

    // MARK: - Keyboard

    /// Dispatch the keyboard verbs both overviews share (Esc / Return /
    /// Space / Tab / `m`). Returns `true` if it consumed the key; the
    /// caller's monitor then handles the view-specific arrow nav (grid's
    /// 2-D `kbMoveSelection(dx:dy:)`, the rail's 1-D `(dx:)`). The
    /// PopupMenu-open guard stays in the monitor (it passes the event
    /// through rather than consuming it).
    func overviewCommonKey(_ keyCode: UInt16, shift: Bool,
                           on v: some OverviewView) -> Bool {
        switch keyCode {
        case 53:     v.kbEscape();                     return true   // Esc
        case 36, 76: v.kbCommit();                     return true   // Return
        case 49:     v.kbSpaceLift();                  return true   // Space
        case 48:     v.kbCycleWindow(forward: !shift); return true   // Tab
        case 46:     v.kbContextMenu();                return true   // 'm' (③)
        default:     return false
        }
    }
}
