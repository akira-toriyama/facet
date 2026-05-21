// FacetCore — backend protocol surface.
//
// `WindowBackend` is the only seam between adapters (rift today,
// native later) and the rest of the app. Views and the controller
// hold it as a protocol, never as a concrete type — see
// docs/architecture.md.

/// An action that operates on the WM's currently-selected window.
///
/// Semantic enum, kept layout-mode-agnostic. Adapters silently no-op
/// actions that don't apply to the current backend / layout mode —
/// the menu builder (`WindowBackend.windowMenu`) is responsible for
/// only surfacing applicable items in the first place.
public enum WindowAction: Sendable, Equatable {
    case toggleFloat, toggleFullscreen
    case promoteToMaster, swapMasterStack          // master_stack
    case toggleStack, toggleOrientation            // traditional / bsp / stack
    case centerColumn, snapStrip                   // scrolling
}

/// One entry in the window right-click menu.
///
/// `ops` is a sequence — e.g. an item that "unfloats then promotes"
/// runs `[.toggleFloat, .promoteToMaster]` against the focused window.
/// `isClose` is the one operation that needs an explicit window id
/// (not focus), since the focused window is what closes.
public struct WindowMenuItem: Sendable {
    public let label: String
    public let ops: [WindowAction]
    public let isClose: Bool

    public init(_ label: String, _ ops: [WindowAction], close: Bool = false) {
        self.label = label
        self.ops = ops
        self.isClose = close
    }
}

/// Coarse-grained event emitted by the backend when its state has
/// likely changed (a window opened / closed, workspace switched, …).
///
/// Deliberately coarse: subscribers re-query via `workspaces()` rather
/// than diffing — that's how ws-tabs operated and it's plenty for the
/// frame rates the view layer runs at.
public enum BackendEvent: Sendable {
    case refreshNeeded
}

/// The only surface the rest of the app knows about. rift / native
/// each implement it; the UI, AX focus glue, themes and DnD are all
/// WM-agnostic.
public protocol WindowBackend: Sendable {
    /// Backend-defined layout-mode names that may appear on
    /// `Workspace.layoutMode` (e.g. rift returns
    /// `["master_stack", "traditional", "bsp", "stack", "scrolling"]`).
    var layoutModes: [String] { get }

    func workspaces() -> [Workspace]
    func focusedWindow() -> WindowID?

    func switchWorkspace(toIndex index: Int)
    func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int)
    func setLayoutMode(workspaceIndex index: Int, mode: String)
    func closeWindow(_ id: WindowID)

    /// Run an action against the currently-focused window.
    func perform(_ action: WindowAction)

    /// Build the right-click menu for a window in the given layout
    /// mode / floating state. Pure function on the backend's
    /// knowledge of which actions its layouts support.
    func windowMenu(mode: String, floating: Bool) -> [WindowMenuItem]

    /// Subscribe to backend state-change notifications. The handler
    /// runs on a backend-owned background queue (not the main
    /// thread). Call once at app start; there is no `stop` — adapters
    /// tie the subscription to their own lifetime.
    func startEvents(_ handler: @escaping @Sendable (BackendEvent) -> Void)
}
