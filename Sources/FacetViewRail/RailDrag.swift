// Drag ghosts + commit/cancel for the rail's window-move and
// workspace-swap gestures. Ghost construction is the shared FacetView
// helper (DragGhost.swift), fed the rail's tunables; the commit /
// cancel lifecycle stays module-local — the rail has no FLIP reorder
// tweens (it just lets the backend re-place windows) and instead
// carries the ack-deadline poll the grid lacks. State lives on
// RailView; these are the behaviour.

import AppKit
import CoreGraphics
import FacetCore
import FacetView

extension RailView {

    // MARK: - Ghosts

    // Construction is the shared FacetView helper (DragGhost.swift),
    // fed the rail's tunables (`railGhostStyle`). The rail passes no
    // app-icon fallback (it shows captures only) — a not-yet-captured
    // window lifts as a plain accent tile / placeholder fill.

    func installDragGhost(for hit: MiniWindowHit) {
        let g = makeWindowGhost(over: hit.rect,
                                thumbnail: thumbnails[hit.id],
                                iconFallback: { nil },
                                style: railGhostStyle,
                                pal: pal)        // PR-B: rail's per-view palette
        addSubview(g)
        dragGhost = g
        liftShadow(g, style: railGhostStyle)
    }

    func installWorkspaceGhost(for cell: OverviewCell) {
        let thumbs = cell.windows.map { hit -> MiniThumbSpec in
            let local = NSRect(x: hit.rect.minX - cell.rect.minX,
                               y: hit.rect.minY - cell.rect.minY,
                               width: hit.rect.width, height: hit.rect.height)
            let content = thumbnails[hit.id]
                .map { MiniThumbContent.capture($0) } ?? .placeholder
            return MiniThumbSpec(rect: local, content: content)
        }
        let g = makeWorkspaceGhost(cellRect: cell.rect,
                                   label: cell.label,
                                   thumbs: thumbs,
                                   style: railGhostStyle,
                                   pal: pal)     // PR-B: rail's per-view palette
        addSubview(g)
        dragGhost = g
        liftShadow(g, style: railGhostStyle)
    }

    func positionDragGhost(at p: NSPoint) {
        positionGhost(dragGhost, at: p)
    }

    // MARK: - Commit / cancel

    func commitDrop(sourceWS: Int, pid: Int, id: WindowID, dstCell: OverviewCell) {
        // Ghost stays at the release point as a placeholder; `drag`
        // stays set (source thumb hidden) until the backend acks the
        // move and `layoutCells`'s landing gate clears it.
        lastDrop = OverviewPendingDrop(id: id, dstWS: dstCell.wsIndex, committedAt: Date())
        onMoveWindow?(sourceWS, dstCell.wsIndex, pid, id)
        scheduleAckDeadline()
    }

    func commitContentSwap(sourceWS: Int, srcIDs: [WindowID], dstCell: OverviewCell) {
        // Source the swap's window set from the LIVE workspace, not the
        // render-filtered cell thumbs (frameless / sub-2pt windows have
        // no thumb but must still move).
        let dstIDs = workspaces.first(where: { $0.index == dstCell.wsIndex })?
            .windows.map(\.id) ?? dstCell.windows.map(\.id)
        if srcIDs.isEmpty && dstIDs.isEmpty {
            cancelDrop(to: drag?.sourceRect ?? .zero)    // both empty → no-op
            return
        }
        lastSwap = OverviewPendingSwap(srcWS: sourceWS, dstWS: dstCell.wsIndex,
                               srcIDs: srcIDs, dstIDs: dstIDs, committedAt: Date())
        onSwap?(sourceWS, dstCell.wsIndex, srcIDs, dstIDs)
        scheduleAckDeadline()
    }

    /// The landing gate's timeout is only evaluated when `layoutCells`
    /// runs; a silent backend no-op otherwise leaves the gesture frozen
    /// until the next reconcile (~poll interval). Fire one `layoutCells`
    /// at the deadline so the timeout is honoured. Harmless if the gate
    /// already cleared (no pending drop → a plain relayout).
    private func scheduleAckDeadline() {
        DispatchQueue.main.asyncAfter(deadline: .now() + overviewDropAckTimeout) {
            [weak self] in self?.layoutCells()
        }
    }

    func cancelDrop(to sourceRect: NSRect) {
        // Re-lay after the cancel so the hero re-syncs with `selectedSectionID`
        // — a KEYBOARD aim advances selectedSectionID while lifted, so on
        // cancel the frozen hero would otherwise be stale (mouse cancels leave
        // selectedSectionID untouched, so this is a cheap no-op for them).
        guard let g = dragGhost else { clearDrag(); layoutCells(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            g.animator().frame = sourceRect
            g.animator().alphaValue = 0
        }) { [weak self] in self?.clearDrag(); self?.layoutCells() }
    }

    /// Tear the gesture down: remove the ghost, drop all drag state,
    /// release the layout freeze. The cancel path, the landing gate,
    /// and the Controller's `hideRail` teardown all end here.
    public func clearDrag() {
        dragGhost?.removeFromSuperview()
        dragGhost = nil
        drag = nil
        lastDrop = nil
        lastSwap = nil
        layoutSuppressed = false
        reorderDrag = false
        dragSectionID = nil
        reorderInsertAt = nil
        reorderLine = nil
        needsDisplay = true
    }
}
