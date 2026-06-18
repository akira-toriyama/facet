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
    /// Header right-click / `m` menu. Workspace mode → the layout picker
    /// directly. Tag mode → a two-facet menu (Layout + Select tags), since
    /// a tag-world also owns a lens (which tags are shown).
    func headerMenu(at scr: NSPoint, workspaceIndex ws: Int,
                            filterable: Bool = false) {
        if tagModeActive {
            // Tag mode: one sectioned menu (Layout + Select tags). Not
            // filterable — the layout list is short and `Select tags` opens
            // its own filterable checklist.
            showTagWorldMenu(at: scr, workspaceIndex: ws)
        } else {
            showLayoutMenu(at: scr, workspaceIndex: ws, filterable: filterable)
        }
    }

    private func showTagWorldMenu(at scr: NSPoint, workspaceIndex ws: Int) {
        let modes = backend.layoutModes.filter {
            LayoutGrouping.isCompatible(mode: $0, with: .tag)
        }
        let cur = lastWorkspaces.first { $0.index == ws }?.layoutMode
        let bk = backend
        ViewContextMenu.showTagWorld(
            at: scr, layoutModes: modes, currentLayout: cur, palette: pal,
            onPickLayout: { mode in
                cliQueue.async { bk.setLayoutMode(workspaceIndex: ws, mode: mode) }
            },
            onSelectTags: { [weak self] in
                self?.controller?.openLensSelector(at: scr) },
            // "All tags" (item 15/16): lens = every tag = show everything.
            // `autoFocus: false` keeps the tree from losing key to a window
            // in the new union.
            onAllTags: { cliQueue.async { bk.setLens(.all, autoFocus: false) } })
    }

    private func showLayoutMenu(at scr: NSPoint, workspaceIndex ws: Int,
                                filterable: Bool = false) {
        ViewContextMenu.showLayout(at: scr, backend: backend,
                                   workspaceIndex: ws, workspaces: lastWorkspaces,
                                   palette: pal, filterable: filterable,
                                   tagMode: tagModeActive)
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
        let lensTargets: [(label: String, groupID: String)] =
            sectionModeActive
            ? lastGroups.enumerated().compactMap { (g, grp) in
                  guard grp.sectionType == .lens, g != currentGroup else { return nil }
                  return (grp.label, grp.id)
              }
            : []
        ViewContextMenu.showWindow(
            at: scr, backend: backend, workspaceIndex: ws,
            workspaces: lastWorkspaces, pid: pid, windowID: id, title: title,
            palette: pal,
            tagMode: tagModeActive,
            filterable: filterable,
            addToLensTargets: lensTargets,
            onApplyAdd: { [weak self] gid in
                self?.controller?.applyAdd(windowID: id, toGroupID: gid)
            },
            onOpenTagEditor: { [weak self] wid, pid, app, title, tags, anchor in
                self?.controller?.openTagEditor(
                    forWindow: wid, pid: pid, appName: app, title: title,
                    currentTags: tags, at: anchor)
            }
        ) { [weak self] ops, window, ws in
            self?.controller?.runWindowOps(ops, on: window, workspaceIndex: ws)
        }
    }
}
