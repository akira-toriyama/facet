// Full-screen takeover panel for the overview grid. Borderless so
// the backdrop fills the whole screen; key/main behaviour is what
// distinguishes it from `KeyablePanel` (the tree panel): the grid
// needs keys (Esc to dismiss, arrows / Space / Return for kbDnD)
// but should never sit as the main window.

import AppKit

public final class GridOverlay: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
}
