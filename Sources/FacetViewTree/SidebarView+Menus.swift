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
            // Workspace header → full layout picker; lens header → the
            // stateless-only union layout picker (R9 / Cluster B).
            if let ws { headerMenu(at: scr, workspaceIndex: ws) }
            else { lensHeaderMenu(at: scr, group: g) }
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
    /// Header right-click / `m` menu → the workspace layout picker.
    func headerMenu(at scr: NSPoint, workspaceIndex ws: Int,
                            filterable: Bool = false) {
        showLayoutMenu(at: scr, workspaceIndex: ws, filterable: filterable)
    }

    private func showLayoutMenu(at scr: NSPoint, workspaceIndex ws: Int,
                                filterable: Bool = false) {
        ViewContextMenu.showLayout(at: scr, backend: backend,
                                   workspaceIndex: ws, workspaces: lastWorkspaces,
                                   palette: pal, filterable: filterable)
    }

    /// Lens-section header right-click / `m` menu → the stateless-only union
    /// layout picker (R9). `g` is the render group; `lastSections[g]` is the
    /// `type=lens` section it came from. Picking routes through the controller,
    /// which activates the lens then sets its union layout.
    func lensHeaderMenu(at scr: NSPoint, group g: Int, filterable: Bool = false) {
        guard g >= 0, g < lastSections.count else { return }
        let sec = lastSections[g]
        guard sec.sectionType == .lens else { return }
        let label = sec.label
        ViewContextMenu.showLensLayout(
            at: scr, backend: backend, lensLabel: label,
            palette: pal, filterable: filterable
        ) { [weak self] mode in
            self?.controller?.setLensLayout(label: label, mode: mode)
        }
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
