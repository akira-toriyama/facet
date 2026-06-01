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
    case cycleStackNext, cycleStackPrev            // stack (native adapter)
    case growMaster, shrinkMaster                  // tall / wide / centered: ratio
    case incMaster, decMaster                      // tall / wide / centered: master count
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
/// Deliberately coarse: subscribers re-query via `workspaces()`
/// rather than diffing — plenty for the frame rates the view
/// layer runs at.
public enum BackendEvent: Sendable {
    case refreshNeeded
}

/// Relative workspace target for `switchWorkspaceRelative`.
/// `next` / `prev` step through the configured workspaces (wrapping
/// at the ends); `recent` returns to the previously-active one.
public enum RelativeWorkspace: Sendable, Equatable {
    case next, prev, recent
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

    /// Switch the active workspace.
    /// - Parameters:
    ///   - index: 0-based workspace index (CLI / catalog use 1-based;
    ///     translation happens at the seam).
    ///   - autoFocus: when `true`, the backend should focus the
    ///     window the user was last on in the destination WS — or,
    ///     when the destination is empty, defocus the source WS's
    ///     window (e.g. activate Finder). Callers that already
    ///     pick an explicit window to focus right after the switch
    ///     (tree window-row click, grid window-thumb click, etc.)
    ///     should leave this `false` to avoid a redundant AX write
    ///     plus a brief flicker before the explicit pick wins.
    func switchWorkspace(toIndex index: Int, autoFocus: Bool)

    /// Switch relative to the current workspace: `next` / `prev` step
    /// through the configured workspaces (wrapping), `recent` returns
    /// to the previously-active one. No-op when there's nowhere to go
    /// (fewer than 2 workspaces, or no recent recorded yet).
    /// `autoFocus` behaves as in `switchWorkspace`.
    func switchWorkspaceRelative(_ target: RelativeWorkspace, autoFocus: Bool)

    /// Switch to the workspace whose name matches `name` (first match,
    /// case-sensitive). No-op when no workspace has that name.
    /// `autoFocus` behaves as in `switchWorkspace`. Names are a stable
    /// handle even as position-based indices shift under add / remove /
    /// move (memory: facet-cli-dynamic-runtime-model).
    func switchWorkspace(named name: String, autoFocus: Bool)

    /// Append a new, empty (unnamed) workspace at the end. Runtime
    /// state — session-only, not persisted (config stays the seed).
    func addWorkspace()

    /// Remove a workspace (1-based position; `nil` = active). Its
    /// windows evacuate to a neighbouring workspace so nothing is
    /// lost; positions above the removed one shift down by one. No-op
    /// when only one workspace remains (the last can't be removed).
    func removeWorkspace(at position: Int?)

    /// Rename a workspace (1-based position; `nil` = active). An empty
    /// name makes it display its position number.
    func renameWorkspace(at position: Int?, to name: String)

    /// Move the active workspace to a new 1-based position (reorder).
    /// No-op for an out-of-range or unchanged position.
    func moveActiveWorkspace(to position: Int)

    func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int)
    func setLayoutMode(workspaceIndex index: Int, mode: String)
    func closeWindow(_ id: WindowID)

    /// Run an action against the currently-focused window.
    func perform(_ action: WindowAction)

    /// Build the right-click menu for a window, given its workspace's
    /// layout `mode`, whether the window is `floating`, whether it is
    /// the `isMaster` window (first in tiling order), and the
    /// workspace's tiled `windowCount` (non-floating members). Pure
    /// function on the backend's knowledge of which actions its
    /// layouts support; state-dependent items (e.g. "Promote to
    /// master", stack cycling) are gated so the menu matches the
    /// window's actual state.
    func windowMenu(mode: String, floating: Bool,
                    isMaster: Bool, windowCount: Int) -> [WindowMenuItem]

    /// Re-apply the active workspace's layout. Phase γ escape
    /// hatch: when the on-screen state has drifted from what the
    /// backend thinks (external resize / unexpected move), the
    /// user runs `facet workspace --retile` to force a fresh tile pass.
    /// Backends that delegate layout (rift) silently no-op.
    func retileActiveWorkspace()

    /// Reset the active workspace's master knobs to their even
    /// baseline (`facet workspace --balance`): master ratio → 0.5,
    /// master count → 1, undoing accumulated grow/shrink/inc/dec
    /// nudges. No-op for modes without master knobs (bsp / stack /
    /// grid / spiral / float) and for backends without layout state.
    func balanceActiveWorkspace()

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

public extension WindowBackend {
    /// Convenience for callers that don't care about auto-focus
    /// (the majority). Keeps the call sites that already follow
    /// up with `Focus.assert` etc. terse.
    func switchWorkspace(toIndex index: Int) {
        switchWorkspace(toIndex: index, autoFocus: false)
    }

    // Default no-ops so backends that don't support a dynamic
    // workspace set (and the unit-test stub) need not implement
    // these. The native adapter overrides all of them.
    func switchWorkspace(named name: String, autoFocus: Bool) {}
    func addWorkspace() {}
    func removeWorkspace(at position: Int?) {}
    func renameWorkspace(at position: Int?, to name: String) {}
    func moveActiveWorkspace(to position: Int) {}
    func balanceActiveWorkspace() {}
}
