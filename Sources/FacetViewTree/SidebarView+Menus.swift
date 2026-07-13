// SidebarView right-click menus — the workspace-header layout / tag
// picker and the per-window ops menu (shared PopupMenu). Same-module
// extension split out of SidebarView.swift (P8-2); stored state on primary.
import AppKit
import CoreGraphics
import FacetCore
import FacetView

extension SidebarView {
    // MARK: - Right-click menus

    // Right-click: WS header → pick layout engine; window row →
    // window actions.
    public override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let row = rows.first(where: { $0.rect.contains(p) }),
              let win = window else { return }
        let scr = win.convertPoint(toScreen: e.locationInWindow)
        switch row.kind {
        case .header(let g, let ws):
            // Workspace header → full layout picker. A no-workspace header is one
            // of an isolate desktop's two sections: matched (Rename + Edit match)
            // or holding (nothing). Discriminate at the CALL SITE so a menu
            // builder's own guard can't fail silently on the wrong kind — which is
            // exactly what `.holding` did until t-63h2's guard was repaired.
            if let ws { headerMenu(at: scr, group: g, workspaceIndex: ws) }
            else if g >= 0, g < lastSections.count {
                switch lastSections[g].sectionType {
                case .matched:    isolateHeaderMenu(at: scr, group: g)
                // t-63h2: the holding section is display-only. It is synthesized
                // by subtraction from the `match`, so it has no label to rename
                // (`FilterProjection` mints `""`) and no layout of its own —
                // there is no menu item that would mean anything. Deliberately
                // no menu, not an oversight; the CLI carries the loud reject.
                case .holding:    break
                case .workspace:  break   // workspace headers carry ws != nil
                }
            }
        case .window(_, let ws, let pid, let id, let title):
            showWindowMenu(at: scr, workspaceIndex: ws,
                           pid: pid, windowID: id, title: title)
        default:
            break
        }
    }

    // The header (layout) + window (ops) menus are shared with grid /
    // rail via `ViewContextMenu` (FacetView) so all three views show the
    // identical themed popup (③).
    /// Header right-click / `m` menu → the workspace layout picker. `g` is the
    /// render group (display position) — drives the §D `index (label)` header.
    func headerMenu(at scr: NSPoint, group g: Int, workspaceIndex ws: Int,
                            filterable: Bool = false) {
        showLayoutMenu(at: scr, group: g, workspaceIndex: ws, filterable: filterable)
    }

    private func showLayoutMenu(at scr: NSPoint, group g: Int, workspaceIndex ws: Int,
                                filterable: Bool = false) {
        ViewContextMenu.showLayout(at: scr, backend: backend,
                                   workspaceIndex: ws, workspaces: lastWorkspaces,
                                   header: sectionHeaderDisplay(group: g),
                                   palette: pal, filterable: filterable,
                                   // §E: SECTION ▸ Rename → controller resolves
                                   // `g` to the 1-based index + current label
                                   // (same logic as `sectionHeaderDisplay`).
                                   // `scr` = the header's screen point, so the
                                   // editor opens at the clicked header's height.
                                   onRename: { [weak self] in
                                       self?.controller?.beginSectionRename(group: g, at: scr)
                                   })
    }

    /// §D caption for the header at render group `g`: `index (label)`. Section
    /// mode → `index = g + 1` (g IS the display position). By-workspace degrade
    /// → `g == ws.index`, so the display position is `g`'s slot in the
    /// (reorder-applied) `lastWorkspaces`, NOT `g + 1` — matching the rendered
    /// row caption and `--focus index:N`.
    func sectionHeaderDisplay(group g: Int) -> String {
        if g >= 0, g < lastSections.count {
            return sectionDisplayLabel(index: g + 1, label: lastSections[g].label)
        }
        guard let pos = lastWorkspaces.firstIndex(where: { $0.index == g }) else {
            return sectionDisplayLabel(index: g + 1, label: "")
        }
        return sectionDisplayLabel(index: pos + 1, label: lastWorkspaces[pos].name)
    }

    /// Lens-section header right-click / `m` menu → the stateless-only union
    /// layout picker (R9). `g` is the render group; `lastSections[g]` is the
    /// `type=isolate` section it came from. Picking routes through the controller,
    /// which activates the isolate desktop then sets its union layout.
    func isolateHeaderMenu(at scr: NSPoint, group g: Int, filterable: Bool = false) {
        guard g >= 0, g < lastSections.count else { return }
        let sec = lastSections[g]
        guard sec.sectionType == .matched else { return }
        // No layout picker: an isolate desktop's `layout` is a key on the
        // `[desktop.N]` TABLE, not on a section, so the matched section has no
        // layout of its own to pick. Header offers ONLY SECTION ▸ Rename.
        // §D: the header is the unified `index (label)` caption (e.g. "4 (Web)").
        ViewContextMenu.showSectionRenameMenu(
            at: scr,
            header: sectionDisplayLabel(index: g + 1, label: sec.label),
            palette: pal, filterable: filterable,
            // §E: SECTION ▸ Rename → controller resolves `g` to index + label
            // (same `sectionHeaderDisplay` logic; passes the SAME `g`).
            // `scr` = the header's screen point → editor opens at its height.
            onRename: { [weak self] in
                self?.controller?.beginSectionRename(group: g, at: scr)
            },
            // t-0020: an isolate desktop also offers "Edit match" — live-tune its filter.
            // Routes to the controller's match-edit panel (the GUI twin of
            // `facet section --match`).
            onEditMatch: { [weak self] in
                self?.controller?.beginSectionMatchEdit(group: g, at: scr)
            })
    }

    func showWindowMenu(at scr: NSPoint,
                                workspaceIndex ws: Int,
                                pid: Int,
                                windowID id: WindowID,
                                title: String,
                                filterable: Bool = false) {
        // Per-window tag editing (R10): the "Tag…" item opens the tag
        // checklist panel via the controller (which owns the keyable panel +
        // the activation dance). Section model only — `applyAdd`'s pivot-era
        // "Add to <lens>" is retired in favour of editing the window's tags
        // directly.
        let onEditTags: ((Int, WindowID, String, NSPoint) -> Void)? =
            sectionModeActive
            ? { [weak self] pid, id, title, anchor in
                  self?.controller?.openTagEditor(pid: pid, windowID: id,
                                                  title: title, at: anchor)
              }
            : nil
        ViewContextMenu.showWindow(
            at: scr, backend: backend, workspaceIndex: ws,
            workspaces: lastWorkspaces, pid: pid, windowID: id, title: title,
            palette: pal,
            filterable: filterable,
            onEditTags: onEditTags
        ) { [weak self] ops, window, ws in
            self?.controller?.runWindowOps(ops, on: window, workspaceIndex: ws)
        }
    }
}
