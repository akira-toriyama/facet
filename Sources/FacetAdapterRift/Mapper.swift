// Pure conversion from rift-cli's JSON-shape structs to the
// backend-neutral FacetCore models. The mapper is the *only* place
// in the adapter that knows both shapes — keeping it factored out
// lets us cover it with JSON-fixture tests that don't need rift-cli
// installed.

import FacetCore

enum RiftMapper {
    static func workspace(from rf: RFWorkspace) -> Workspace {
        Workspace(
            index: rf.index,
            name: rf.name,
            isActive: rf.is_active,
            layoutMode: rf.layout_mode,
            windows: rf.windows.map(window(from:)))
    }

    static func window(from rf: RFWindow) -> Window {
        Window(
            id: WindowID(serverID: rf.window_server_id),
            pid: rf.id.pid,
            appName: rf.app_name,
            title: rf.title,
            isFocused: rf.is_focused,
            // rift omits `is_floating` for non-tileable workspaces;
            // treat absent as not-floating to match ws-tabs behavior.
            isFloating: rf.is_floating ?? false,
            frame: rf.frame?.cg)
    }
}
