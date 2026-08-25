// Wiring shared by the two overview surfaces — the full-screen grid
// (`Controller+Grid`) and the workspace rail (`Controller+Rail`): the
// move / swap backend round-trips and the thumbnail capture feeds. Both
// surfaces are SwiftUI VMs now, so what remains here is exactly the part
// with no per-surface shape. Same-module extension — stored state lives
// on the primary `Controller` declaration.

import AppKit
import FacetCore
import FacetAccessibility
import FacetView

extension Controller {

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

    /// Snapshot-on-show capture kick-off: request every window in every
    /// workspace once. Cells paint app icons / placeholders first and
    /// swap to real thumbnails as captures land. Feeds whichever
    /// overview is on screen (the other ref is `nil` → skipped); grid
    /// and rail are mutually exclusive, so this matches feeding the one
    /// shown — same shape as `pushFreshThumbnails`.
    func startOverviewCaptures() {
        let wp = winPreview
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
        guard gridVM != nil || railVM != nil else { return }
        let wp = winPreview
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
}
