// Controller surface needed by the tree view.
//
// `SidebarView` and `GripView` hold a `weak var controller:
// TreeController?` and call these methods for orchestration that
// the view itself can't do alone (panel positioning, persistence,
// preview reconcile timing, grip-resize gating).
//
// Defined in FacetViewTree so the view module owns its protocol;
// `FacetApp.Controller` (step 6) imports FacetViewTree and conforms.

import CoreGraphics
import Foundation

@MainActor
public protocol TreeController: AnyObject {
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

    /// Grip drag started — controller pauses background
    /// refresh/apply ticks for the duration. Without this gate, a
    /// refresh landing between two mouseDragged events can stomp
    /// the panel height the next drag tick was about to read
    /// (memory: grid-branch-grip-intermittent).
    func gripResizeBegan()

    /// Grip drag ended — controller persists the new size and runs
    /// a single refresh to catch up on events skipped during the
    /// drag.
    func gripResizeEnded()

    /// Per-mouseDragged-event resize delta from the grip. `dx` /
    /// `dy` come straight from `NSEvent`.
    func resizeBy(dx: CGFloat, dy: CGFloat)
}
