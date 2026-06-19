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
    /// `IconResolver` spec (`SF:<name>`) for the menu row, "" = no icon.
    /// Supplied by the backend so the icon↔action mapping lives next to
    /// the label that defines the op, not in a fragile view-side switch.
    public let icon: String
    /// Section label this op groups under in the popup menu (item 4):
    /// e.g. "Layout" (tiling ops) vs "Window" (float / sticky / close).
    /// The view inserts a dim section header when the section changes.
    public let section: String

    public init(_ label: String, _ ops: [WindowAction], close: Bool = false,
                icon: String = "", section: String = "Action") {
        self.label = label
        self.ops = ops
        self.isClose = close
        self.icon = icon
        self.section = section
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

/// A lens command (M11-3 tag mode). The lens is the set of tags
/// currently shown; these change it. Each verb takes one OR MORE tag
/// names (#228, comma-joined on the CLI): `only` shows exactly that set
/// (replace), `add` unions them in, `remove` strips them out, `toggle`
/// XORs each, `all` shows every tag. Names are resolved STRICTLY — one
/// undefined name rejects the whole command (no silent drop). User verbs
/// touch user bits only; emptying the lens falls back to the `_default`
/// floor (show untagged). Tag-mode only — a no-op under `by =
/// "workspace"`.
public enum LensSpec: Sendable, Equatable {
    case only([String])
    case add([String])
    case remove([String])
    case toggle([String])
    case all

    /// Parse a `lens:` DNC payload (#228) into a spec. The payload is
    /// `all` or `VERB:CSV` where VERB ∈ only/add/remove/toggle and CSV is
    /// a comma-joined tag list. Tag names can't contain `,` or `:` (the
    /// CLI's `parseTagList` forbids them), so both splits are
    /// unambiguous. Returns `nil` for a malformed payload (unknown verb,
    /// empty CSV) — the dispatcher ignores it. Pure, so the wire-format
    /// round-trip is unit-testable without the server.
    public static func parse(_ payload: String) -> LensSpec? {
        if payload == "all" { return .all }
        let parts = payload
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2 else { return nil }
        let names = parts[1].split(separator: ",").map(String.init)
        guard !names.isEmpty else { return nil }
        switch parts[0] {
        case "only":   return .only(names)
        case "add":    return .add(names)
        case "remove": return .remove(names)
        case "toggle": return .toggle(names)
        default:       return nil
        }
    }
}

/// Outcome of `facet window --retag OLD NEW` (#228, tag mode). A 4-way
/// result rather than a `Bool` so the dispatch layer surfaces a precise
/// error — `Bool` would conflate "no focused window" with "no such tag
/// OLD" and "vocabulary full".
public enum WindowRetagResult: Sendable, Equatable {
    /// Retagged: OLD replaced with NEW on the focused window (a window
    /// lacking OLD degrades to a bare add of NEW; `OLD == NEW` is a no-op
    /// success).
    case retagged
    /// No managed focused window (or not tag mode / unmanaged desktop).
    case noFocus
    /// OLD isn't a defined tag — Strict-A reject (consistent with
    /// `--untag`), never a silent degrade.
    case oldUndefined
    /// NEW would auto-vivify but the vocabulary is full (63 user tags).
    case vocabFull
}

/// The only surface the rest of the app knows about. The backend
/// adapter (`FacetAdapterNative`) implements it; the UI, AX focus
/// glue, themes and DnD are all backend-agnostic.
public protocol WindowBackend: Sendable {
    /// Short identifier shown in `facet query` and debug logs
    /// (e.g. `"native"`). Lower-case, no spaces.
    var name: String { get }

    /// Backend-defined layout-mode names that may appear on
    /// `Workspace.layoutMode` (e.g. the native adapter returns
    /// `["bsp", "stack", "master-left", …, "grid", "spiral", "float"]`).
    var layoutModes: [String] { get }

    func workspaces() -> [Workspace]
    func focusedWindow() -> WindowID?

    /// Push a freshly-loaded config to the backend (hot-reload). The
    /// adapter swaps it in on its own serialization queue so the next
    /// refresh reads the new values — gaps, animation, layout-default,
    /// exclusion rules and grouping take effect without a restart. The
    /// live workspace SET is NOT re-seeded: once seeded it's
    /// runtime-authoritative (config stays the read-only seed), so
    /// `[[desktop.N.section]]` workspace-count / layout edits still land only
    /// on restart by design.
    func updateConfig(_ config: FacetConfig)

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

    /// Change the lens (M11-3 tag mode): which set of tags is shown.
    /// Windows whose tags leave the lens are parked; windows that enter
    /// are restored + re-tiled into the visible union. No-op under
    /// `by = "workspace"` or when the named tag is unknown (the backend
    /// surfaces the latter as an operational error).
    ///
    /// `autoFocus` mirrors `switchWorkspace(toIndex:autoFocus:)`: the CLI
    /// path (`lens:` DNC, from a hotkey) wants `true` so focus lands in
    /// the new union, but the in-panel lens selector passes `false` — the
    /// user is still configuring the view, so stealing key to a window
    /// would drop the tree / lens panel out of keyboard focus mid-pick
    /// (memory [[tree-click-crossapp-focus-broken-sequoia]]).
    func setLens(_ spec: LensSpec, autoFocus: Bool)

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
    /// (90 / 180 / 270) — `facet workspace --rotate N`. No-op outside
    /// bsp mode (the tree is the only rotatable layout state) and for
    /// backends without one.
    func rotateActiveWorkspace(degrees: Int)

    /// Mirror the active workspace's bsp tree across `axis`
    /// (`facet workspace --mirror horizontal|vertical`). Same bsp-only
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

    /// Called once when a real-window resize gesture fully ends (any
    /// outcome — resize settle, move, or unread frame). Lets the adapter
    /// drop any per-drag state (e.g. the live-follow AX-element cache) so
    /// nothing leaks into the next gesture. Runs on the gesture's cliQueue.
    func endLiveResize()

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
    /// (`facet window --mark NAME`). 1:1: the name's old window and the
    /// focused window's old mark are both cleared. Returns `false` when
    /// there is no focused window (caller surfaces the error).
    func markFocusedWindow(_ name: String) -> Bool

    /// Jump focus to the window holding mark `name`
    /// (`facet window --focus-mark NAME`), switching workspace if it
    /// lives on another one. Returns `false` when the mark is unset or
    /// its window has since closed (caller surfaces the error).
    func focusMark(_ name: String) -> Bool

    /// Remove mark `name` (`facet window --unmark NAME`). Returns
    /// `false` when the name wasn't set (caller surfaces the error).
    func unmark(_ name: String) -> Bool

    /// Add tag `name` to the focused window (`facet window --tag NAME`,
    /// tag mode). Auto-vivifies an unknown name: creates it in the
    /// session tag vocabulary, then assigns. Returns `false` when there
    /// is no managed focused window, the run isn't in tag mode, or the
    /// vocabulary is full (63 user tags). Caller surfaces the error.
    func addTagToFocusedWindow(_ name: String) -> Bool

    /// Remove tag `name` from the focused window
    /// (`facet window --untag NAME`, tag mode). Strict: rejects an
    /// unknown name. The `_default` floor is never removed. Returns
    /// `false` when there is no focused window, the run isn't in tag
    /// mode, or `name` isn't a defined tag.
    func removeTagFromFocusedWindow(_ name: String) -> Bool

    /// Toggle tag `name` on the focused window
    /// (`facet window --toggle-tag NAME`, tag mode). Auto-vivifies an
    /// unknown name (then sets it). Returns `false` for the same
    /// reasons as `addTagToFocusedWindow`.
    func toggleTagOnFocusedWindow(_ name: String) -> Bool

    /// Retag the focused window: replace tag `old` with `new` in a single
    /// atomic mask write (`facet window --retag OLD NEW`, tag mode).
    /// `old` must be DEFINED (Strict-A); `new` auto-vivifies. See
    /// `WindowRetagResult` for the precise outcomes the caller messages.
    func retagFocusedWindow(old: String, new: String) -> WindowRetagResult

    /// Add tag `name` to a SPECIFIC window `id` (the GUI tag menu's
    /// "Tag…" item, tag mode). Like `addTagToFocusedWindow` but targets
    /// an explicit window — the right-clicked row, which need not be
    /// focused — so it never changes focus. Auto-vivifies an unknown
    /// name. Returns `false` when `id` isn't a managed window, the run
    /// isn't in tag mode, or the vocabulary is full.
    func addTag(_ name: String, toWindow id: WindowID) -> Bool

    /// Remove tag `name` from a SPECIFIC window `id` (the GUI tag menu's
    /// "Untag #NAME" item, tag mode). Strict — rejects an unknown or
    /// reserved name; the `_default` floor is never removed. Returns
    /// `false` when `id` isn't managed, not tag mode, or `name` isn't a
    /// defined tag on that window's vocabulary.
    func removeTag(_ name: String, fromWindow id: WindowID) -> Bool

    // MARK: - Section-model apply/un-apply (PR8)

    /// ABSOLUTE, focus-free by-`WindowID` mutators driven by the tree's
    /// section-path apply/un-apply DnD (the `ApplyOp` set). Unlike the
    /// `perform(.toggle*)` gestures these target an arbitrary managed window,
    /// are idempotent (set an absolute value, never flip), and skip lens
    /// park/restore (the section model is the by-workspace axis). No-op
    /// outside the section model (the native impl gates on
    /// `isSectionModelActive`); the protocol defaults are no-ops so other
    /// backends need not implement them.
    func setFloating(_ id: WindowID, _ floating: Bool)
    func setSticky(_ id: WindowID, _ sticky: Bool)
    func setMaster(_ id: WindowID, _ master: Bool)

    /// Set / clear a tag bit on a SPECIFIC window WITHOUT lens park/restore
    /// (section-model apply / un-apply). `addTagSection` auto-vivifies +
    /// keeps the `_default` floor; `removeTagSection` is strict. Both return
    /// `false` on unknown window / vocab-full (add) / unknown name (remove).
    func addTagSection(_ name: String, toWindow id: WindowID) -> Bool
    func removeTagSection(_ name: String, fromWindow id: WindowID) -> Bool

    /// Define tag `name` in the session vocabulary without attaching it
    /// to any window (`facet tag --add NAME`, tag mode). Idempotent — a
    /// defined name is a no-op success. Returns `false` only when not in
    /// tag mode / unmanaged, or the vocabulary is full (63 user tags).
    func addTag(_ name: String) -> Bool

    /// Remove tag `name` from the vocabulary, stripping its bit from
    /// every window (`facet tag --remove NAME`, tag mode). The freed bit
    /// becomes reusable by a later add; windows keep the `_default`
    /// floor. Returns `false` when not in tag mode / unmanaged, or
    /// `name` is unknown / reserved.
    func removeTag(_ name: String) -> Bool

    /// Rename tag `old` to `new` in place (`facet tag --rename OLD NEW`,
    /// tag mode) — the bit is unchanged, so windows keep their tag
    /// membership. Returns `false` when not in tag mode / unmanaged,
    /// `old` is unknown, or `new` is already a defined tag.
    func renameTag(_ old: String, to new: String) -> Bool

    /// Stash the focused window onto scratchpad shelf `name`, parking
    /// it off-screen (`facet scratchpad --stash NAME`). A named hidden
    /// shelf, 1:1 like marks; clears any sticky (XOR), force-floats and
    /// detaches the window. Returns `false` when there is no managed
    /// focused window (caller surfaces the error).
    func stashScratchpad(_ name: String) -> Bool

    /// Toggle scratchpad shelf `name` (`facet scratchpad --toggle NAME`):
    /// if its window is *visible on the current workspace*, re-park it to
    /// the shelf; otherwise (stashed, or settled on another WS) summon it
    /// onto the current workspace as a floating overlay. Returns `false`
    /// when the shelf is unset / its window has closed.
    func toggleScratchpad(_ name: String) -> Bool

    /// Release shelf `name` (`facet scratchpad --release NAME`): drop it
    /// from the shelf and re-home the window as a normal tiled window of
    /// the current workspace (same landing as un-sticky). Returns `false`
    /// when the shelf is unset.
    func releaseScratchpad(_ name: String) -> Bool

    /// Names of currently *stashed* scratchpad shelves (for
    /// `facet query`). Settled (summoned) shelves are excluded — they
    /// show in the tree under their workspace. Empty when none.
    func stashedScratchpads() -> [String]

    /// The defined tag VOCABULARY in declaration order (`facet query
    /// --tags`, #228). `[]` outside tag mode. A cheap main-actor catalog
    /// read, same risk class as `stashedScratchpads()` — the Controller
    /// folds it into the status snapshot on reconcile.
    func definedTagNames() -> [String]

    /// The current lens (`facet query --lens`, #228). `nil` outside tag
    /// mode (the lens is a tag-mode concept). Same cheap main-actor
    /// read as `definedTagNames()`.
    func currentLens() -> LensStatus?

    /// Per-window facet management state for `facet query --windows`
    /// (#223), keyed by window id, across the active + parked catalogs.
    /// Reads the in-memory catalog structs, so the Controller calls it on
    /// the **main actor** (where the DNC dispatch also mutates them — a
    /// quick read there, same risk class as `stashedScratchpads()`), then
    /// hands the immutable result to ``queryEntries(facetStates:)``.
    /// Empty when nothing is managed.
    func queryFacetStates() -> [WindowID: WindowQueryEntry.FacetWindowState]

    /// Every window the window server reports, flattened for
    /// `facet query --windows` (#223): raw properties + the facet state
    /// from `facetStates` (or `nil` when unmanaged), across ALL mac
    /// desktops (visited or not). Read-only / SIP-on; no side-effects.
    /// Heavy (a full `CGWindowList` + SkyLight + AX-title sweep) and
    /// touches **no** catalog state — the Controller calls it off-main on
    /// `cliQueue`. Empty when the backend has nothing to report.
    func queryEntries(facetStates:
        [WindowID: WindowQueryEntry.FacetWindowState]) -> [WindowQueryEntry]

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
    /// message into `facet query`'s lastError slot.
    ///
    /// Single-subscriber, same lifetime as `events`. Adapters
    /// only push messages a *user* could act on — internal
    /// debugging chatter belongs in `Log.debug` instead.
    var errors: AsyncStream<String> { get }

    /// True while a cosmetic slide animation is in flight (P6). The
    /// Controller skips its poll-driven refresh while this holds so a
    /// reconcile-triggered re-tile can't AX-fight the in-flight tween; the
    /// slide's settle yields a fresh refresh when it lands. Read on the
    /// main actor (set/cleared there too). Defaults to `false` for backends
    /// without animation.
    var isAnimating: Bool { get }
}

public extension WindowBackend {
    var isAnimating: Bool { false }

    /// Default no-op: a backend that doesn't hot-reload config (the
    /// test stub, future backends) needs no implementation.
    func updateConfig(_ config: FacetConfig) {}

    /// Convenience for callers that don't care about auto-focus
    /// (the majority). Keeps the call sites that already follow
    /// up with `Focus.assert` etc. terse.
    func switchWorkspace(toIndex index: Int) {
        switchWorkspace(toIndex: index, autoFocus: false)
    }

    /// Convenience: lens change WITH auto-focus (the CLI default). The
    /// in-panel selector calls the two-arg form with `autoFocus: false`.
    func setLens(_ spec: LensSpec) {
        setLens(spec, autoFocus: true)
    }

    // Default no-ops so backends that don't support a dynamic
    // workspace set (and the unit-test stub) need not implement
    // these. The native adapter overrides all of them.
    func switchWorkspace(named name: String, autoFocus: Bool) {}
    func setLens(_ spec: LensSpec, autoFocus: Bool) {}
    func addWorkspace() {}
    func removeWorkspace(at position: Int?) {}

    func renameWorkspace(at position: Int?, to name: String) {}
    func moveActiveWorkspace(to position: Int) {}
    func balanceActiveWorkspace() {}
    func rotateActiveWorkspace(degrees: Int) {}
    func mirrorActiveWorkspace(_ axis: MirrorAxis) {}
    func swapWindows(_ a: WindowID, _ b: WindowID) {}
    func insertWindow(_ moved: WindowID, beside target: WindowID,
                      edge: InsertEdge) {}
    func resizeWindow(_ id: WindowID, to frame: CGRect, reflowDragged: Bool) {}
    func endLiveResize() {}
    func revealWindow(_ id: WindowID) {}
    func windowFrame(_ id: WindowID) -> CGRect? { nil }
    func predictedDrop(dragged: WindowID, target: WindowID,
                       zone: IntentZone) -> DropPrediction { .none }
    func markFocusedWindow(_ name: String) -> Bool { false }
    func focusMark(_ name: String) -> Bool { false }
    func unmark(_ name: String) -> Bool { false }
    func addTagToFocusedWindow(_ name: String) -> Bool { false }
    func removeTagFromFocusedWindow(_ name: String) -> Bool { false }
    func toggleTagOnFocusedWindow(_ name: String) -> Bool { false }
    func retagFocusedWindow(old: String, new: String) -> WindowRetagResult {
        .noFocus
    }
    func addTag(_ name: String, toWindow id: WindowID) -> Bool { false }
    func removeTag(_ name: String, fromWindow id: WindowID) -> Bool { false }
    func setFloating(_ id: WindowID, _ floating: Bool) { }
    func setSticky(_ id: WindowID, _ sticky: Bool) { }
    func setMaster(_ id: WindowID, _ master: Bool) { }
    func addTagSection(_ name: String, toWindow id: WindowID) -> Bool { false }
    func removeTagSection(_ name: String, fromWindow id: WindowID) -> Bool { false }
    func addTag(_ name: String) -> Bool { false }
    func removeTag(_ name: String) -> Bool { false }
    func renameTag(_ old: String, to new: String) -> Bool { false }
    func stashScratchpad(_ name: String) -> Bool { false }
    func toggleScratchpad(_ name: String) -> Bool { false }
    func releaseScratchpad(_ name: String) -> Bool { false }
    func stashedScratchpads() -> [String] { [] }
    func definedTagNames() -> [String] { [] }
    func currentLens() -> LensStatus? { nil }
    func queryFacetStates() -> [WindowID: WindowQueryEntry.FacetWindowState] { [:] }
    func queryEntries(facetStates:
        [WindowID: WindowQueryEntry.FacetWindowState]) -> [WindowQueryEntry] { [] }
}
