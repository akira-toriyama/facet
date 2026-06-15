// Shared context-menu builders (③) so the tree, grid and rail show the
// SAME themed PopupMenu for a workspace header (layout-engine picker) and
// a window (ops menu). Each view supplies its own snapshot + hit point;
// the backend round-trip + menu data are identical, so they live here in
// the shared FacetView layer rather than duplicated three times.

import AppKit
import FacetCore

@MainActor
public enum ViewContextMenu {

    /// Layout-engine picker for a workspace header. `ws` is the 0-based
    /// workspace index; `workspaces` the view's current snapshot (for the
    /// checkmark on the active mode).
    public static func showLayout(
        at scr: NSPoint,
        backend: any WindowBackend,
        workspaceIndex ws: Int,
        workspaces: [Workspace],
        palette: ResolvedPalette
    ) {
        let modes = backend.layoutModes
        let cur = workspaces.first { $0.index == ws }?.layoutMode
        let idx = modes.firstIndex(of: cur ?? "")
        PopupMenu.shared.show(at: scr,
                              header: "WS\(ws + 1) layout",
                              items: modes,
                              checkedIndex: idx,
                              palette: palette) { i in
            cliQueue.async { backend.setLayoutMode(workspaceIndex: ws, mode: modes[i]) }
        }
    }

    /// Panel-level menu for the pinned "Desktop N" band — the third
    /// right-click surface (scope hierarchy: panel ▸ workspace ▸ window).
    /// Exposes the tree-wide keyboard modes that are otherwise reachable
    /// only by entering `--active`: Search (the `s` key) always, and Manage
    /// tags (the `t` key) only under tag grouping. Picking an item runs its
    /// callback, which self-activates facet — no window is focused, so the
    /// #66 same-app-focus invariant and the never-steal-focus contract both
    /// hold (contrast a window-row click, which must NOT grab key).
    public static func showDesktop(
        at scr: NSPoint,
        palette: ResolvedPalette,
        tagManage: Bool,
        onSearch: @escaping () -> Void,
        onTagManage: @escaping () -> Void
    ) {
        var items = ["Search"]
        if tagManage { items.append("Manage tags") }
        PopupMenu.shared.show(at: scr,
                              header: "Desktop",
                              items: items,
                              checkedIndex: nil,
                              palette: palette) { i in
            if i == 0 { onSearch() } else { onTagManage() }
        }
    }

    /// Window-ops menu for a window (close / float / master / stack /
    /// sticky, gated by the window's state). `runOps` runs the chosen
    /// non-close ops against the window — the caller threads it to the
    /// controller's `runWindowOps` (close goes straight to the backend).
    public static func showWindow(
        at scr: NSPoint,
        backend: any WindowBackend,
        workspaceIndex ws: Int,
        workspaces: [Workspace],
        pid: Int,
        windowID id: WindowID,
        title: String,
        palette: ResolvedPalette,
        tagMode: Bool = false,
        onOpenTagEditor: ((_ id: WindowID, _ pid: Int, _ appName: String,
                           _ title: String, _ currentTags: [String],
                           _ anchor: NSPoint) -> Void)? = nil,
        runOps: @escaping (_ ops: [WindowAction], _ window: Window, _ ws: Int) -> Void
    ) {
        let wsModel = workspaces.first { $0.index == ws }
        let mode = wsModel?.layoutMode ?? ""
        let win = wsModel?.windows.first { $0.id == id }
        let floating = win?.isFloating ?? false
        let isMaster = win?.isMaster ?? false
        let isSticky = win?.isSticky ?? false
        // Non-floating tiled members — what stack cycling rotates over.
        let windowCount = wsModel?.windows.filter { !$0.isFloating }.count ?? 0
        let menu = backend.windowMenu(mode: mode, floating: floating,
                                      isMaster: isMaster,
                                      windowCount: windowCount,
                                      isSticky: isSticky)
        // Tag mode (#4): after the window ops, append a single "Tag" item
        // that opens the per-window tag-edit checklist (`TagEditPanel`). The
        // closure routes to the controller, which owns the panel + key
        // focus. Grid / rail are workspace-only in tag mode, so they never
        // set `tagMode` and this item never appears there. (The old
        // "Untag #NAME" group is gone — un-tagging now happens inside the
        // checklist by unchecking the row.)
        var labels = menu.map(\.label)
        if tagMode { labels.append("Tag") }
        PopupMenu.shared.show(at: scr,
                              header: "Window",
                              items: labels,
                              checkedIndex: nil,
                              palette: palette) { i in
            if i < menu.count {
                let item = menu[i]
                if item.isClose {
                    cliQueue.async { backend.closeWindow(id) }
                } else {
                    let window = Window(id: id, pid: pid, appName: "",
                                        title: title, isFocused: false,
                                        isFloating: floating, frame: nil)
                    runOps(item.ops, window, ws)
                }
            } else {
                // The lone tag item: open the checklist for this window.
                onOpenTagEditor?(id, pid, win?.appName ?? "",
                                 win?.title ?? title, win?.tags ?? [], scr)
            }
        }
    }
}
