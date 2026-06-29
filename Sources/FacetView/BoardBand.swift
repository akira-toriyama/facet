// The board switcher band (t-wrd2) — a pinned chrome band that switches which
// `[[desktop.N.tab]]` board the view shows. Shown ONLY when the active mac
// desktop has ≥2 boards (a flat / single-board config gets no band — zero new
// chrome, byte-identical to today). A board switch is a pure DISPLAY
// re-grouping of the SAME windows — it commits the same session-only
// `selectedBoard` + re-render as `facet board --focus` (via the Controller's
// `selectBoardFromUI`, the CLI verb's sibling — they share the EFFECT, not a
// function), only skipping the label / `index:` parsing — and never moves a
// real window.
//
// Promoted out of FacetViewTree (where it shipped as `BoardTabBar`, W2.4) into
// FacetView so the tree AND the grid overlay can reuse one band view (the rail
// draws its own edge-aware variant inline, since its passive `.nonactivatingPanel`
// can't host a subview whose `scrollWheel` fires reliably). The tree pins it
// below the "Desktop N" HandleBar; the grid pins it at the overlay top.
//
// Interaction (modelled on the rail, the other facet board-ish switcher):
//   • click a tab            → switch to that board
//   • scroll-wheel / swipe   → cycle boards (one step per `boardBandWheelStep`)
//   • both commit immediately — a board switch is display-only and cheap, so
//     there is no rail-style browse-then-commit cursor.
// Layout/​geometry is the pure `boardTabLayout` (FacetCore): tabs sit at their
// intrinsic width when they fit (the v1 2-3 board case), else shrink uniformly.
//
// DnD: the band does NOT participate — a row dragged onto a tab does nothing
// (boards are independent worlds; cross-board moves aren't a drag gesture).
// Tab reordering is deferred.

import AppKit
import FacetCore

// Board band metrics. Moved from `FacetViewTree/Tunables.swift` when the band
// was promoted to FacetView. The tree's `rowPadX` (used tree-wide) was NOT
// moved — the band carries its own side inset (`boardBandSidePad`, same 12pt).
let boardBandBarH: CGFloat = 30           // band height; the host reserves it when shown
let boardBandFontSize: CGFloat = 12       // tab caption — subhead size
let boardBandPadX: CGFloat = 10           // horizontal padding inside each tab (intrinsic width = text + 2×this)
let boardBandGap: CGFloat = 4             // gap between adjacent tabs
let boardBandRadius: CGFloat = 6          // active-tab pill corner radius
let boardBandWheelStep: CGFloat = 14      // scroll-wheel points accumulated per one board step (≈ a notch / swipe)
let boardBandSidePad: CGFloat = 12        // band's left/right content inset (was the tree's `rowPadX`)

@MainActor
public final class BoardBand: NSView {
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

    /// Band height; the host reserves it (tree: below the HandleBar; grid: at
    /// the overlay top) only when shown.
    public static let height: CGFloat = boardBandBarH

    /// Per-surface palette (PR-B). Wired by the host to that surface's box.
    public var paletteBox: PaletteBox!
    var pal: ResolvedPalette { paletteBox.pal }

    private var hoverIndex: Int?
    /// Accumulated scroll-wheel delta; one board step per `boardBandWheelStep`.
    private var wheelAccum: CGFloat = 0

    public override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    public required init?(coder: NSCoder) { nil }

    // MARK: - layout (single source for draw + hit-test)

    private var tabFont: NSFont { uiFont(boardBandFontSize, .medium) }

    /// Intrinsic width of one tab caption = measured text + horizontal padding.
    private func intrinsicWidth(_ label: String) -> CGFloat {
        let w = (label as NSString)
            .size(withAttributes: [.font: tabFont]).width
        return ceil(w) + boardBandPadX * 2
    }

    /// The laid-out tab frames in this band's content space (already inset by
    /// `boardBandSidePad` on the left). Empty when < 2 boards (no band shown).
    private func frames() -> [BoardTabFrame] {
        guard boardLabels.count >= 2 else { return [] }
        let available = bounds.width - boardBandSidePad * 2
        let laid = boardTabLayout(widths: boardLabels.map(intrinsicWidth),
                                  available: available, gap: boardBandGap)
        // Shift into the inset content origin.
        return laid.map {
            BoardTabFrame(boardIndex: $0.boardIndex,
                          x: $0.x + boardBandSidePad, width: $0.width)
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
        // Mirror the rail's `scrollRotate` (RailView): IGNORE the momentum tail
        // so one trackpad flick can't keep stepping after the fingers lift (M2);
        // honour natural-scroll as-is (the sign already carries it) — down →
        // next. Reset the accumulator at each gesture start so a sub-threshold
        // leftover can't bias the next, unrelated gesture.
        guard boardLabels.count > 1, e.momentumPhase == [] else { return }
        let dy = e.scrollingDeltaY
        if dy == 0 { return }
        var step = 0
        if e.hasPreciseScrollingDeltas {
            // Trackpad / Magic Mouse: accumulate points, one step per
            // `boardBandWheelStep`.
            if e.phase.contains(.began) { wheelAccum = 0 }
            wheelAccum += dy
            while abs(wheelAccum) >= boardBandWheelStep {
                let d = wheelAccum < 0 ? 1 : -1            // down → next, up → prev
                wheelAccum += CGFloat(d) * boardBandWheelStep
                step += d
            }
        } else {
            step = dy < 0 ? 1 : -1                          // notched wheel: 1 detent = 1 step
        }
        guard step != 0 else { return }
        // Apply the NET step once (clamped) so a multi-step swipe is a single
        // commit / re-render rather than one per intermediate board.
        let next = boardIndexStep(current: activeBoardIndex, by: step,
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
                NSBezierPath(roundedRect: tabRect, xRadius: boardBandRadius,
                             yRadius: boardBandRadius).fill()
            }
            let color: NSColor = active ? pal.primary
                : (hot ? pal.foreground : pal.muted)
            let labelRect = NSRect(
                x: f.x + boardBandPadX, y: (bounds.height - th) / 2,
                width: f.width - boardBandPadX * 2, height: th)
            (boardLabels[f.boardIndex] as NSString).draw(
                in: labelRect,
                withAttributes: [.font: tabFont, .foregroundColor: color,
                                 .paragraphStyle: para])
        }
        // Hairline bottom divider, matching the HandleBar's.
        let lineY = bounds.height - 0.5
        pal.border.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: boardBandSidePad, y: lineY))
        sep.line(to: NSPoint(x: bounds.width - boardBandSidePad, y: lineY))
        sep.lineWidth = 1
        sep.stroke()
    }
}
