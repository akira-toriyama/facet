// SidebarView keyboard control (tree keyboard nav) — selection nav over the
// row ladder and keyboard drag-and-drop (Space lift, arrow aim, Return
// commit, Esc cancel). Thin wrappers over the pure index helpers in
// KbNav.swift. Same-module extension split out of SidebarView.swift (P8-2).
import AppKit
import CoreGraphics
import FacetCore
import FacetView

extension SidebarView {
    // MARK: - Keyboard navigation (tree keyboard nav)

    // Selection is tracked by logical identity (window id / empty-WS
    // index), never array position, so it survives the 2 s refresh
    // and backend events.

    // Thin wrappers around the free, testable kb-nav functions.
    private func kbSelectable() -> [Int] {
        kbSelectableIndices(rows: rows)
    }
    private func kbKey(at i: Int) -> TreeKbSel? {
        kbKeyAt(i, in: rows)
    }
    func kbIndex(of sel: TreeKbSel) -> Int? {
        kbIndexOf(sel, in: rows)
    }

    /// Focused window, else the first selectable row.
    func kbDefault() -> TreeKbSel? {
        if let i = cells.firstIndex(where: { $0.kind == 2 && $0.hot }),
           let k = kbKey(at: i) { return k }
        return kbSelectable().first.flatMap(kbKey(at:))
    }

    /// Re-anchor across a rebuild: keep the same logical selection
    /// if it still exists; only fall back when it's truly gone.
    func resolveSel() {
        if let s = kbSel, kbIndex(of: s) != nil { return }
        kbSel = kbDefault()
    }

    private func selRect() -> NSRect? {
        guard let s = kbSel, let i = kbIndex(of: s) else { return nil }
        return rows[i].rect
    }

    func scrollSelVisible() {
        guard let r = selRect() else { return }
        scrollToVisible(r.insetBy(dx: 0, dy: -windowRowH))
    }

    private func setSel(_ s: TreeKbSel?) {
        kbSel = s
        // Keyboard nav takes the preview back from hover (and clears the
        // stale hover highlight). previewTargets() prefers hoverIdx, so
        // without this an arrow key wouldn't move the preview while the
        // mouse rests on a row. Next mouseMoved re-sets hoverIdx.
        hoverIdx = nil
        needsDisplay = true
        if s != nil { scrollSelVisible() }
        controller?.previewTargetChanged()
    }

    public func enterKbNav() {
        kbNav = true
        if kbSel == nil { kbSel = kbDefault() }
        needsDisplay = true
        scrollSelVisible()
        controller?.previewTargetChanged()
    }

    public func exitKbNav() {
        kbNav = false
        kbSel = nil
        kbLifted = nil; kbDropWS = nil
        searching = false           // restore headers / normal list next show
        query = ""
        signature = ""
        needsDisplay = true
        controller?.previewTargetChanged()
    }

    public func kbMove(_ d: Int) {
        if kbLifted != nil { kbAim(d); return }
        let ids = kbSelectable()
        let cur = kbSel.flatMap(kbIndex(of:))
        if let new = kbMoveTarget(selectable: ids, current: cur, delta: d) {
            setSel(kbKey(at: new))
        }
    }

    /// Jump to the prev/next workspace: its first window, or its
    /// header when that workspace is empty.
    public func kbJumpWS(_ dir: Int) {
        if kbLifted != nil { kbAim(dir); return }
        let curWS: Int? = {
            guard let s = kbSel, let i = kbIndex(of: s) else { return nil }
            switch rows[i].kind {
            case .header(let g, _):          return g
            case .window(let g, _, _, _, _): return g
            default:                         return nil
            }
        }()
        if let t = kbJumpTarget(rows: rows, fromWS: curWS, dir: dir) {
            setSel(t)
        }
    }

    // MARK: - Keyboard DnD (lift / aim / commit)

    private func liftSourceWS() -> Int? {
        switch kbLifted {
        case .win(let g, let id):
            // Section model: the drop target walks render-group ordinals
            // (`kbWsOrder` / `wsBands`), so the lift SOURCE must be the lifted
            // row's GROUP ordinal too — NOT its real WS index (`wsOf`), a
            // different namespace. By-workspace keeps `wsOf` (group == ws.index).
            return sectionModeActive ? g : wsOf(windowID: id)
        case .hdr(let g): return g
        case .none:       return nil
        }
    }

    /// Space: pick up the selected row (window = move, header =
    /// WS-swap). A second Space — or Return — commits; Esc cancels.
    /// While lifted, the arrow keys (via `kbMove` / `kbJumpWS`) walk
    /// the drop target through the workspace order instead of moving
    /// the selection.
    public func kbToggleLift() {
        // The section model supports lift (PR8): a window-row lift commits an
        // apply-based MOVE; a header lift no-ops (header swap stays
        // by-workspace-only).
        if kbLifted == nil {
            guard let s = kbSel else { return }
            kbLifted = s
            kbDropWS = liftSourceWS()
            needsDisplay = true
        } else {
            kbCommitLift()
        }
    }

