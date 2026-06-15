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
    /// Leave keyboard-nav (`--active`) mode. `restore == true` means
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

    /// Double-click on the panel's top handle band — reset the panel to
    /// its `[tree]` config geometry, or the built-in default when none
    /// is configured.
    func resetPanelGeometry()

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

    /// Switch to `window`'s workspace if needed, focus it, then run
    /// `ops` against the now-focused window. Used for right-click
    /// menu items that operate on the focused window — keeps the
    /// view ignorant of the inter-op timing required for the WM to
    /// register each action before the next lands.
    func runWindowOps(_ ops: [WindowAction],
                      on window: Window,
                      workspaceIndex: Int)

    /// Open the per-window tag-edit checklist (`TagEditPanel`) for `id` —
    /// the GUI "Tag" menu item (#4, tag mode). The header mirrors the tree's
    /// window row: `pid` resolves the app icon, `appName` / `title` are its
    /// two text lines. `currentTags` seeds the checked rows; `screenPt` is
    /// where the ops menu was raised (the panel anchors there). The
    /// Controller owns the floating panel, its key focus + the activation
    /// policy dance.
    func openTagEditor(forWindow id: WindowID, pid: Int, appName: String,
                       title: String, currentTags: [String], at screenPt: CGPoint)
}
