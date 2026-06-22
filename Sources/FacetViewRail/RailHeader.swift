// Grid-style workspace header for the rail's bottom cells: a grip
// glyph + the WS name + layout mode on a faint rounded band. The grip
// + fill read as grabbable (header drag = swap in Phase R3, click =
// switch). The text-line / label drawing is shared (FacetView
// `drawTextLine`, FacetCore `workspaceShortLabel`) so the rail matches
// the grid without importing FacetViewGrid.

import AppKit
import FacetCore
import FacetView

extension RailView {

    func drawHeader(_ cell: OverviewCell) {
        let hb = cell.headerRect
        guard hb.height > 1, hb.width > 1 else { return }
        let hover = hoverHeaderID == cell.sectionID
        // Keyboard "whole-WS" pick: the WS-name slot is selected (Tab
        // cycled to -1, or an arrow just landed here). Highlight the
        // WS name like the grid's header-slot focus. Keyed on sectionID
        // (EX-2b) — lens cells share wsIndex=−1, which would collide.
        let kbWholeWS = drag == nil && kbSelectedWindowIdx == -1
            && selectedSectionID == cell.sectionID
        // The browse target (carousel centre) when it ISN'T the live
        // active WS: paint it in the SECONDARY accent so "previewing"
        // reads apart from the PRIMARY-accent active WS (2-b — mid-browse
        // they're different cells; at rest selected == active = primary).
        let browseTarget = kbWholeWS && !cell.isActive
        let pickColor = browseTarget ? pal.secondary : pal.primary
        let hot = cell.isActive || hover || kbWholeWS

        // Band fill — pick-colour-strong when this WS is the keyboard
        // whole-WS (swap) pick, faint otherwise (brighter on hover).
        let band = NSBezierPath(roundedRect: hb.insetBy(dx: 0, dy: 1),
                                xRadius: 4, yRadius: 4)
        if kbWholeWS {
            pickColor.withAlphaComponent(0.30).setFill(); band.fill()
            pickColor.setStroke(); band.lineWidth = 1.5; band.stroke()
        } else {
            (cell.isActive
                ? pal.primary.withAlphaComponent(hover ? 0.20 : 0.12)
                : pal.muted.withAlphaComponent(hover ? 0.20 : 0.10)).setFill()
            band.fill()
        }

        // Grip (left) — only for WORKSPACE cells (the swap grab affordance).
        // A lens cell is click-only (activate, no swap), so it shows no grip.
        if !cell.isLens {
            drawGripDots(in: NSRect(x: hb.minX + 4, y: hb.minY,
                                    width: railHeaderGripW, height: hb.height),
                         tallExtent: 18,
                         color: browseTarget ? pal.secondary : (hot ? pal.primary : pal.foreground),
                         alpha: hot ? 0.85 : 0.5)
        }

        // Name (+ mode), left-aligned, vertically centred.
        let lp = NSMutableParagraphStyle()
        lp.alignment = .left
        lp.lineBreakMode = .byTruncatingTail
        let nameX = hb.minX + 4 + railHeaderGripW + 5
        let nameW = max(hb.maxX - nameX - 4, 0)
        let nameFont = min(railHeaderNameMaxFont,
                           max(railHeaderNameMinFont,
                               (hb.height * railHeaderNameFrac).rounded()))
        let nameColor = browseTarget ? pal.secondary
            : (cell.isActive ? pal.primary : pal.foreground)
        // A lens cell shows its bare label (no WS ordinal); a workspace uses
        // the shared short caption.
        let name = cell.isLens ? cell.label : railLabel(cell.label, cell.wsIndex)

        if cell.mode.isEmpty || hb.height < railHeaderTwoLineMinH {
            let nameH = nameFont * 1.3
            drawTextLine(name, font: nameFont, weight: .semibold,
                           color: nameColor, para: lp,
                           in: NSRect(x: nameX,
                                      y: hb.minY + (hb.height - nameH) / 2,
                                      width: nameW, height: nameH))
        } else {
            let modeFont = min(railHeaderModeMaxFont,
                               max(railHeaderModeMinFont,
                                   (hb.height * railHeaderModeFrac).rounded()))
            let modeColor = cell.isActive ? pal.secondary : pal.muted
            let nameH = nameFont * 1.25
            let modeH = (modeFont * 1.3).rounded()
            let gap: CGFloat = 2
            let startY = hb.minY + (hb.height - (nameH + gap + modeH)) / 2
            drawTextLine(name, font: nameFont, weight: .semibold,
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

    /// Short WS caption — delegates to the shared `workspaceShortLabel`
    /// (FacetCore). Thin module-local name for the rail's call sites.
    func railLabel(_ name: String, _ idx: Int) -> String {
        workspaceShortLabel(name: name, idx: idx)
    }
}