    /// Step the drop target to the prev/next workspace.
    private func kbAim(_ delta: Int) {
        guard kbLifted != nil else { return }
        let order = kbWsOrder(rows: rows)
        guard !order.isEmpty else { return }
        let cur = kbDropWS ?? liftSourceWS() ?? order[0]
        let pos = order.firstIndex(of: cur) ?? 0
        let step = delta > 0 ? 1 : -1
        kbDropWS = order[min(max(pos + step, 0), order.count - 1)]
        if let t = kbDropWS, let band = wsBands[t] {
            scrollToVisible(NSRect(x: 0, y: band.lowerBound,
                                   width: bounds.width,
                                   height: band.upperBound - band.lowerBound))
        }
        needsDisplay = true
    }

    /// Esc while lifting: drop the lift without moving anything.
    /// Returns true if a lift was in progress (so the caller doesn't
    /// also exit keyboard mode).
    @discardableResult
    public func kbCancelLift() -> Bool {
        guard kbLifted != nil else { return false }
        kbLifted = nil; kbDropWS = nil
        needsDisplay = true
        return true
    }

    /// Commit the lift: a window moves to the target WS (a background
    /// move — no switch, no focus-follow — same as the mouse drop
    /// since M9-1); a header swaps its WS's contents with the target.
    /// Returns true if a lift was in progress.
    @discardableResult
    public func kbCommitLift() -> Bool {
        guard let s = kbLifted else { return false }
        let tgt = kbDropWS
        kbLifted = nil; kbDropWS = nil
        needsDisplay = true
        guard let tgt else { return true }
        switch s {
        case .win(let g, let id):
            if sectionModeActive {
                // Section model: commit = apply-based MOVE. `tgt` and `g` are
                // render-group ordinals (kbWsOrder / liftSourceWS, same
                // namespace). The Controller resolves the apply and snaps back
                // (runs no op) on an inert / non-satisfying drop.
                guard tgt != g, g < lastSections.count, tgt < lastSections.count
                else { return true }
                controller?.applyMove(
                    windowID: id,
                    fromSectionID: lastSections[g].id,
                    toSectionID: lastSections[tgt].id,
                    destSourceWorkspaceIndex: lastSections[tgt].sourceWorkspaceIndex)
                kbSel = .win(group: g, id)
            } else {
                // Move-only background move (same model as the mouse drop
                // since M9-1): "file" the window into the target WS and
                // stay put — no switch, so don't claim tgt is active (no
                // setOptimistic, which would mislabel the active WS). The
                // reconcile relocates the row; kbSel follows it.
                guard let src = wsOf(windowID: id), src != tgt else { return true }
                let bk = backend
                cliQueue.async {
                    bk.moveWindow(id, toWorkspaceIndex: tgt)
                }
                kbSel = .win(group: g, id)
                controller?.scheduleReconcile(after: 0.05)
            }
        case .hdr(let g):
            // Section model: a workspace-section header swap is not supported
            // (parity with the mouse path) — a header lift-commit no-ops.
            if sectionModeActive { return true }
            guard g != tgt else { return true }
            performSwap(sourceWS: g, targetWS: tgt)
        }
        return true
    }

    /// `m` in keyboard nav: open the selected row's context menu — the
    /// same menu right-click shows (window actions / workspace layout).
    /// Anchored OUTSIDE the tree, just past the panel's right edge
    /// (`f.maxX + 8`, the same placement as the `t` tag-manage panel)
    /// and level with the selected row's top — so the menu sits *beside*
    /// the target window instead of covering it (dropping it inside the
    /// tree hid the very row the user is acting on). (Space is the lift
    /// gesture in Theme A.) facet stays in keyboard nav; pick with the mouse or
    /// Esc.
    public func kbContextMenu() {
        guard let s = kbSel, let i = kbIndex(of: s),
              let win = window else { return }
        let r = rows[i].rect
        let rowTop = win.convertPoint(toScreen:
            convert(NSPoint(x: r.minX, y: r.minY), to: nil))
        let scr = NSPoint(x: win.frame.maxX + 8, y: rowTop.y)
        // Keyboard path → type-to-filter menu (the tree panel keeps key, so
        // PopupMenu's key monitor receives the typed query).
        switch rows[i].kind {
        case .header(let g, let ws):
            // Workspace header → full layout picker; lens header → the
            // stateless-only union layout picker (R9 / Cluster B).
            if let ws { headerMenu(at: scr, workspaceIndex: ws, filterable: true) }
            else { lensHeaderMenu(at: scr, group: g, filterable: true) }
        case .window(let g, let ws, let pid, let id, let title):
            showWindowMenu(at: scr, workspaceIndex: ws,
                           pid: pid, windowID: id, title: title,
                           filterable: true, currentGroup: g)
        default:
            break
        }
    }

    /// Enter: act on the selected row exactly like a click, then
    /// leave keyboard mode (focus follows via assertFocus, so we
    /// don't restore the previously-frontmost app here).
    public func kbActivate() {
        guard let s = kbSel, let i = kbIndex(of: s) else { return }
        let row = rows[i]
        // Leave keyboard mode FIRST so we act exactly like a mouse
        // click (facet no longer the active app). Otherwise,
        // switching to an empty workspace then dropping .regular
        // lets the prior app re-activate and yank the WM back.
        controller?.exitActive(restore: false)
        handleClick(row)
    }

}
