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

    /// Tag-unification Phase 1 (PR4): the user clicked an out-of-lens
    /// (parked, dimmed `lens`-badged) window row. Drop the active
    /// section-lens — restoring EVERY parked window into its layout — then
    /// focus `window`. Called ONLY for a parked window on the ACTIVE workspace
    /// (no switch needed); EX-0's cross-workspace lens means a parked row can
    /// live in an inactive WS, but `handleClick` routes that case through
    /// `activateSection(.workspace(…))` instead (the switch clears the lens +
    /// makes the window visible). Reuses the `lens --clear` path; the restore
    /// and the focus both ride the serial CLI queue, so the window is back in
    /// its tile before focus lands.
    func revealLensParked(_ window: Window)

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

    /// Section/lens model (PR6): the user clicked a `type=lens` section
    /// header in the tree. TOGGLE it as the active lens — activate `label`,
    /// or clear if it is already active. The controller validates against
    /// the live section config (an unknown label is a no-op) and re-renders
    /// so the active lens's header lights up. No-op outside the section model.
    func toggleActiveLens(_ label: String)

    /// Section/lens model: the user picked a union layout from a `type=lens`
    /// header's `m` / right-click menu. ACTIVATE the lens `label` (if it isn't
    /// already the active section) so the backend's `setLayoutMode` lens branch
    /// targets THIS lens's cross-workspace union, then set `mode` as the union
    /// layout (session-only, like the CLI). `mode` is always one the view took
    /// from the stateless-only lens picker; the backend re-clamps regardless.
    /// No-op outside the section model.
    func setLensLayout(label: String, mode: String)

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
    /// `title` feed the panel header. No-op outside the section model.
    func openTagEditor(pid: Int, windowID: WindowID, title: String)

    /// Section drag-to-reorder (display-only, session-only): move the section
    /// `sectionID` to insertion BOUNDARY `boundary` (current display-list
    /// coords; `0` = before first, `count` = after last) on the active mac
    /// desktop. No window moves, no config write — a relaunch resets to config
    /// order. A no-op drop (own-slot boundary) commits nothing.
    func reorderSection(move sectionID: String, toBoundary boundary: Int)
}
