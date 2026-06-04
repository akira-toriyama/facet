// FacetCore — backend protocol surface.
//
// `WindowBackend` is the only seam between a backend adapter
// (`FacetAdapterNative` today; a port future adapters can implement)
// and the rest of the app. Views and the controller hold it as a
// protocol, never as a concrete type — see docs/architecture.md.

import CoreGraphics

/// An action that operates on the WM's currently-selected window.
///
/// Semantic enum, kept layout-mode-agnostic. Adapters silently no-op
/// actions that don't apply to the current backend / layout mode —
/// the menu builder (`WindowBackend.windowMenu`) is responsible for
/// only surfacing applicable items in the first place.
public enum WindowAction: Sendable, Equatable {
    case toggleFloat, toggleFullscreen
    case toggleSticky                              // pin across all WSs
    case promoteToMaster, swapMasterStack          // master_stack
    case toggleStack, toggleOrientation            // traditional / bsp / stack
    case centerColumn, snapStrip                   // scrolling
    case cycleStackNext, cycleStackPrev            // stack (native adapter)
    case growMaster, shrinkMaster                  // master-* engines: ratio
    case incMaster, decMaster                      // master-* engines: master count
    case focusDir(Direction)               // ② directional focus
    case moveDir(Direction)                // ② directional move (swap)
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
    /// A window focus change specifically (vs any other reconcile
    /// trigger). The Controller fast-paths these with a much shorter
    /// debounce because they drive the directly-felt ④ shake + ⑤
    /// active-window border. Still goes through the same settled
    /// reconcile snapshot — just sooner.
    case focusChanged
}

/// Relative workspace target for `switchWorkspaceRelative`.
/// `next` / `prev` step through the configured workspaces (wrapping
/// at the ends); `recent` returns to the previously-active one.
public enum RelativeWorkspace: Sendable, Equatable {
    case next, prev, recent
}

/// Axis to mirror a layout across (`mirrorActiveWorkspace`).
/// `horizontal` reflects left↔right, `vertical` reflects top↔bottom
/// (image-editor "flip horizontal / vertical" semantics).
public enum MirrorAxis: Sendable, Equatable {
    case horizontal, vertical
}

/// Which side of a target window an insert lands on (real-window DnD,
/// 枠C `insertWindow`). Layout-interpreted: bsp splits the target on
/// that side; stateless / stack engines place the moved window before
/// (`left` / `top`) or after (`right` / `bottom`) the target in the
/// window order. `top` = the minY side, `bottom` = the maxY side.
public enum InsertEdge: Sendable, Equatable {
    case left, right, top, bottom
}

/// The only surface the rest of the app knows about. The backend
/// adapter (`FacetAdapterNative`) implements it; the UI, AX focus
/// glue, themes and DnD are all backend-agnostic.
public protocol WindowBackend: Sendable {
    /// Short identifier shown in `facet status` and debug logs
    /// (e.g. `"native"`). Lower-case, no spaces.
    var name: String { get }

    /// Backend-defined layout-mode names that may appear on
    /// `Workspace.layoutMode` (e.g. the native adapter returns
    /// `["bsp", "stack", "master-left", …, "grid", "spiral", "float"]`).
    var layoutModes: [String] { get }

    func workspaces() -> [Workspace]
    func focusedWindow() -> WindowID?

    /// Window-server-fresh focused window for the focus fast-path.
    /// Default = `focusedWindow()` (the AX/NSWorkspace path); the native
    /// adapter overrides it with a private-SkyLight front-signal read
    /// that commits more promptly than `NSWorkspace.frontmostApplication`.
    func frontWindowFast() -> WindowID?

    /// Briefly vibrate `id` in place as a focus cue (④) — position-only,
    /// the layout is untouched so neighbours never move. Has a default
    /// no-op so non-animating backends (test stubs) needn't implement it.
    /// `amplitude` (px) + `durationMs` are passed in from the caller's
    /// live config so `[shake]` edits hot-reload (the adapter's own
    /// config is frozen at init).
    func animateShake(_ id: WindowID, amplitude: CGFloat, durationMs: Double)

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

