// Panel that can take keyboard input on demand.
//
// A borderless `.nonactivatingPanel` reports `canBecomeKey == false`,
// so it can never receive key events. We only make it key explicitly
// (the `--active` keyboard-nav mode); the rest of the time it stays
// non-activating and never steals focus from the user's frontmost
// app.

import AppKit

public final class KeyablePanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}
