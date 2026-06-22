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
        case .header(_, let ws):
            // A lens-section header (workspaceIndex nil) has no layout to
            // pick; PR6 adds a lens menu. Workspace header → layout picker.
            if let ws { headerMenu(at: scr, workspaceIndex: ws) }
        case .window(let g, let ws, let pid, let id, let title):
            showWindowMenu(at: scr, workspaceIndex: ws,
                           pid: pid, windowID: id, title: title, currentGroup: g)
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

    func showWindowMenu(at scr: NSPoint,
                                workspaceIndex ws: Int,
                                pid: Int,
                                windowID id: WindowID,
                                title: String,
                                filterable: Bool = false,
                                currentGroup: Int? = nil) {
        // Section model (PR8): "Add to ▸ <lens>" — apply-only ADD (multi-match).
        // Lens sections only, excluding the row's OWN render group; the
        // Controller's ApplyResolver no-ops a drop-inert / non-satisfying lens.
        let lensTargets: [(label: String, sectionID: String)] =
            sectionModeActive
            ? lastSections.enumerated().compactMap { (g, sec) in
                  guard sec.sectionType == .lens, g != currentGroup else { return nil }
                  return (sec.label, sec.id)
              }
            : []
        ViewContextMenu.showWindow(
            at: scr, backend: backend, workspaceIndex: ws,
            workspaces: lastWorkspaces, pid: pid, windowID: id, title: title,
            palette: pal,
            filterable: filterable,
            addToLensTargets: lensTargets,
            onApplyAdd: { [weak self] sid in
                self?.controller?.applyAdd(windowID: id, toSectionID: sid)
            }
        ) { [weak self] ops, window, ws in
            self?.controller?.runWindowOps(ops, on: window, workspaceIndex: ws)
        }
    }
}
