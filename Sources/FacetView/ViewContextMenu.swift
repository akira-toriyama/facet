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
        PopupMenu.shared.show(at: scr,
                              header: "Window",
                              items: menu.map(\.label),
                              checkedIndex: nil,
                              palette: palette) { i in
            let item = menu[i]
            if item.isClose {
                cliQueue.async { backend.closeWindow(id) }
            } else {
                let window = Window(id: id, pid: pid, appName: "",
                                    title: title, isFocused: false,
                                    isFloating: floating, frame: nil)
                runOps(item.ops, window, ws)
            }
        }
    }
}