    /// Un-hide / un-minimize `id`, then focus it — the tree-click
    /// gesture on a *hidden* row (a window the user Cmd+H'd or Cmd+M'd,
    /// so `isOnscreen == false` and hide-reclaim pulled its tile slot).
    /// Probe-based: unhides the owning app AND clears `kAXMinimized`,
    /// each a no-op when not applicable, so the hide-type needn't be
    /// tracked. No-op when `id` isn't managed. Tree-click only — not a
    /// CLI verb. Memory: `facet-hide-reclaim-decisions`.
    func revealWindow(_ id: WindowID)

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
                    isMaster: Bool, windowCount: Int,
                    isSticky: Bool) -> [WindowMenuItem]

    /// Re-apply the active workspace's layout. Phase γ escape
    /// hatch: when the on-screen state has drifted from what the
    /// backend thinks (external resize / unexpected move), the
    /// user runs `facet workspace --retile` to force a fresh tile pass.
    /// A backend that delegates tiling to the OS would silently
    /// no-op; the native adapter performs a real tile pass.
    func retileActiveWorkspace()

    /// Reset the active workspace's master knobs to their even
    /// baseline (`facet workspace --balance`): master ratio → 0.5,
    /// master count → 1, undoing accumulated grow/shrink/inc/dec
    /// nudges. No-op for modes without master knobs (bsp / stack /
    /// grid / spiral / float) and for backends without layout state.
    func balanceActiveWorkspace()

    /// Rotate the active workspace's bsp tree clockwise by `degrees`
    /// (90 / 180 / 270) — `facet workspace --rotate=N`. No-op outside
    /// bsp mode (the tree is the only rotatable layout state) and for
    /// backends without one.
    func rotateActiveWorkspace(degrees: Int)

    /// Mirror the active workspace's bsp tree across `axis`
    /// (`facet workspace --mirror=horizontal|vertical`). Same bsp-only
    /// no-op contract as `rotateActiveWorkspace`.
    func mirrorActiveWorkspace(_ axis: MirrorAxis)

    /// Swap two tiled windows' positions within the active workspace
    /// (real-window DnD, 枠C). Stateless / stack engines trade the two
    /// windows' order slots; bsp trades their leaves (frames swap, tree
    /// shape unchanged). No-op unless both are non-floating members of
    /// the active workspace. Not a CLI verb — DnD-only (the UI in PR-2
    /// is the sole caller).
    func swapWindows(_ a: WindowID, _ b: WindowID)

    /// Insert `moved` beside `target` on `edge` within the active
    /// workspace (real-window DnD, 枠C). The edge is layout-interpreted:
    /// bsp splits the target's `edge` side and drops `moved` there;
    /// stateless / stack engines move `moved` before (`left` / `top`)
    /// or after (`right` / `bottom`) `target` in the window order. The
    /// prediction overlay (PR-2) absorbs the per-engine difference.
    /// No-op unless both are non-floating members of the active
    /// workspace. Not a CLI verb — DnD-only.
    func insertWindow(_ moved: WindowID, beside target: WindowID,
                      edge: InsertEdge)

    /// Follow a real edge-drag resize of `id` to `frame` within the
    /// active workspace (real-window resize, 枠C 機能2). The window was
    /// resized natively by the user; facet only updates the controlling
    /// split ratio (bsp) / master divider (master-*) so the
    /// opposite side tracks it, then re-tiles. No-op outside those modes,
    /// for an off-tree window, or when no divider-controlling edge moved.
    /// Not a CLI verb — DnD/resize-only. `frame` is backend (Quartz) coords.
    ///
    /// `reflowDragged` picks the re-tile scope. `false` (PR-2 live tick):
    /// reflow the NEIGHBOURS only and leave `id` exactly where the OS is
    /// drawing it, so facet never fights the in-progress native resize.
    /// `true` (gesture settle / one-shot): reflow everything incl. `id`,
    /// snapping it onto its freshly-computed tile slot.
    func resizeWindow(_ id: WindowID, to frame: CGRect, reflowDragged: Bool)

    /// The window's current on-screen frame in backend (Quartz, top-left)
    /// coords, read live from the OS — or `nil` when it isn't a managed /
    /// resolvable window. Used by the real-window resize gesture (枠C 機能2)
    /// to poll the natively-resized window each tick and self-classify the
    /// drag (size changed ⇒ resize, position only ⇒ move). Read-only; no
    /// side-effects.
    func windowFrame(_ id: WindowID) -> CGRect?

    /// The layout the active workspace WOULD have if `dragged` were
    /// dropped onto `target` with intent `zone` — without committing.
    /// Computed on a copy of the layout state through the SAME swap /
    /// insert + tiling math (incl. inner gap) the commit uses, so the
    /// real-window-DnD prediction overlay (枠C PR-3) can't drift from
    /// what actually lands. `frames` are backend (Quartz, top-left)
    /// coords; `moved` is which windows the drop relocates (diffed
    /// against the pre-drop computed layout, so it's exact — no live /
    /// sub-pixel noise). `.none` when the drop changes nothing / isn't
    /// applicable. Not a CLI verb — DnD-only.
    func predictedDrop(dragged: WindowID, target: WindowID,
                       zone: IntentZone) -> DropPrediction

    /// Assign mark `name` (vim-style label) to the focused window
    /// (`facet window --mark=NAME`). 1:1: the name's old window and the
    /// focused window's old mark are both cleared. Returns `false` when
    /// there is no focused window (caller surfaces the error).
    func markFocusedWindow(_ name: String) -> Bool

    /// Jump focus to the window holding mark `name`
    /// (`facet window --focus-mark=NAME`), switching workspace if it
    /// lives on another one. Returns `false` when the mark is unset or
    /// its window has since closed (caller surfaces the error).
    func focusMark(_ name: String) -> Bool

    /// Remove mark `name` (`facet window --unmark=NAME`). Returns
    /// `false` when the name wasn't set (caller surfaces the error).
    func unmark(_ name: String) -> Bool

    /// Stash the focused window onto scratchpad shelf `name`, parking
    /// it off-screen (`facet scratchpad --stash=NAME`). A named hidden
    /// shelf, 1:1 like marks; clears any sticky (XOR), force-floats and
    /// detaches the window. Returns `false` when there is no managed
    /// focused window (caller surfaces the error).
    func stashScratchpad(_ name: String) -> Bool

    /// Toggle scratchpad shelf `name` (`facet scratchpad --toggle=NAME`):
    /// if its window is *visible on the current workspace*, re-park it to
    /// the shelf; otherwise (stashed, or settled on another WS) summon it
    /// onto the current workspace as a floating overlay. Returns `false`
    /// when the shelf is unset / its window has closed.
    func toggleScratchpad(_ name: String) -> Bool

    /// Release shelf `name` (`facet scratchpad --release=NAME`): drop it
    /// from the shelf and re-home the window as a normal tiled window of
    /// the current workspace (same landing as un-sticky). Returns `false`
    /// when the shelf is unset.
    func releaseScratchpad(_ name: String) -> Bool

    /// Names of currently *stashed* scratchpad shelves (for
    /// `facet status`). Settled (summoned) shelves are excluded — they
    /// show in the tree under their workspace. Empty when none.
    func stashedScratchpads() -> [String]

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
    /// surfaced (e.g. an AX call failed, or Accessibility permission
    /// is missing). The Controller subscribes and routes each
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

    /// Default no-op focus shake (④) — only the native adapter animates.
    func animateShake(_ id: WindowID, amplitude: CGFloat, durationMs: Double) {}
    func renameWorkspace(at position: Int?, to name: String) {}
    func moveActiveWorkspace(to position: Int) {}
    func balanceActiveWorkspace() {}
    func rotateActiveWorkspace(degrees: Int) {}
    func mirrorActiveWorkspace(_ axis: MirrorAxis) {}
    func swapWindows(_ a: WindowID, _ b: WindowID) {}
    func insertWindow(_ moved: WindowID, beside target: WindowID,
                      edge: InsertEdge) {}
    func resizeWindow(_ id: WindowID, to frame: CGRect, reflowDragged: Bool) {}
    func revealWindow(_ id: WindowID) {}
    func windowFrame(_ id: WindowID) -> CGRect? { nil }
    func frontWindowFast() -> WindowID? { focusedWindow() }
    func predictedDrop(dragged: WindowID, target: WindowID,
                       zone: IntentZone) -> DropPrediction { .none }
    func markFocusedWindow(_ name: String) -> Bool { false }
    func focusMark(_ name: String) -> Bool { false }
    func unmark(_ name: String) -> Bool { false }
    func stashScratchpad(_ name: String) -> Bool { false }
    func toggleScratchpad(_ name: String) -> Bool { false }
    func releaseScratchpad(_ name: String) -> Bool { false }
    func stashedScratchpads() -> [String] { [] }
}
