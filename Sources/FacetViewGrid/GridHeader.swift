// Grid workspace header bar — the swap drag handle (Theme A: drag the
// header = swap this WS's contents with the drop target; click =
// switch). A faint rounded fill + a grip glyph read as grabbable (same
// model / affordance as the tree header and the rail's `RailHeader`).
// Extracted from `draw(_:)` so the grid's header drawing sits in its own
// method like the rail's — keeping the big `draw(_:)` readable (P8).

import AppKit
import FacetCore
import FacetView

extension GridView {

    /// Draw one cell's workspace header band: grip + WS name (line 1) +
    /// layout mode (line 2, accent). Reads the drag / kb-selection /
    /// hover state off `self`. Called per cell from `draw(_:)`.
    func drawHeader(_ cell: OverviewCell) {
        // Same palette derivations as `draw(_:)` (deterministic from
        // `pal`, stable for the pass) so the band matches the cells.
        let activeColor = pal.primary
        let labelColor = pal.foreground.withAlphaComponent(0.85)
        let hb = cell.headerRect
        let headerSel = (drag == nil && kbSelectedID == cell.sectionID
                         && kbSelectedWindowIdx == -1)
        let headerHover = (drag == nil && hoverHeaderID == cell.sectionID)
        let headerHot = cell.isActive || headerSel || headerHover
        (cell.isActive
            ? activeColor.withAlphaComponent(headerHover ? 0.20 : 0.12)
            : pal.muted.withAlphaComponent(headerHover ? 0.20 : 0.10))
            .setFill()
        NSBezierPath(roundedRect: hb.insetBy(dx: 0, dy: 1),
                     xRadius: 4, yRadius: 4).fill()
        if headerSel {
            // Match the cell cursor + rail: accent for the active
            // WS, secondary for a browse target — not a plain text
            // stroke (the WS-name slot is the open-time selection
            // since grid opens at kbSelectedWindowIdx == -1).
            (cell.isActive ? pal.primary : pal.secondary).setStroke()
            let ho = NSBezierPath(
                roundedRect: hb.insetBy(dx: 0.75, dy: 1.25),
                xRadius: 4, yRadius: 4)
            ho.lineWidth = 1.5
            ho.stroke()
        }
        // Grip dots = the swap-drag affordance. Only a WORKSPACE cell header
        // is a swap target; a non-workspace cell is click-only (no source
        // workspace → no swap), so suppress the grip for it.
        if cell.sectionType == .workspace {
            drawGripDots(
                in: NSRect(x: hb.minX + 4, y: hb.minY,
                           width: gridHeaderGripW, height: hb.height),
                tallExtent: 18,
                color: headerHot ? activeColor : labelColor,
                alpha: headerHot ? 0.85 : 0.5)
        }
        // WS name (line 1) + layout mode (line 2, accent), stacked
        // and vertically centred. Two lines give the header a
        // natural thickness and surface the same layout-mode info
        // the tree header shows. Fonts track the band height.
        let lp = NSMutableParagraphStyle()
        lp.alignment = .left
        lp.lineBreakMode = .byTruncatingTail
        let nameX = hb.minX + 4 + gridHeaderGripW + 5
        let nameW = max(hb.maxX - nameX - 4, 0)
        let nameFont = min(gridHeaderNameMaxFont,
                           max(gridHeaderNameMinFont,
                               (hb.height * gridHeaderNameFrac).rounded()))
        let nameColor = cell.isActive ? activeColor : labelColor
        if cell.mode.isEmpty {
            let nameH = nameFont * 1.3
            drawTextLine(cell.label, font: nameFont, weight: .semibold,
                           color: nameColor, para: lp,
                           in: NSRect(x: nameX,
                                      y: hb.minY + (hb.height - nameH) / 2,
                                      width: nameW, height: nameH))
        } else {
            let modeFont = min(gridHeaderModeMaxFont,
                               max(gridHeaderModeMinFont,
                                   (hb.height * gridHeaderModeFrac).rounded()))
            // Layout-mode text — secondary semibold on the active
            // WS, `pal.muted` on the rest. No pill background — the
            // text + color step alone carries the badge weight,
            // matching the tree header's restyle.
            let modeColor = cell.isActive ? pal.secondary : pal.muted
            let mAttrs: [NSAttributedString.Key: Any] = [
                .font: uiFont(modeFont, .semibold),
                .foregroundColor: modeColor,
                .paragraphStyle: lp,
            ]
            let modeH = (modeFont * 1.3).rounded()
            let nameH = nameFont * 1.25
            let gap: CGFloat = 3
            let startY = hb.minY + (hb.height - (nameH + gap + modeH)) / 2
            drawTextLine(cell.label, font: nameFont, weight: .semibold,
                           color: nameColor, para: lp,
                           in: NSRect(x: nameX, y: startY,
                                      width: nameW, height: nameH))
            (layoutBadgeLabel(cell.mode) as NSString).draw(
                in: NSRect(x: nameX, y: startY + nameH + gap,
                           width: nameW, height: modeH),
                withAttributes: mAttrs)
        }
    }
}
