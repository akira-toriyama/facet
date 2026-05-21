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

    // Without this, the first click on a non-key panel only promotes
    // the panel to key — mouseDown never reaches the view, so the
    // user has to click twice before resize starts working.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // For NSPanel with becomesKeyOnlyIfNeeded=true, a mouseDown only
    // routes mouseDragged/mouseUp to a view if that view returns true
    // from BOTH acceptsFirstResponder and needsPanelToBecomeKey.
    // Without these the grip catches mouseDown but the drag stream
    // never arrives — resize feels "intermittently dead".
    public override var acceptsFirstResponder: Bool { true }
    public override var needsPanelToBecomeKey: Bool { true }

    // addCursorRect alone relies on AppKit's key-window polling, which
    // gets unreliable on .nonactivatingPanel / LSUIElement agents.
    // SidebarView uses NSTrackingArea + NSCursor.set() for the same
    // reason ([Sources/FacetViewTree/SidebarView.swift:262]) — mirror
    // that so the resize cursor actually shows over the grip.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect,
                      .mouseMoved, .mouseEnteredAndExited],
            owner: self))
    }

    // push/pop instead of set: SidebarView covers the same window
    // pixels (it's the scroll's documentView, panel-wide) and its
    // mouseMoved sets arrow/pointingHand whenever its tracking area
    // fires too. With set() the two views fight per-event and the
    // resize cursor flickers. push() puts nwse on top of the stack
    // so it stays visible even when SidebarView pushes arrow under it.
    private var pushed = false

    public override func mouseEntered(with e: NSEvent) {
        if !pushed { NSCursor.nwse.push(); pushed = true }
    }

    public override func mouseExited(with e: NSEvent) {
        if pushed && !resizing { NSCursor.pop(); pushed = false }
    }

    public override func draw(_ dirty: NSRect) {
        pal.accent.setStroke()
        let p = NSBezierPath()
        p.lineWidth = 2.0
        let b = bounds
        // Chevron at the grip's bottom-right (= visual edge of the
        // hit area). The grip's *frame* is already shifted left by
        // PanelHost.scrollerInset so this position sits just left of
        // the overlay scrollbar — guarantees visual == hit target.
        let edge: CGFloat = 4
        for off in [CGFloat(4), 10, 16] {
            p.move(to: NSPoint(x: b.maxX - off,  y: b.minY + edge))
            p.line(to: NSPoint(x: b.maxX - edge, y: b.minY + off))
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
    }

    public override func mouseDragged(with e: NSEvent) {
        guard resizing else { return }
        controller?.resizeBy(dx: e.deltaX, dy: e.deltaY)
    }

    public override func mouseUp(with e: NSEvent) {
        guard resizing else { return }
        resizing = false
        // If mouseExited was deferred during resize, pop now.
        if pushed { NSCursor.pop(); pushed = false }
        // gripResizeEnded persists the position AND runs a single
        // refresh so any backend events skipped during the drag
        // land now.
        controller?.gripResizeEnded()
    }
}
