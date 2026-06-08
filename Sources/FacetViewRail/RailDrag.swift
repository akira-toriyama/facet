// Drag ghosts + commit/cancel for the rail's window-move and
// workspace-swap gestures. Module-local copies of the grid's
// installDragGhost / installWorkspaceGhost / commitDrop /
// commitContentSwap / cancelDrop machinery, minus the FLIP reorder
// tweens (the rail just lets the backend re-place windows). State
// lives on RailView; these are the behaviour.

import AppKit
import CoreGraphics
import FacetCore
import FacetView

extension RailView {

    // MARK: - Ghosts

    /// Thumb-sized accent ghost for a window drag — installed already
    /// at lifted size so cursor-follow starts on frame 1; only the
    /// shadow fades in.
    func installDragGhost(for hit: MiniWindowHit) {
        let lifted = NSRect(
            x: hit.rect.midX - (hit.rect.width  * railLiftScale) / 2,
            y: hit.rect.midY - (hit.rect.height * railLiftScale) / 2,
            width:  hit.rect.width  * railLiftScale,
            height: hit.rect.height * railLiftScale)
        let g = NSView(frame: lifted)
        g.wantsLayer = true
        g.layer?.cornerRadius = 4
        g.layer?.cornerCurve = .continuous
        g.layer?.masksToBounds = true
        g.layer?.borderColor = pal.accent.cgColor
        g.layer?.borderWidth = 1.5
        g.layer?.shadowColor = NSColor.black.cgColor
        g.layer?.shadowOffset = CGSize(width: 0, height: -4)
        g.layer?.shadowRadius = railLiftShadowRadius
        g.layer?.shadowOpacity = 0
        if let img = thumbnails[hit.id] {
            g.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
            let iv = NSImageView(frame: g.bounds)
            iv.image = img
            iv.imageScaling = .scaleAxesIndependently
            iv.autoresizingMask = [.width, .height]
            g.addSubview(iv)
        } else {
            // No app-icon fallback (rail shows captures only); a not-yet-
            // captured window lifts as a plain accent tile.
            g.layer?.backgroundColor = pal.accent.withAlphaComponent(0.45).cgColor
        }
        addSubview(g)
        dragGhost = g
        liftShadow(g)
    }

    /// Cell-sized ghost for a workspace swap — reproduces the source
    /// cell's mini-thumbnails so it reads as "the whole cell floating."
    func installWorkspaceGhost(for cell: Cell) {
        let g = FlippedView(frame: cell.rect)
        g.wantsLayer = true
        g.layer?.cornerRadius = railCellRadius
        g.layer?.cornerCurve = .continuous
        g.layer?.masksToBounds = true
        g.layer?.borderColor = pal.text.withAlphaComponent(0.85).cgColor
        g.layer?.borderWidth = 2
        g.layer?.backgroundColor = pal.text.withAlphaComponent(0.10).cgColor
        g.layer?.shadowColor = NSColor.black.cgColor
        g.layer?.shadowOffset = CGSize(width: 0, height: -4)
        g.layer?.shadowRadius = railLiftShadowRadius
        g.layer?.shadowOpacity = 0
        if cell.wins.isEmpty {
            let label = NSTextField(labelWithString: railLabel(cell.name, cell.wsIndex))
            label.font = uiFont(railGhostLabelSize, .bold)
            label.textColor = pal.text.withAlphaComponent(0.95)
            label.alignment = .center
            label.sizeToFit()
            label.frame = NSRect(
                x: (g.bounds.width  - label.frame.width)  / 2,
                y: (g.bounds.height - label.frame.height) / 2,
                width: label.frame.width, height: label.frame.height)
            label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            g.addSubview(label)
        } else {
            for hit in cell.wins {
                let local = NSRect(x: hit.rect.minX - cell.rect.minX,
                                   y: hit.rect.minY - cell.rect.minY,
                                   width: hit.rect.width, height: hit.rect.height)
                let iv = NSImageView(frame: local)
                iv.wantsLayer = true
                iv.layer?.cornerRadius = 3
                iv.layer?.masksToBounds = true
                if let img = thumbnails[hit.id] {
                    iv.image = img
                    iv.imageScaling = .scaleAxesIndependently
                } else {
                    iv.layer?.backgroundColor = pal.text.withAlphaComponent(0.22).cgColor
                }
                g.addSubview(iv)
            }
        }
        addSubview(g)
        dragGhost = g
        liftShadow(g)
    }

    private func liftShadow(_ g: NSView) {
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = 0
        fade.toValue = railLiftShadowOpacity
        fade.duration = railLiftDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.layer?.shadowOpacity = railLiftShadowOpacity
        g.layer?.add(fade, forKey: "shadow-lift")
    }

    func positionDragGhost(at p: NSPoint) {
        guard let g = dragGhost else { return }
        g.frame.origin = NSPoint(x: p.x - g.frame.width / 2,
                                 y: p.y - g.frame.height / 2)
    }

    // MARK: - Commit / cancel

    func commitDrop(sourceWS: Int, pid: Int, id: WindowID, dstCell: Cell) {
        // Ghost stays at the release point as a placeholder; `drag`
        // stays set (source thumb hidden) until the backend acks the
        // move and `layoutCells`'s landing gate clears it.
        lastDrop = PendingDrop(id: id, dstWS: dstCell.wsIndex, committedAt: Date())
        onMoveWindow?(sourceWS, dstCell.wsIndex, pid, id)
        scheduleAckDeadline()
    }

    func commitContentSwap(sourceWS: Int, srcIDs: [WindowID], dstCell: Cell) {
        // Source the swap's window set from the LIVE workspace, not the
        // render-filtered cell thumbs (frameless / sub-2pt windows have
        // no thumb but must still move).
        let dstIDs = workspaces.first(where: { $0.index == dstCell.wsIndex })?
            .windows.map(\.id) ?? dstCell.wins.map(\.id)
        if srcIDs.isEmpty && dstIDs.isEmpty {
            cancelDrop(to: drag?.sourceRect ?? .zero)    // both empty → no-op
            return
        }
        lastSwap = PendingSwap(srcWS: sourceWS, dstWS: dstCell.wsIndex,
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.railDropAckTimeout) {
            [weak self] in self?.layoutCells()
        }
    }

    func cancelDrop(to sourceRect: NSRect) {
        // Re-lay after the cancel so the hero re-syncs with `selectedWS`
        // — a KEYBOARD aim advances selectedWS while lifted, so on cancel
        // the frozen hero would otherwise be stale (mouse cancels leave
        // selectedWS untouched, so this is a cheap no-op for them).
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
        needsDisplay = true
    }
}
