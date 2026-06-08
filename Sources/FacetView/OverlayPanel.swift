// Shared factory for the borderless, click-through overlay panels used
// by the tree's hover preview (`PreviewOverlay`) and the real-window
// DnD prediction (`DndPredictionOverlay`). Both build the identical
// `.nonactivatingPanel` at `.statusBar`; this keeps that one recipe in
// a single place. The caller sets `contentView` after construction.
//
// Never key / never active: the facet panel sits above `.statusBar`,
// so it stays fully operable on top of these overlays.

import AppKit

public extension NSPanel {
    /// A borderless, click-through, never-key overlay panel at
    /// `.statusBar`. `hasShadow` is the only knob that differs between
    /// the two consumers (the hover preview casts one; the DnD veil
    /// does not).
    @MainActor
    static func clickThroughOverlay(hasShadow: Bool) -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = hasShadow
        p.ignoresMouseEvents = true       // click-through
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary]
        return p
    }
}
