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
    case cycleStackNext, cycleStackPrev            // stack (Phase γ.2)
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
    /// Short identifier shown in `facet status` and debug logs
    /// (e.g. `"rift"`, `"native"`). Lower-case, no spaces.
    var name: String { get }

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

    /// Re-apply the active workspace's layout. Phase γ escape
    /// hatch: when the on-screen state has drifted from what the
    /// backend thinks (external resize / unexpected move), the
    /// user runs `facet --retile` to force a fresh tile pass.
    /// Backends that delegate layout (rift) silently no-op.
    func retileActiveWorkspace()

    /// Stream of backend state-change notifications.
    ///
    /// Consumed once at app start by the controller — typically as
    /// `for await event in backend.events { refresh() }` inside a
    /// long-lived `Task`. Cancelling the task tears the subscription
    /// down; the stream finishes when the adapter releases its
    /// continuation. Single-subscriber by convention — each adapter
    /// builds the stream once and replays nothing.
    var events: AsyncStream<BackendEvent> { get }

    /// Stream of human-readable operational errors the adapter
    /// surfaced (e.g. `rift-cli` returned non-zero, AX permission
    /// failure). The Controller subscribes and routes each
    /// message into `facet status`'s lastError slot.
    ///
    /// Single-subscriber, same lifetime as `events`. Adapters
    /// only push messages a *user* could act on — internal
    /// debugging chatter belongs in `Log.debug` instead.
    var errors: AsyncStream<String> { get }
}
