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

    /// The full-screen overview overlay both the grid and the rail
    /// build. Borderless + nonactivating, floats just above the tree
    /// panel, clear/non-opaque (the view paints its own backdrop), and
    /// joins every Space so it survives a mac-desktop switch. Was
    /// byte-identical setup in `showGrid` / `showRail`.
    public static func fullScreen(_ frame: NSRect) -> OverviewPanel {
        let p = OverviewPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 2)   // above tree
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary]
        return p
    }
}
