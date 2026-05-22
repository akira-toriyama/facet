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

    /// User dragged the panel by `delta`. Controller updates the
    /// panel's frame in real time; persist happens on
    /// `persistPosition` at mouseUp.
    func movePanel(by delta: CGSize)

    /// Write current panel frame to user defaults. Called at the end
    /// of a drag (panel move or grip resize).
    func persistPosition()

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
    /// know about AX or rift's post-switch default-focus race.
    func focusWindow(_ window: Window, postSwitch: Bool)

    /// Switch to `window`'s workspace if needed, focus it, then run
    /// `ops` against the now-focused window. Used for right-click
    /// menu items that operate on the focused window — keeps the
    /// view ignorant of the inter-op timing required for the WM to
    /// register each action before the next lands.
    func runWindowOps(_ ops: [WindowAction],
                      on window: Window,
                      workspaceIndex: Int)
}
