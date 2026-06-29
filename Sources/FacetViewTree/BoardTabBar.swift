// The board tab bar (t-wrd2 / W2.4) — a pinned chrome band below the
// "Desktop N" HandleBar that switches which `[[desktop.N.tab]]` board the tree
// shows. Shown ONLY when the active mac desktop has ≥2 boards (a flat / single-
// board config gets no bar — zero new chrome, byte-identical to today). A board
// switch is a pure DISPLAY re-grouping of the SAME windows (it routes through
// the same `facet board --focus` path), never a real window move.
//
// Interaction (modelled on the rail, the other facet board-ish switcher):
//   • click a tab            → switch to that board
//   • scroll-wheel / swipe   → cycle boards (one step per `boardTabWheelStep`)
//   • both commit immediately — a board switch is display-only and cheap, so
//     there is no rail-style browse-then-commit cursor.
// Layout/​geometry is the pure `boardTabLayout` (FacetCore): tabs sit at their
// intrinsic width when they fit (the v1 2-3 board case), else shrink uniformly.
//
// DnD: the bar does NOT participate — a tree row dragged onto a tab does
// nothing (boards are independent worlds; cross-board moves aren't a drag
// gesture). Tab reordering is deferred.

import AppKit
import FacetCore
import FacetView

@MainActor
public final class BoardTabBar: NSView {
    /// The board captions in display (config) order — `DesktopTab.displayLabel`.
    /// Index in this array IS the 0-based board index `selectedBoard` keys on.
    public var boardLabels: [String] = [] {
        didSet { if boardLabels != oldValue { needsDisplay = true } }
    }
    /// The currently-shown board's 0-based index.
    public var activeBoardIndex: Int = 0 {
        didSet { if activeBoardIndex != oldValue { needsDisplay = true } }
    }

    /// Click / wheel asks the Controller to switch to this 0-based board. The
    /// Controller commits (`selectedBoard`) + re-renders, feeding the new
    /// `activeBoardIndex` back — so this is intent, not local truth.
    public var onSelectBoard: ((Int) -> Void)?

    /// Band height; PanelHost reserves it below the HandleBar when shown.
    public static let height: CGFloat = boardTabBarH

    /// Per-surface palette (PR-B). Wired by PanelHost to the tree box.
    public var paletteBox: PaletteBox!
    var pal: ResolvedPalette { paletteBox.pal }

    private var hoverIndex: Int?
    /// Accumulated scroll-wheel delta; one board step per `boardTabWheelStep`.
    private var wheelAccum: CGFloat = 0

    public override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    public required init?(coder: NSCoder) { nil }

    // MARK: - layout (single source for draw + hit-test)

    private var tabFont: NSFont { uiFont(boardTabFontSize, .medium) }

    /// Intrinsic width of one tab caption = measured text + horizontal padding.
    private func intrinsicWidth(_ label: String) -> CGFloat {
        let w = (label as NSString)
            .size(withAttributes: [.font: tabFont]).width
        return ceil(w) + boardTabPadX * 2
    }

    /// The laid-out tab frames in this band's content space (already inset by
    /// `rowPadX` on the left). Empty when < 2 boards (the bar shouldn't show).
    private func frames() -> [BoardTabFrame] {
        guard boardLabels.count >= 2 else { return [] }
        let available = bounds.width - rowPadX * 2
        let laid = boardTabLayout(widths: boardLabels.map(intrinsicWidth),
                                  available: available, gap: boardTabGap)
        // Shift into the inset content origin.
        return laid.map {
            BoardTabFrame(boardIndex: $0.boardIndex,
                          x: $0.x + rowPadX, width: $0.width)
        }
    }

    private func boardIndex(at point: NSPoint) -> Int? {
        frames().first { point.x >= $0.x && point.x < $0.x + $0.width }?
            .boardIndex
    }

    // MARK: - mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved,
                      .inVisibleRect],
            owner: self))
    }

    public override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let idx = boardIndex(at: p)
        if idx != hoverIndex { hoverIndex = idx; needsDisplay = true }
    }
    public override func mouseExited(with e: NSEvent) {
        if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
    }

    public override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let idx = boardIndex(at: p), idx != activeBoardIndex {
            onSelectBoard?(idx)
        }
    }

    public override func scrollWheel(with e: NSEvent) {
        // Accumulate until a full step; a downward / rightward gesture advances
        // to the NEXT board (matching the rail's wheel direction).
        wheelAccum += e.scrollingDeltaY + e.scrollingDeltaX
        let dir: Int
        if wheelAccum <= -boardTabWheelStep { dir = 1 }       // scroll down → next
        else if wheelAccum >= boardTabWheelStep { dir = -1 }  // scroll up → prev
        else { return }
        wheelAccum = 0
        let next = boardIndexStep(current: activeBoardIndex, by: dir,
                                  count: boardLabels.count)
        if next != activeBoardIndex { onSelectBoard?(next) }
    }

    // MARK: - draw

    public override func draw(_ dirty: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .center
        let th = tabFont.ascender - tabFont.descender
        for f in frames() {
            let active = f.boardIndex == activeBoardIndex
            let hot = f.boardIndex == hoverIndex
            let tabRect = NSRect(x: f.x, y: 3, width: f.width,
                                 height: bounds.height - 9)
            // Active = accent text on the tree's selection fill (the same
            // selected-row idiom); hover = a faint fill. `background` is
            // optional (nil under vibrancy), so the active text is the
            // non-optional accent, never the panel bg.
            if active || hot {
                (active ? pal.selection : pal.hover).setFill()
                NSBezierPath(roundedRect: tabRect, xRadius: boardTabRadius,
                             yRadius: boardTabRadius).fill()
            }
            let color: NSColor = active ? pal.primary
                : (hot ? pal.foreground : pal.muted)
            let labelRect = NSRect(
                x: f.x + boardTabPadX, y: (bounds.height - th) / 2,
                width: f.width - boardTabPadX * 2, height: th)
            (boardLabels[f.boardIndex] as NSString).draw(
                in: labelRect,
                withAttributes: [.font: tabFont, .foregroundColor: color,
                                 .paragraphStyle: para])
        }
        // Hairline bottom divider, matching the HandleBar's.
        let lineY = bounds.height - 0.5
        pal.border.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: rowPadX, y: lineY))
        sep.line(to: NSPoint(x: bounds.width - rowPadX, y: lineY))
        sep.lineWidth = 1
        sep.stroke()
    }
}
