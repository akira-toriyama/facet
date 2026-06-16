// Full-screen takeover panel shared by the overview grid and rail.
// Borderless so the backdrop fills the whole screen; key/main behaviour
// is what distinguishes it from `KeyablePanel` (the passive tree panel):
// an overview needs keys (Esc to dismiss, arrows / Space / Return for
// keyboard nav + DnD) but must never sit as the main window.
//
// Was duplicated byte-for-byte as `GridOverlay` (FacetViewGrid) and
// `RailOverlay` (FacetViewRail); the grid/rail are the same "overview"
// surface, so one panel subclass serves both.

import AppKit

public final class OverviewPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
}
