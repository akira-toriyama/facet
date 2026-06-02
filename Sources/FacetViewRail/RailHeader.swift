// Grid-style workspace header for the rail's bottom cells: a grip
// glyph + the WS name + layout mode on a faint rounded band. The grip
// + fill read as grabbable (header drag = swap in Phase R3, click =
// switch). Module-local copies of the grid's `drawGridGrip` /
// `drawHeaderLine` / `gridLabel` — the rail can't import FacetViewGrid.

import AppKit
import FacetCore
import FacetView

extension RailView {

    func drawHeader(_ cell: Cell) {
        let hb = cell.headerRect
        guard hb.height > 1, hb.width > 1 else { return }
        let hover = hoverHeaderWS == cell.wsIndex
        // Keyboard "whole-WS" pick: the WS-name slot is selected (Tab
        // cycled to -1, or an arrow just landed here). Highlight the
        // WS name like the grid's header-slot focus.
        let kbWholeWS = drag == nil && kbSelectedWindowIdx == -1
            && selectedWS == cell.wsIndex
        let hot = cell.isActive || hover || kbWholeWS

        // Band fill — accent-strong when this WS is the keyboard
        // whole-WS (swap) pick, faint otherwise (brighter on hover).
        let band = NSBezierPath(roundedRect: hb.insetBy(dx: 0, dy: 1),
                                xRadius: 4, yRadius: 4)
        if kbWholeWS {
            pal.accent.withAlphaComponent(0.30).setFill(); band.fill()
            pal.accent.setStroke(); band.lineWidth = 1.5; band.stroke()
        } else {
            (cell.isActive
                ? pal.accent.withAlphaComponent(hover ? 0.20 : 0.12)
                : pal.dim.withAlphaComponent(hover ? 0.20 : 0.10)).setFill()
            band.fill()
        }

        // Grip (left).
        drawRailGrip(in: NSRect(x: hb.minX + 4, y: hb.minY,
                                width: railHeaderGripW, height: hb.height),
                     color: hot ? pal.accent : pal.text,
                     alpha: hot ? 0.85 : 0.5)

        // Name (+ mode), left-aligned, vertically centred.
        let lp = NSMutableParagraphStyle()
        lp.alignment = .left
        lp.lineBreakMode = .byTruncatingTail
        let nameX = hb.minX + 4 + railHeaderGripW + 5
        let nameW = max(hb.maxX - nameX - 4, 0)
        let nameFont = min(railHeaderNameMaxFont,
                           max(railHeaderNameMinFont,
                               (hb.height * railHeaderNameFrac).rounded()))
        let nameColor = cell.isActive ? pal.accent : pal.text
        let name = railLabel(cell.name, cell.wsIndex)

        if cell.mode.isEmpty || hb.height < railHeaderTwoLineMinH {
            let nameH = nameFont * 1.3
            drawHeaderLine(name, font: nameFont, weight: .semibold,
                           color: nameColor, para: lp,
                           in: NSRect(x: nameX,
                                      y: hb.minY + (hb.height - nameH) / 2,
                                      width: nameW, height: nameH))
        } else {
            let modeFont = min(railHeaderModeMaxFont,
                               max(railHeaderModeMinFont,
                                   (hb.height * railHeaderModeFrac).rounded()))
            let modeColor = cell.isActive ? pal.accent2 : pal.dim
            let nameH = nameFont * 1.25
            let modeH = (modeFont * 1.3).rounded()
            let gap: CGFloat = 2
            let startY = hb.minY + (hb.height - (nameH + gap + modeH)) / 2
            drawHeaderLine(name, font: nameFont, weight: .semibold,
                           color: nameColor, para: lp,
                           in: NSRect(x: nameX, y: startY,
                                      width: nameW, height: nameH))
            (layoutBadgeLabel(cell.mode) as NSString).draw(
                in: NSRect(x: nameX, y: startY + nameH + gap,
                           width: nameW, height: modeH),
                withAttributes: [.font: uiFont(modeFont, .semibold),
                                 .foregroundColor: modeColor,
                                 .paragraphStyle: lp])
        }
    }

    func drawHeaderLine(_ s: String, font: CGFloat, weight: NSFont.Weight,
                        color: NSColor, para: NSParagraphStyle, in rect: NSRect) {
        (s as NSString).draw(in: rect, withAttributes: [
            .font: uiFont(font, weight),
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
    }

    /// A 3-column dot grid — the drag-handle affordance at the header's
    /// left. Height-aware (10 rows tall / 3 rows compact) so it stays
    /// legible in the rail's tiny bottom cells. (Copy of the grid's
    /// `drawGridGrip`.)
    func drawRailGrip(in r: NSRect, color: NSColor, alpha: CGFloat) {
        let dotR: CGFloat = 1.5
        let xs = [r.minX + dotR + 2, r.minX + dotR + 7, r.minX + dotR + 12]
        let ys: [CGFloat] = r.height >= 28
            ? stride(from: -18.0, through: 18.0, by: 4.0).map { r.midY + $0 }
            : [r.midY - 4, r.midY, r.midY + 4]
        color.withAlphaComponent(alpha).setFill()
        for x in xs {
            for y in ys {
                NSBezierPath(ovalIn: NSRect(x: x - dotR, y: y - dotR,
                                            width: dotR * 2,
                                            height: dotR * 2)).fill()
            }
        }
    }

    /// Short WS caption — strips a leading "workspace " prefix; empty →
    /// "WS<n>". (Module-local copy of the grid's `gridLabel`.)
    func railLabel(_ name: String, _ idx: Int) -> String {
        if name.isEmpty { return "WS\(idx + 1)" }
        let lower = name.lowercased()
        if lower.hasPrefix("workspace "), name.count > "workspace ".count {
            return String(name.dropFirst("workspace ".count))
        }
        return name
    }
}
