// The rail's board switcher band (t-wrd2) — drawn INLINE in RailView (not a
// subview) and hit-tested through RailView's own mouse + the Controller's
// scroll monitor, because the rail overlay is a `.nonactivatingPanel` whose
// scroll / keyboard are caught at the app's event monitor, not the responder
// chain (a subview's `scrollWheel` / first-responder would never fire). The
// pure geometry (`railBoardBand` / `railInset`, FacetCore) decides the rects;
// this file owns only the AppKit draw + the wheel-to-step. The band is always a
// horizontal tab row — its POSITION varies by edge (see `RailGeometry`).

import AppKit
import FacetCore
import FacetView

extension RailView {

    var boardTabFont: NSFont { uiFont(railBoardFontSize, .medium) }

    /// Intrinsic width of one board caption = measured text + horizontal padding
    /// (the same idiom the tree band uses; measured view-side, fed to the pure
    /// `boardTabLayout`).
    func boardTabIntrinsicWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: boardTabFont]).width)
            + railBoardPadX * 2
    }

    /// Paint the board band — a subtle backing strip, an accent pill behind the
    /// active tab, captions, and a hairline separating it from the strip / hero.
    /// No-op when there's no band (< 2 boards).
    func drawBoardBand() {
        guard !boardBandRect.isEmpty, !boardCells.isEmpty else { return }
        pal.muted.withAlphaComponent(0.10).setFill()
        boardBandRect.fill()

        let font = boardTabFont
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .center
        let th = font.ascender - font.descender
        for c in boardCells where c.boardIndex < boardLabels.count {
            let active = c.boardIndex == activeBoardIndex
            if active {
                pal.selection.setFill()
                NSBezierPath(roundedRect: c.rect.insetBy(dx: 0, dy: 3),
                             xRadius: railBoardRadius, yRadius: railBoardRadius).fill()
            }
            let color: NSColor = active ? pal.primary : pal.muted
            let labelRect = NSRect(x: c.rect.minX + railBoardPadX,
                                   y: c.rect.midY - th / 2,
                                   width: c.rect.width - railBoardPadX * 2, height: th)
            (boardLabels[c.boardIndex] as NSString).draw(
                in: labelRect,
                withAttributes: [.font: font, .foregroundColor: color,
                                 .paragraphStyle: para])
        }
        // Hairline on the band's bottom edge (it's pinned to the screen top, so
        // the inner edge — toward the strip / hero — is always the bottom).
        let innerY = boardBandRect.maxY
        pal.border.setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: boardBandRect.minX, y: innerY))
        sep.line(to: NSPoint(x: boardBandRect.maxX, y: innerY))
        sep.lineWidth = 1
        sep.stroke()
    }

    /// Wheel over the band → step boards (clamped, one step per
    /// `boardBandWheelStep`), mirroring the tree band's `scrollWheel`. Called by
    /// `scrollRotate`'s hit-zone split (the carousel handles wheel elsewhere).
    /// Shares the `wheelSteps` math (FacetCore) AND the `boardBandWheelStep`
    /// threshold (FacetView) with the tree band, NET-applied once; the
    /// momentum-tail guard lives in the caller (`scrollRotate`).
    func scrollBoardBand(_ e: NSEvent) {
        guard boardLabels.count > 1 else { return }
        let step = wheelSteps(deltaY: e.scrollingDeltaY, accum: &boardWheelAccum,
                              threshold: boardBandWheelStep,
                              precise: e.hasPreciseScrollingDeltas,
                              gestureBegan: e.phase.contains(.began))
        guard step != 0 else { return }
        let next = boardIndexStep(current: activeBoardIndex, by: step,
                                  count: boardLabels.count)
        if next != activeBoardIndex { onSelectBoard?(next) }
    }
}
