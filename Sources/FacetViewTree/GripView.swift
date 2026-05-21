// Diagonal resize grip in the bottom-right corner of the sidebar
// panel. Tiny chevron drawn on top; resize math is the controller's
// responsibility (it owns the panel frame).

import AppKit
import FacetView

extension NSCursor {
    /// Diagonal resize cursor (private; falls back to crosshair on
    /// macOS releases where the private symbol moves or vanishes).
    static var nwse: NSCursor {
        (NSCursor.value(forKey: "_windowResizeNorthWestSouthEastCursor")
            as? NSCursor) ?? .crosshair
    }
}

public final class GripView: NSView {
    public weak var controller: TreeController?

    public override init(frame: NSRect) {
        super.init(frame: frame)
    }
    public required init?(coder: NSCoder) { nil }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .nwse)
    }

    public override func draw(_ dirty: NSRect) {
        pal.dim.withAlphaComponent(0.8).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.5
        let b = bounds
        for off in [CGFloat(3), 7, 11] {
            p.move(to: NSPoint(x: b.maxX - off, y: b.minY + 3))
            p.line(to: NSPoint(x: b.maxX - 3, y: b.minY + off))
        }
        p.stroke()
    }

    // Resize via AppKit event dispatch (mouseDragged / mouseUp
    // routed to the view that captured mouseDown) instead of a
    // `win.nextEvent(matching:)` tracking loop. The sync-loop
    // pattern requires the window to be pumping events through its
    // own queue — for our `.nonactivatingPanel` (non-key,
    // LSUIElement agent) drag events don't reliably show up there,
    // so the loop never advances past mouseDown and the grip is
    // silently dead. Plain overrides Just Work for any window.
    private var resizing = false

    public override func mouseDown(with e: NSEvent) {
        resizing = true
        // Controller gates background refresh/apply ticks until
        // mouseUp — fixes the "intermittent grip resize" race where
        // a layout pass from a refresh tick lands between two
        // mouseDragged events and stomps on the panel height the
        // next drag tick was about to read. Memory:
        // [[grid-branch-grip-intermittent]].
        controller?.gripResizeBegan()
        NSCursor.nwse.set()
    }

    public override func mouseDragged(with e: NSEvent) {
        guard resizing else { return }
        controller?.resizeBy(dx: e.deltaX, dy: e.deltaY)
        NSCursor.nwse.set()
    }

    public override func mouseUp(with e: NSEvent) {
        guard resizing else { return }
        resizing = false
        // gripResizeEnded persists the position AND runs a single
        // refresh so any backend events skipped during the drag
        // land now.
        controller?.gripResizeEnded()
        NSCursor.arrow.set()
    }
}
