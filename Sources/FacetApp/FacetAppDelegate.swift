// Minimal `NSApplicationDelegate` whose sole job is the graceful-quit
// window rescue (mechanism ① of the window-rescue feature). Both
// termination routes that go through `NSApp.terminate` land in
// `applicationShouldTerminate`:
//   - `facet --quit`  (DNC → Controller routes 'quit' → NSApp.terminate)
//   - Cmd+Q           (the App menu item → terminate:)
//
// (SIGTERM / SIGINT are deliberately NOT intercepted — see the note in
// Controller.start(); `kill` / crash recover via auto-heal / `--rescue`.)
//
// We CANCEL AppKit's own termination (`.terminateCancel`) and let the
// Controller own the exit: it restores the parked windows off the
// catalog queue (main run loop kept free → no deadlock) and then
// `exit(0)`s, with a global-queue deadman guaranteeing the process
// always dies. The `.terminateLater` + `reply(toApplicationShouldTerminate:)`
// path was tried first and proved unreliable for this `.accessory` app —
// the reply never actually terminated it, hanging `--quit`.
//
// facet otherwise has no app delegate (it sets up AppKit by hand in
// `FacetApp.main`); this one exists purely so a clean quit leaves no
// window stranded in the corner.

import AppKit
import FacetCore

@MainActor
final class FacetAppDelegate: NSObject, NSApplicationDelegate {

    weak var controller: Controller?

    func applicationShouldTerminate(_ sender: NSApplication)
        -> NSApplication.TerminateReply
    {
        guard let controller else { return .terminateNow }
        // Controller restores parked windows then `exit(0)`s itself, so
        // cancel AppKit's termination flow and let it own the exit.
        controller.restoreParkedThenExit()
        return .terminateCancel
    }
}
