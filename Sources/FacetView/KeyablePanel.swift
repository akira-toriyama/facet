// Panel that can take keyboard input on demand.
//
// A borderless `.nonactivatingPanel` reports `canBecomeKey == false`,
// so it can never receive key events. We only make it key explicitly
// (the `--active` keyboard-nav mode); the rest of the time it stays
// non-activating and never steals focus from the user's frontmost
// app.

import AppKit

public final class KeyablePanel: NSPanel {
    /// The panel may become key ONLY when explicitly entering keyboard
    /// nav (`--active`), which sets this true via `PanelHost.makeKey()`.
    /// A plain tree-row click must NOT make the panel key: if it did,
    /// facet's own panel would hold the key window and no public-AX call
    /// could move the keyboard focus to the clicked window of an
    /// already-frontmost app — that was the same-app focus bug. (This is
    /// exactly why AeroSpace, which has no key-grabbing panel, can focus
    /// same-app windows with plain public AX and facet previously
    /// couldn't.)
    public var wantsKey = false
    public override var canBecomeKey: Bool { wantsKey }
    public override var canBecomeMain: Bool { true }
}
