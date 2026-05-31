// Full-screen takeover panel for the workspace rail. Borderless so
// the near-black backdrop fills the whole screen; becomes key (like
// the grid overlay, NOT like the passive tree panel) so Escape and —
// later — keyboard navigation reach it. Never sits as the main window.

import AppKit

public final class RailOverlay: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
}
