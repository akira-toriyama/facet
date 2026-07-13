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

        // R12: was the tree PASSIVE when this click began? A mac-desktop switch
        // strips the panel's key (facet never auto-grabs it back — トミー), so
        // the tree commonly sits visible-but-passive. A plain click then WAKES
        // it into keyboard nav rather than acting on the row (handled at
        // leftMouseUp below). Captured up-front so an intervening enterActive
        // can't flip the decision mid-gesture.
        let wasPassive = !kbNav

        var mode = 0          // 0 undecided · 1 panel-move · 2 window-drag
        var dragWS = 0
        var dragGroup = 0     // section model: the dragged row's render-group ordinal
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
                    if sectionModeActive {
                        // Section model: a drop is an apply-based MOVE
                        // (un-apply source → apply dest). `wsBands` keys are
                        // render-group ordinals here (lastSections), NOT WS
                        // indices, so compare/route on `dragGroup`. The
                        // Controller resolves the apply via the live config +
                        // ApplyResolver and snaps back (runs no op) on an inert
                        // / non-satisfying drop — the row was never hidden.
                        // SAME-TYPE-ONLY (t-qtpx): the resolver accepts only
                        // ws→ws and lens→lens MOVEs; a ws↔lens crossing snaps
                        // back (do cross-axis edits via right-click / `t` / CLI).
                        // §G RESCUE is the one cross-type exception: an orphan
                        // row under the unassigned section is a valid drag SOURCE
                        // (its `dragGroup` is the unassigned ordinal, a real
                        // `wsBands` key), and dropping it on a WORKSPACE band runs
                        // that workspace's move → the orphan is rescued. Dropping
                        // ON unassigned is inert (no apply) → snap-back.
                        // An ISOLATE DESKTOP's section membership is match-driven
                        // (t-ec9s) — a window can't be hand-moved between the
                        // matched / holding sections, so the drop is inert (snap-
                        // back; the row was never hidden). Retarget via `--match`.
                        if !isolateDesktop, let tgt, tgt != dragGroup,
                           dragGroup < lastSections.count, tgt < lastSections.count {
                            controller?.applyMove(
                                windowID: dragWindowID,
                                fromSectionID: lastSections[dragGroup].id,
                                toSectionID: lastSections[tgt].id,
                                destSourceWorkspaceIndex: lastSections[tgt].sourceWorkspaceIndex)
                        }
                    } else if let tgt, tgt != dragWS {
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
                } else if mode == 4 {
                    // Section reorder commit (display-only, session-only): the
                    // insertion boundary is the top/bottom half of the band
                    // under the cursor. The Controller mutates the per-mac-
                    // desktop order override + re-renders all three views; a
                    // no-op drop commits nothing (`reorderSection` guards). A
                    // lens DESKTOP's 1–2 synthesized sections have a fixed order
                    // (matched then holding) — reordering is meaningless, so gate
                    // it (t-ec9s).
                    if !isolateDesktop,
                       let hit = wsBands.first(where: { $0.value.contains(cp.y) }),
                       dragGroup < lastSections.count {
                        let mid = (hit.value.lowerBound + hit.value.upperBound) / 2
                        let boundary = cp.y < mid ? hit.key : hit.key + 1
                        controller?.reorderSection(
                            move: lastSections[dragGroup].id, toBoundary: boundary)
                    }
                } else if mode == 0, wasPassive {
                    // R12 click-to-activate: a plain click on a PASSIVE tree
                    // (no drag) WAKES it into keyboard nav instead of acting on
                    // the row. This is the user-initiated recovery トミー asked
                    // for — facet never grabs key on a mac-desktop switch, but an
                    // explicit click does (works on every desktop, incl. after a
                    // round-trip through an unmanaged one). Land the kb cursor on
                    // the clicked row so nav continues from there; do NOT act —
                    // a SECOND click (now active) or Enter focuses the window,
                    // preserving #66 (the acting click drops key first, below).
                    controller?.enterActive()
                    switch row?.kind {
                    case .window(let g, _, _, let id, _)?: kbSel = .win(group: g, id)
                    case .header(let g, _)?:               kbSel = .hdr(group: g)
                    default:                                break
                    }
                    needsDisplay = true
                } else if let row, row.rect.contains(cp) {
                    // t-63h2: an isolate desktop's holding row is inert — bail
                    // BEFORE exitActive so an active-mode click doesn't drop
                    // keyboard nav for a no-op (see isHoldingRow).
                    if case .window(let g, _, _, _, _) = row.kind,
                       isHoldingRow(group: g) { break loop }
                    // #66 safety belt: drop key/active BEFORE acting on
                    // the row, mirroring the Enter path (kbActivate).
                    // Since the tree now opens active, a plain click
                    // lands while facet holds key — focusing a same-app
                    // window then fails unless facet relinquishes key
                    // first. No-op when already passive (exitActive
                    // guards on kbNav). prevApp here is the Controller's
                    // (set at show time), distinct from this view's drag
                    // prevApp, so there's no interference.
                    controller?.exitActive(restore: false)
                    handleClick(row)
                }
                break loop
            case .leftMouseDragged:
                if mode == 0,
                   hypot(cp.x - start.x, cp.y - start.y) >= pointerDragThreshold {
                    // ⌘+drag is always a panel-move. In the section model a
                    // window-row drag is an apply-based MOVE (PR8 —
                    // `applyMove`: un-apply source → apply dest); a section
                    // header still falls back to panel-move (header swap stays
                    // by-workspace-only). Retag-via-menu still works.
                    if ev.modifierFlags.contains(.command) {
                        mode = 1                       // ⌘ → panel-move
                    } else {
                        switch row?.kind {
                        case .none, .search?:
                            mode = 1                   // empty / search → move
                        case .window(let g, let ws, _, let wid, _)?:
                            // t-63h2: a holding row never becomes a drag
                            // source (display-only; see isHoldingRow).
                            // Not promoting keeps mode 0 — the eventual
                            // mouseUp lands on the inert-click guard above.
                            if isHoldingRow(group: g) { break }
                            mode = 2
                            dragWS = ws
                            dragGroup = g
                            dragWindowID = wid
                            // Store the SOURCE identity the drag affordance
                            // compares against `dropWS`: a render-group ordinal
                            // in section mode (wsBands is keyed by ordinal
                            // there), the real WS index in the by-workspace
                            // degrade (where group == ws.index anyway).
                            draggingWid = (sectionModeActive ? g : ws, wid)
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
                        case .header(let g, let wsi)?:
                            // Section model: a header grip-drag REORDERS the
                            // section list (display-only, session-only — the
                            // whole row lifts; the threshold above already
                            // separated this from a plain click that
                            // toggles/switches). Both workspace AND lens
                            // headers reorder. By-workspace degrade keeps Theme
                            // A header-swap (an isolate desktop header can't occur there).
                            // Panel move retreats to ⌘+drag / empty space.
                            if sectionModeActive {
                                mode = 4
                                dragGroup = g
                                // ⑨ richer ghost: lift the whole section
                                // (header + windows) as a snapshot card. NOTE:
                                // do NOT set `draggingWS` — that would paint a
                                // swap drop-band; reorder paints a line.
                                if !showDragCard(rect: dragRect(forGroup: g)) {
                                    showChip(reorderChipLabel(for: g))
                                }
                                lastDropWS = nil
                                reorderLineY = nil
                            } else if wsi != nil {
                                mode = 3
                                dragWS = g
                                draggingWS = g
                                if !showDragCard(rect: dragRect(forGroup: g)) {
                                    showChip(swapChipLabel(for: g))
                                }
                                lastDropWS = nil
                            } else {
                                mode = 1               // lens header (degrade) → move
                            }
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
                    // Section mode keys wsBands by render-group ordinal, so the
                    // cursor's "valid drop" test compares against the dragged
                    // row's GROUP ordinal; by-workspace / header-swap keep the
                    // WS index (group == ws.index there).
                    let dragSrc = sectionModeActive ? dragGroup : dragWS
                    if let t = dropWS, t != dragSrc {
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
                } else if mode == 4 {
                    // Section reorder: the insertion BOUNDARY is the top/bottom
                    // half of the band under the cursor (flipped y: top half →
                    // before that section, bottom half → after). A drop on the
                    // dragged section's own slot edge is a no-op (no line).
                    var lineY: CGFloat? = nil
                    if let hit = wsBands.first(where: { $0.value.contains(cp.y) }) {
                        let mid = (hit.value.lowerBound + hit.value.upperBound) / 2
                        let boundary = cp.y < mid ? hit.key : hit.key + 1
                        if boundary != dragGroup && boundary != dragGroup + 1 {
                            lineY = wsBands[boundary]?.lowerBound
                                ?? wsBands.values.map(\.upperBound).max()
                        }
                    }
                    NSCursor.closedHand.set()
                    if lineY == nil { NSCursor.arrow.set() }
                    moveDragGhost(to: cp)
                    tiltDragGhost(deltaX: ev.deltaX)
                    if lineY != reorderLineY { reorderLineY = lineY; needsDisplay = true }
                }
            default:
                break
            }
        }

        draggingWid = nil; draggingWS = nil; dropWS = nil; dragLabel = nil
        lastDropWS = nil; reorderLineY = nil
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
        // §D caption `index (label)`. Only reached in the by-workspace degrade
        // header-swap (mode 3), where the arg is `ws.index`. The display index
        // is that workspace's slot in the (reorder-applied) `lastWorkspaces`,
        // NOT `ws + 1` — matching the rendered caption + `--focus index:N`.
        guard let pos = lastWorkspaces.firstIndex(where: { $0.index == ws }) else {
            return sectionDisplayLabel(index: ws + 1, label: "")
        }
        return sectionDisplayLabel(index: pos + 1, label: lastWorkspaces[pos].name)
    }

    private func swapChipLabel(for ws: Int) -> String { "⇄ \(wsName(ws))" }

    /// Drag-ghost fallback chip for a section reorder (mode 4) — the section's
    /// friendly name (workspace emoji label or lens label) with a reorder
    /// glyph. Used only when the snapshot drag-card can't be built.
    private func reorderChipLabel(for g: Int) -> String {
        guard g < lastSections.count else { return "⇅" }
        // §D caption `index (label)` — index = tree position `g + 1`, same for
        // workspace + lens.
        return "⇅ \(sectionDisplayLabel(index: g + 1, label: lastSections[g].label))"
    }

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
            // A lens / unassigned header carries `workspaceIndex == nil` (no
            // workspace to switch to). Since the section-lens activate concept
            // was retired (t-ec9s), a `.matched` section (an isolate desktop's
            // match-synthesized section) and a `.unassigned` receptacle both
            // FOCUS THEIR FIRST window via the unified §G helper — no toggle, no
            // switch (membership is match-driven / by-subtraction, not manual).
            guard let i else {
                kbSel = .hdr(group: g)
                if sectionModeActive, g < lastSections.count {
                    let sec = lastSections[g]
                    switch sec.sectionType {
                    case .matched, .holding, .unassigned:
                        controller?.focusFirstWindow(inSectionID: sec.id)
                    case .workspace:  break   // workspace always has i != nil
                    }
                }
                return
            }
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
            // sel fill. The click already dropped kbNav (exitActive
            // ran before handleClick — #66 safety belt), so this just
            // pre-syncs the cursor for the next nav entry.
            kbSel = .hdr(group: g)
            // Header click = no explicit window pick (the backend's
            // `autoFocus: true` path uses the same `predictedFocus` helper as
            // fallback, so the window highlighted above is the one that ends up
            // focused, or Finder activated when the WS is empty). Route through
            // the Controller (NOT the backend directly) so every activation
            // funnels through the one validated seam. `i` is 0-based
            // (Workspace.index, matched at `$0.index == i` above);
            // ActiveSection.workspace is 1-based → `i + 1`.
            controller?.activateSection(.workspace(i + 1), autoFocus: true)
        case .window(let g, let i, let pid, let id, let title):
            // t-63h2 defensive twin of the mouseUp / kbActivate guards: a
            // holding row is inert whichever path reaches here.
            if isHoldingRow(group: g) { return }
            // Off main so the click never hitches; skip the switch
            // round-trip when the window is already on the active
            // workspace.
            let needSwitch = (i != activeWS)
            setOptimistic(windowID: id, workspaceIndex: i)
            // Keep the kb-nav cursor (drawn only while `kbNav` is
            // on) in sync with the click target, otherwise the
            // outline strands on the previous selection beside the
            // new sel fill. (The click dropped kbNav via exitActive —
            // see the header case above.)
            kbSel = .win(group: g, id)
            // A *hidden* row (Cmd+H'd / minimized window — hide-reclaim
            // pulled its tile slot, `isOnscreen == false`) is restored
            // on click: the backend un-hides / un-minimizes + focuses,
            // and the next reconcile re-tiles it. A normal row just
            // focuses. Memory: `facet-hide-reclaim-decisions`.
            let win0 = lastWorkspaces.first { $0.index == i }?
                .windows.first { $0.id == id }
            let hidden = win0?.isOnscreen == false
            let window = Window(id: id, pid: pid, appName: "",
                                title: title, isFocused: false,
                                isFloating: false, frame: nil)
            // An ISOLATE DESKTOP always tiles its matched set + anchor-parks the
            // rest by `match` (t-ec9s; the section-lens "clear to un-park"
            // gesture is gone). Clicking any window — parked or tiled — just
            // focuses it; the always-on park re-derives from `match` next
            // reconcile, so there is no per-window unpark to perform.
            let bk = backend
            let ctrl = controller
            cliQueue.async {
                if needSwitch {
                    // Switch to the clicked row's workspace. `autoFocus: false`
                    // because focusWindow below focuses the explicit target.
                    // `i` is 0-based (Workspace.index); switchWorkspace takes
                    // 0-based.
                    bk.switchWorkspace(toIndex: i, autoFocus: false)
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

    /// t-63h2 (2026-07-12 決定): an isolate desktop's HOLDING row is DISPLAY-ONLY —
    /// see `isHoldingSection` (FacetCore) for the contract and why the predicate
    /// is pure. The section TYPE carries it: `.holding` is minted only by
    /// `projectIsolateDesktop`, so no `isolateDesktop` flag is needed to
    /// discriminate — asking the section what it IS is the whole point of t-mqqw.
    func isHoldingRow(group g: Int) -> Bool {
        isHoldingSection(lastSections, group: g)
    }

}
