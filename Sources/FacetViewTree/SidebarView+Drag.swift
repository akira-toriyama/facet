// SidebarView pointer interaction — the mouseDown tracking loop
// (click vs panel-move handle vs window-row / header drag), the rich
// drag-card ghost (⑨), and the workspace-content swap commit. Same-module
// extension split out of SidebarView.swift (P8-2); stored state on primary.
import AppKit
import CoreGraphics
import FacetCore
import FacetView

extension SidebarView {
    // MARK: - Mouse: click vs drag-handle vs drag-window-row

    // A single explicit mouse-tracking loop. NSCursor changes during
    // a button-down drag are only honored from inside such a loop
    // (the normal mouseDragged path suppresses them) — this is what
    // finally makes the hand cursor appear.
    public override func mouseDown(with e: NSEvent) {
        let start = convert(e.locationInWindow, from: nil)
        guard let win = window else { return }
        let row = rows.first(where: { $0.rect.contains(start) })
        draggingWid = nil; dropWS = nil; dragLabel = nil

        // (Double-click-to-reset-geometry now lives on the pinned
        // HandleBar, not on a scrolling row.)

        var mode = 0          // 0 undecided · 1 panel-move · 2 window-drag
        var dragWS = 0
        var dragWindowID = WindowID(serverID: 0)
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        loop: while let ev = win.nextEvent(matching: mask) {
            let cp = convert(ev.locationInWindow, from: nil)
            switch ev.type {
            case .leftMouseUp:
                // mode 1 (panel move) needs nothing on mouseUp — the
                // move applied live during the drag and geometry is
                // session-only now (sticks via `[tree]` config, not
                // UserDefaults).
                if mode == 2 {
                    let tgt = wsBands.first { $0.value.contains(cp.y) }?.key
                    if let tgt, tgt != dragWS {
                        // M9-1: background move — file the window into
                        // the target WS without switching to it or
                        // focus-following. This matches the grid drop
                        // and the keyboard lift; the tree mouse drop
                        // was the lone exception. No setOptimistic (it
                        // would mislabel the active WS) — the reconcile
                        // relocates the row; prevApp is restored below
                        // so focus stays put.
                        let id = dragWindowID
                        let bk = backend
                        cliQueue.async {
                            bk.moveWindow(id, toWorkspaceIndex: tgt)
                        }
                        controller?.scheduleReconcile(after: 0.05)
                    }
                } else if mode == 3 {
                    let tgt = wsBands.first { $0.value.contains(cp.y) }?.key
                    if let tgt, tgt != dragWS {
                        performSwap(sourceWS: dragWS, targetWS: tgt)
                    }
                } else if let row, row.rect.contains(cp) {
                    handleClick(row)
                }
                break loop
            case .leftMouseDragged:
                if mode == 0,
                   hypot(cp.x - start.x, cp.y - start.y) >= pointerDragThreshold {
                    // ⌘+drag is always a panel-move; so is ANY drag in tag
                    // mode (the flat list has no workspace to drop onto) and
                    // in the section model (PR5 — apply-based DnD lands in
                    // PR8; until then a section-path drag must not move a
                    // window / swap a header). Retag / move is via the row
                    // context menu / CLI.
                    if ev.modifierFlags.contains(.command)
                        || tagModeActive || sectionModeActive {
                        mode = 1                       // ⌘ / tag / section → move
                    } else {
                        switch row?.kind {
                        case .none, .search?:
                            mode = 1                   // empty / search → move
                        case .window(_, let ws, _, let wid, _)?:
                            mode = 2
                            dragWS = ws
                            dragWindowID = wid
                            draggingWid = (ws, wid)
                            if let rr = row?.rect,
                               let c = cells.first(where: {
                                   $0.row == rr && $0.kind == 2
                               }) {
                                dragLabel = c.title.isEmpty
                                    ? c.app : "\(c.app)  \(c.title)"
                            }
                            // ⑨ richer ghost: lift the window's row as a
                            // snapshot card; fall back to the text chip.
                            if !showDragCard(rect: dragRect(forWindow: wid)) {
                                showChip(dragLabel ?? "")
                            }
                            lastDropWS = nil
                            prevApp = NSWorkspace.shared.frontmostApplication
                            NSApp.activate(ignoringOtherApps: true)
                        case .header(let g, .some)?:
                            // Theme A: header drag = swap this WS's
                            // contents with the drop-target WS. Panel
                            // move retreats to ⌘+drag / empty space. (Only
                            // reachable in the by-workspace path, where
                            // group == ws.index == the swap target.)
                            mode = 3
                            dragWS = g
                            draggingWS = g
                            // ⑨ richer ghost: lift the whole WS section
                            // (header + windows) as a snapshot card.
                            if !showDragCard(rect: dragRect(forGroup: g)) {
                                showChip(swapChipLabel(for: g))
                            }
                            lastDropWS = nil
                        case .header(_, .none)?:
                            mode = 1                   // lens header → move
                        }
                    }
                }
                if mode == 1 {
                    // Hand the panel move to the WINDOW SERVER via
                    // performDrag(with:) — the same machinery a native title
                    // bar uses. It tracks at compositor rate (perfect lockstep
                    // with the cursor, zero per-event main-thread work, no
                    // coalescing / pointer-acceleration drift) and translates
                    // the addChildWindow pet overlay for free. The
                    // .nonactivatingPanel style keeps kCGSPreventsActivation
                    // set, so this never steals focus / activates facet. It
                    // runs its OWN modal loop until mouseUp, so it only fits the
                    // pure-move path: modes 2/3 (window DnD / header swap) keep
                    // the manual loop below because they need per-event ghost /
                    // drop-band hooks. Threshold-gated — we only reach here once
                    // a real drag is confirmed, so plain clicks and the handle
                    // double-click (handled above) are untouched. On return the
                    // window has settled at its drop point; re-derive the
                    // persisted anchor + pet inset, then exit the loop (the
                    // mouseUp was consumed by performDrag).
                    win.performDrag(with: ev)
                    controller?.syncPanelAfterDrag()
                    break loop
                } else if mode == 2 || mode == 3 {
                    dropWS = wsBands.first { $0.value.contains(cp.y) }?.key
                    if let t = dropWS, t != dragWS {
                        NSCursor.closedHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                    // Move just the ghost (cheap → keeps up at speed) +
                    // lean it toward the drag direction (⑨).
                    moveDragGhost(to: cp)
                    tiltDragGhost(deltaX: ev.deltaX)
                    // Full redraw only when the drop band changes.
                    if dropWS != lastDropWS {
                        lastDropWS = dropWS
                        needsDisplay = true
                    }
                }
            default:
                break
            }
        }

        draggingWid = nil; draggingWS = nil; dropWS = nil; dragLabel = nil
        lastDropWS = nil
        hideDragGhosts()
        NSCursor.arrow.set()
        // Restore the previously-frontmost app. A tree drag activates
        // facet only so the drag cursor shows (see mouseDown top); the
        // M9-1 drop is a background move that never takes focus, so
        // focus always returns to whoever was frontmost.
        if let prev = prevApp {
            prev.activate()
            prevApp = nil
        }
        needsDisplay = true
    }

    private func showChip(_ label: String) {
        chip.stringValue = label
        chip.font = uiFont(windowFontSize, .semibold)
        chip.textColor = pal.background ?? .white
        chip.layer?.backgroundColor = pal.primary.cgColor
        chip.sizeToFit()
        let w = min(chip.frame.width + 20, bounds.width - 16)
        chip.frame = NSRect(x: chip.frame.minX, y: chip.frame.minY,
                            width: w, height: 22)
        chip.isHidden = false
    }

    // MARK: - Drag card (⑨ — snapshot the lifted rows)

    /// Union rect of a render group's header + window rows (header-swap
    /// drag card — by-workspace path only, where group == ws.index).
    private func dragRect(forGroup g: Int) -> NSRect? {
        var r: NSRect?
        for row in rows {
            let hit: Bool
            switch row.kind {
            case .header(let rg, _):          hit = (rg == g)
            case .window(let rg, _, _, _, _): hit = (rg == g)
            default:                          hit = false
            }
            if hit { r = r.map { $0.union(row.rect) } ?? row.rect }
        }
        return r
    }

    /// A single window row's rect.
    private func dragRect(forWindow id: WindowID) -> NSRect? {
        rows.first {
            if case .window(_, _, _, let wid, _) = $0.kind { return wid == id }
            return false
        }?.rect
    }

    /// Show the snapshot card for `rect` (capped to ~60% panel height so a
    /// tall WS shows its top) in the floating window. Returns false → the
    /// caller falls back to the in-panel chip.
    @discardableResult
    private func showDragCard(rect: NSRect?) -> Bool {
        guard var r = rect?.intersection(bounds), r.width > 1, r.height > 1
        else { return false }
        let maxH = max(40, bounds.height * 0.6)
        if r.height > maxH { r.size.height = maxH }   // top portion only
        guard let img = snapshotRegion(r) else { return false }
        dragCard.image = img
        dragCard.frame = NSRect(x: dragCardPad, y: dragCardPad,
                                width: r.width, height: r.height)
        dragCard.layer?.borderColor = pal.primary.withAlphaComponent(0.9).cgColor
        dragCard.layer?.backgroundColor = (pal.background ?? NSColor(white: 0.10, alpha: 1)).cgColor
        dragCardWindow.setContentSize(NSSize(width: r.width + dragCardPad * 2,
                                             height: r.height + dragCardPad * 2))
        // Semi-transparent (dnd-kit style) so the drop-target band shows
        // through the lifted card — the drop is easier to predict (⑨).
        dragCardWindow.alphaValue = dragGhostAlpha
        positionDragCardWindow()
        dragCardWindow.orderFront(nil)
        chip.isHidden = true
        cardShown = true
        return true
    }

    /// Place the card window just below-right of the live cursor (screen
    /// coords); the card itself is inset by `dragCardPad`.
    private func positionDragCardWindow() {
        let m = NSEvent.mouseLocation               // screen, y-up
        dragCardWindow.setFrameTopLeftPoint(
            NSPoint(x: m.x + 14 - dragCardPad, y: m.y - 12 + dragCardPad))
    }

    /// Move the visible drag ghost to follow the cursor — the floating
    /// card window (screen coords) or, as fallback, the in-panel chip.
    private func moveDragGhost(to cp: NSPoint) {
        if cardShown { positionDragCardWindow(); return }
        chip.setFrameOrigin(NSPoint(
            x: min(max(cp.x + 14, 4), bounds.width - chip.frame.width - 4),
            y: max(4, cp.y - 12)))
    }

    /// Lean the lifted card toward the drag direction (⑨) — like a card
    /// dangling from the cursor. Driven by each move's horizontal delta;
    /// eases toward 0 when the motion is vertical / stops. (`dragTilt`
    /// stored state lives on the primary declaration — extensions can't
    /// hold stored properties.)
    private func tiltDragGhost(deltaX: CGFloat) {
        let target = max(-dragTiltMax, min(dragTiltMax, deltaX * dragTiltPerPx))
        dragTilt += (target - dragTilt) * 0.4          // smooth
        let layer = cardShown ? dragCard.layer : chip.layer
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.transform = CATransform3DMakeRotation(dragTilt, 0, 0, 1)
        CATransaction.commit()
    }

    private func hideDragGhosts() {
        chip.isHidden = true
        dragCardWindow.orderOut(nil)
        dragCard.image = nil
        cardShown = false
        // Reset the lean.
        dragTilt = 0
        dragCard.layer?.transform = CATransform3DIdentity
        chip.layer?.transform = CATransform3DIdentity
    }

    // MARK: - Workspace-content swap (header drag / kb header lift)

    private func wsName(_ ws: Int) -> String {
        let w = lastWorkspaces.first { $0.index == ws }
        return (w?.name.isEmpty == false) ? w!.name : "WS\(ws + 1)"
    }

    private func swapChipLabel(for ws: Int) -> String { "⇄ \(wsName(ws))" }

    func wsOf(windowID id: WindowID) -> Int? {
        lastWorkspaces.first { $0.windows.contains { $0.id == id } }?.index
    }

    /// Swap the entire window membership of two workspaces. The WS
    /// indices never change (hotkey mapping preserved) — only the
    /// windows inside trade places. IDs are captured up-front so the
    /// two halves don't interfere mid-flight; N+M `moveWindow` calls
    /// run on the serial backend queue, then a reconcile reflects the
    /// result. Active WS / focus are intentionally left unchanged
    /// (Theme A).
    func performSwap(sourceWS: Int, targetWS: Int) {
        guard sourceWS != targetWS else { return }
        let srcIDs = lastWorkspaces.first { $0.index == sourceWS }?
            .windows.map(\.id) ?? []
        let dstIDs = lastWorkspaces.first { $0.index == targetWS }?
            .windows.map(\.id) ?? []
        guard !(srcIDs.isEmpty && dstIDs.isEmpty) else { return }
        let bk = backend
        cliQueue.async {
            for id in srcIDs { bk.moveWindow(id, toWorkspaceIndex: targetWS) }
            for id in dstIDs { bk.moveWindow(id, toWorkspaceIndex: sourceWS) }
        }
        controller?.scheduleReconcile(after: 0.05)
    }

    func handleClick(_ row: TreeRow) {
        switch row.kind {
        case .search:
            break
        case .header(let g, let i):
            // Tag-world header (tag mode): one tag-world, nothing to switch
            // to — the layout picker is on right-click / `m`. Plain click /
            // Enter is a no-op (no spurious WS switch on the synthetic WS).
            if tagModeActive { return }
            // Lens-section header (section model): no workspace to switch to.
            // PR6 will activate the lens on click; for now sync the cursor
            // and no-op.
            guard let i else { kbSel = .hdr(group: g); return }
            // Move highlight to that workspace immediately: its
            // last-focused window, else its lowest window id (empty
            // → none). Without this the old workspace's window
            // stays selected until the next backend query, then
            // jumps.
            let tgt = lastWorkspaces.first { $0.index == i }
            let pred = tgt?.windows.predictedFocus()?.id
                ?? WindowID(serverID: -1)
            setOptimistic(windowID: pred, workspaceIndex: i)
            // Carry the kb-nav cursor with the click so the
            // outline (drawn only while `kbNav` is on) doesn't
            // strand on the previously selected row beside the new
            // sel fill. A plain click does NOT turn kbNav on (since
            // #66 the panel takes key only via --active / the
            // Desktop-header menu); this just pre-syncs the cursor.
            kbSel = .hdr(group: g)
            let bk = backend
            // Header click = no explicit window pick. The backend's
            // `autoFocus: true` path uses the same `predictedFocus`
            // helper as fallback, so the window highlighted above
            // is the same one that ends up focused (or Finder
            // activated when the WS is empty).
            cliQueue.async {
                bk.switchWorkspace(toIndex: i, autoFocus: true)
            }
        case .window(let g, let i, let pid, let id, let title):
            // Off main so the click never hitches; skip the switch
            // round-trip when the window is already on the active
            // workspace.
            let needSwitch = (i != activeWS)
            setOptimistic(windowID: id, workspaceIndex: i)
            // Keep the kb-nav cursor (drawn only while `kbNav` is
            // on) in sync with the click target, otherwise the
            // outline strands on the previous selection beside the
            // new sel fill. (A plain click doesn't enable kbNav —
            // see the header case above.)
            kbSel = .win(group: g, id)
            // A *hidden* row (Cmd+H'd / minimized window — hide-reclaim
            // pulled its tile slot, `isOnscreen == false`) is restored
            // on click: the backend un-hides / un-minimizes + focuses,
            // and the next reconcile re-tiles it. A normal row just
            // focuses. Memory: `facet-hide-reclaim-decisions`.
            let hidden = lastWorkspaces.first { $0.index == i }?
                .windows.first { $0.id == id }?.isOnscreen == false
            let window = Window(id: id, pid: pid, appName: "",
                                title: title, isFocused: false,
                                isFloating: false, frame: nil)
            let bk = backend
            let ctrl = controller
            cliQueue.async {
                if needSwitch {
                    bk.switchWorkspace(toIndex: i)
                }
                if hidden {
                    bk.revealWindow(id)
                } else {
                    Task { @MainActor in
                        ctrl?.focusWindow(window, postSwitch: needSwitch)
                    }
                }
            }
        }
    }

}
