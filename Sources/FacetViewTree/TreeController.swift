// Controller surface needed by the tree view.
//
// `SidebarView` holds a `weak var controller: TreeController?` and
// calls these methods for orchestration that the view itself can't
// do alone (panel positioning, persistence, preview reconcile
// timing).
//
// Defined in FacetViewTree so the view module owns its protocol;
// `FacetApp.Controller` (step 6) imports FacetViewTree and conforms.

import CoreGraphics
import Foundation
import FacetCore

@MainActor
public protocol TreeController: AnyObject, Sendable {
    /// Enter keyboard-nav mode: make the panel key + flip the app to
    /// `.regular` so ↑↓ / Enter / s / m fire. Used by the summon path and
    /// (R12) by an explicit click on a PASSIVE tree — the user-initiated
    /// recovery after a mac-desktop switch leaves the panel visible but
    /// keyboard-dead (facet never auto-grabs key on a switch; a click does).
    func enterActive()

    /// Leave keyboard-nav mode. `restore == true` means
    /// the user dismissed without picking anything; the controller
    /// re-focuses the previously-frontmost app. `false` means a
    /// selection was made — the controller has already focused the
    /// target and shouldn't second-guess.
    func exitActive(restore: Bool)

    /// The user finished dragging the panel. The live move is driven by
    /// the window server (NSWindow.performDrag(with:)), so the view layer
    /// does no per-event frame writes; this is the one post-drag callback.
    /// Controller re-derives the persisted top-left anchor from the
    /// panel's final frame and re-syncs the pet overlay. Session-only —
    /// the position isn't persisted (it seeds from `[tree]` config each
    /// launch).
    func syncPanelAfterDrag()

    /// A row that owns a window preview has changed (hover moved,
    /// selection shifted). Controller debounces these into a single
    /// preview-overlay reconcile.
    func previewTargetChanged()

    /// Schedule a backend refresh + view reconcile after `delay`.
    /// Coalesces against any pending reconcile (debounce).
    func scheduleReconcile(after delay: TimeInterval)

    /// Move precise focus to `window`. Controller picks the retry
    /// strategy: bounded short retry for same-workspace clicks,
    /// persistent assertion until the backend confirms for
    /// cross-workspace clicks (`postSwitch == true`). View doesn't
    /// know about AX or the backend's post-switch default-focus race.
    func focusWindow(_ window: Window, postSwitch: Bool)


    /// Activate a section (EX-1 throughline) — a workspace (clears any active
    /// lens) or a `type=lens` section. The header / cell click routes here
    /// (not straight to the backend) so the Controller updates its
    /// `currentActiveSection` highlight mirror up-front: a same-workspace click
    /// while a lens is active clears the lens via the adapter's same-index edge,
    /// and without the Controller-side mirror update that stale `.lens(…)` would
    /// swallow the next lens activation.
    func activateSection(_ section: ActiveSection, autoFocus: Bool)

    /// Switch to `window`'s workspace if needed, focus it, then run
    /// `ops` against the now-focused window. Used for right-click
    /// menu items that operate on the focused window — keeps the
    /// view ignorant of the inter-op timing required for the WM to
    /// register each action before the next lands.
    func runWindowOps(_ ops: [WindowAction],
                      on window: Window,
                      workspaceIndex: Int)

    /// Section/lens model (PR6 / §A): the user clicked a `type=lens` section
    /// header in the tree. TOGGLE it as the active lens — activate the section
    /// `sectionID` (`ProjectedSection.id`), or clear if it is already active.
    /// Keyed on the stable id, not the display label, so a non-unique / empty
    /// label can't toggle the wrong lens. No-op outside the section model.
    func toggleActiveLens(_ sectionID: String)

    /// §G: the user clicked an `type=unassigned` section header (or its grid /
    /// rail cell, or `section --focus`d it). FOCUS ITS FIRST orphan window — no
    /// lens toggle, no workspace switch (unassigned has neither behind it). The
    /// Controller looks the section up by stable id, reveals + focuses
    /// `.windows.first` via the existing window path; an empty / missing
    /// section is loud-but-non-fatal. The unified §G focus helper, shared with
    /// the grid/rail `.unassigned` picks + the CLI `--focus` path.
    func focusFirstWindow(inSectionID id: String)

    /// Section-model apply/un-apply MOVE (PR8): un-apply the SOURCE section's
    /// additive tags, then apply the DEST section's ops (workspace dest → move
    /// by index; lens dest → addTag / setFloating / setSticky / setMaster).
    /// The view passes section IDs (`ProjectedSection.id`) + the dest section's
    /// `sourceWorkspaceIndex` (a workspace dest's relocation target); the
    /// Controller resolves the apply via the live section config + the pure
    /// `ApplyResolver` (a `ProjectedSection` carries no apply ops). An inert /
    /// stale / non-satisfying drop runs NO backend op — the tree row was
    /// never hidden during the drag, so doing nothing IS the snap-back.
    /// No-op outside the section model.
    func applyMove(windowID: WindowID, fromSectionID: String,
                   toSectionID: String, destSourceWorkspaceIndex: Int?)

    /// Per-window tag editing (R10): open the tag checklist panel for the
    /// window `windowID` (the ops-menu "Tag…" item). The controller owns the
    /// keyable `TagEditPanel` + the activation dance, computes the in-use tag
    /// union + this window's tags from the live snapshot, and maps the panel's
    /// toggle / create callbacks to `backend.addTag` / `removeTag`. `pid` /
    /// `title` feed the panel header. `anchor` is the menu's screen point (the
    /// row's level — the `m` height), so the panel opens where the context menu
    /// was. No-op outside the section model.
    func openTagEditor(pid: Int, windowID: WindowID, title: String, at anchor: CGPoint)

    /// Section label rename (§E): the user picked the header menu's
    /// `SECTION ▸ Rename` row for the section at render group `g`. The
    /// controller resolves `g` to the same 1-based index + current display
    /// label `sectionHeaderDisplay(group:)` shows, opens the keyable inline
    /// editor pre-filled with that label, and on commit routes to the shared
    /// rename entry (workspace → backend name; lens / §G unassigned →
    /// display-only override; empty → revert). No-op for an out-of-range
    /// group. `anchor` is the right-click screen point
    /// (the clicked header's height) — the editor opens beside the tree at
    /// that y, not pinned to the tree top.
    func beginSectionRename(group g: Int, at anchor: CGPoint)

    /// t-0020: lens-match live edit — the user picked a LENS header's
    /// `SECTION ▸ Edit match` row (or pressed `m` on it) at render group `g`.
    /// The controller opens the same keyable inline editor as `beginSectionRename`,
    /// pre-filled with the lens's current effective predicate, and on commit sets
    /// a session-only `match` override (the GUI twin of `facet section --match`);
    /// the lens re-filters at once. LENS-only (no-op for any other kind / an
    /// out-of-range group). `anchor` is the header's screen point.
    func beginSectionMatchEdit(group g: Int, at anchor: CGPoint)

    /// Section drag-to-reorder (display-only, session-only): move the section
    /// `sectionID` to insertion BOUNDARY `boundary` (current display-list
    /// coords; `0` = before first, `count` = after last) on the active mac
    /// desktop. No window moves, no config write — a relaunch resets to config
    /// order. A no-op drop (own-slot boundary) commits nothing.
    func reorderSection(move sectionID: String, toBoundary boundary: Int)
}
