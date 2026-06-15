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
        tagMode: Bool = false,
        onAddTag: ((WindowID) -> Void)? = nil,
        onRemoveTag: ((WindowID, String) -> Void)? = nil,
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
        // Tag mode (#191 PR-7): after the window ops, append a "Tag" item
        // (opens the tag-name input → auto-vivify + add) and one
        // "Untag #NAME" per tag the window already carries. The closures
        // route to the controller's tag-input box / by-id retag. Grid /
        // rail are workspace-only in tag mode, so they never set `tagMode`
        // and these items never appear there.
        let winTags = tagMode ? (win?.tags ?? []) : []
        var labels = menu.map(\.label)
        if tagMode {
            labels.append("Tag")
            labels.append(contentsOf: winTags.map { "Untag #\($0)" })
        }
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
                // Tag section: index 0 = "Tag", then one per existing tag.
                let ti = i - menu.count
                if ti == 0 {
                    onAddTag?(id)
                } else {
                    onRemoveTag?(id, winTags[ti - 1])
                }
            }
        }
    }
}
