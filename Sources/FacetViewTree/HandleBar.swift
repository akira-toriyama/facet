// The pinned "Desktop N" band at the top of the tree panel — the
// panel's drag-to-move grip plus the mac-desktop label. It used to be
// row 0 of the scrolling `SidebarView`, which meant a long workspace
// list scrolled the only panel-move handle off-screen. Extracted into
// its own view that PanelHost keeps OUTSIDE the scroll view (a sibling
// in the chrome) and pins to the top, so it stays put while the list
// scrolls under it.
//
// Drawing mirrors the old case-0 paint (grip dots + label + a hairline
// bottom divider). Dragging hands off to the window server via
// `performDrag(with:)` — the same native panel-move path the empty
// area uses (see #201); double-click resets the panel geometry.

import AppKit
import FacetView

@MainActor
public final class HandleBar: NSView {
    /// Mac-desktop ordinal shown as "Desktop N"; nil → blank (SkyLight
    /// unavailable). Set by PanelHost from `SidebarView`'s resolved value.
    public var ordinal: Int? {
        didSet { if ordinal != oldValue { needsDisplay = true } }
    }

    /// Double-click → reset the panel to its `[tree]` config geometry.
    /// Wired by the Controller (PanelHost has no `config`/reset logic).
    public var onResetGeometry: (() -> Void)?

    /// Right-click → the panel-level ("Desktop N") context menu, the third
    /// right-click surface alongside the workspace-header and window-row
    /// menus. HandleBar only reports the screen-space click point; the
    /// Controller builds + shows the themed menu (it owns config / palette
    /// / the search + tag-manage entries). Wired by the Controller.
    public var onContextMenu: ((NSPoint) -> Void)?

    /// Height the band reserves at the panel top; PanelHost insets the
    /// scroll view below it. Matches the old scrolling handle-row height.
    public static let height: CGFloat = handleRowH

    private var hot = false
    public override var isFlipped: Bool { true }

    /// Per-surface palette (PR-B). Wired by PanelHost to the tree box.
    public var paletteBox: PaletteBox!
    var pal: ResolvedPalette { paletteBox.pal }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    public required init?(coder: NSCoder) { nil }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    public override func mouseEntered(with e: NSEvent) {
        hot = true; needsDisplay = true; NSCursor.openHand.set()
    }
    public override func mouseExited(with e: NSEvent) {
        hot = false; needsDisplay = true; NSCursor.arrow.set()
    }

    public override func mouseDown(with e: NSEvent) {
        // Double-click resets panel geometry; otherwise a drag moves the
        // panel via the window server (same native path as the empty
        // area). A bare click is a harmless no-op (performDrag with no
        // motion just returns).
        if e.clickCount == 2 { onResetGeometry?(); return }
        window?.performDrag(with: e)
    }

    public override func rightMouseDown(with e: NSEvent) {
        guard let scr = window?.convertPoint(toScreen: e.locationInWindow)
        else { return }
        onContextMenu?(scr)
    }

    public override func draw(_ dirty: NSRect) {
        // Grip + "Desktop N" centred in the zone above a hairline divider
        // that sits `dividerPadBelow` up from the bottom edge.
        let dividerPadBelow: CGFloat = 6
        let zoneH = bounds.height - dividerPadBelow
        drawGripDots(in: NSRect(x: rowPadX, y: (zoneH - 12) / 2,
                                width: headerGripW, height: 12),
                     tallExtent: 14,
                     color: hot ? pal.primary : pal.muted,
                     alpha: hot ? 0.85 : 0.45)
        let th: CGFloat = 18
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let label = ordinal.map { "Desktop \($0)" } ?? ""
        (label as NSString).draw(
            in: NSRect(x: rowPadX + headerGripW + 7, y: (zoneH - th) / 2,
                       width: bounds.width - (rowPadX * 2 + headerGripW + 7),
                       height: th),
            withAttributes: [.font: uiFont(13, .bold),
                             .foregroundColor: pal.foreground,
                             .kern: 0.5, .paragraphStyle: para])
        let lineY = bounds.height - dividerPadBelow
        pal.border.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: rowPadX, y: lineY))
        sep.line(to: NSPoint(x: bounds.width - rowPadX, y: lineY))
        sep.lineWidth = 1
        sep.stroke()
    }
}
