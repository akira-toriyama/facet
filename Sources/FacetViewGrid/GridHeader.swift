// Grid workspace header band — SwiftUI. The swap/reorder drag handle
// (Theme A: grab the header = drag the section; click = switch). A faint
// rounded fill + a grip glyph read as grabbable — the same model /
// affordance as the tree header and the rail's `RailHeader`. The band
// height is resolved by `gridFitMetrics` (proportional, clamped); both
// fonts track it.

import SwiftUI
import AppKit
import FacetCore
import FacetView
import PaletteKit

struct GridHeaderView: View {
    let model: GridViewModel
    let cell: GridCellVM
    let bandH: CGFloat
    @State private var hovering = false

    private var pal: PaletteKit.ResolvedPalette { model.palette }

    /// Cursor-on-header (the WS-name slot is the open-time selection: the
    /// grid opens at `kbWindowIdx == -1`).
    private var headerSel: Bool {
        model.drag == nil && model.kbCursorID == cell.id && model.kbWindowIdx == -1
    }
    private var headerHot: Bool { cell.isActive || headerSel || hovering }

    private var fillColor: Color {
        let base = cell.isActive ? pal.primary : pal.muted
        return Color(nsColor: base)
            .opacity(hovering ? 0.20 : (cell.isActive ? 0.12 : 0.10))
    }

    var body: some View {
        let nameFont = min(gridHeaderNameMaxFont,
                           max(gridHeaderNameMinFont,
                               (bandH * gridHeaderNameFrac).rounded()))
        let modeFont = min(gridHeaderModeMaxFont,
                           max(gridHeaderModeMinFont,
                               (bandH * gridHeaderModeFrac).rounded()))
        let labelColor = Color(nsColor: pal.foreground).opacity(0.85)
        let nameColor = cell.isActive ? Color(nsColor: pal.primary) : labelColor

        HStack(spacing: 5) {
            // Grip dots = the drag affordance. Only a WORKSPACE header is a
            // swap/reorder source with a home of its own; a lens header keeps
            // the click without advertising a grab.
            if cell.sectionType == .workspace {
                GripDotsView(
                    tallForm: bandH >= 28,
                    color: headerHot ? Color(nsColor: pal.primary) : labelColor,
                    alpha: headerHot ? 0.85 : 0.5)
                    .frame(width: gridHeaderGripW, height: bandH)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(cell.caption)
                    .font(Font(uiFont(nameFont, .semibold)))
                    .foregroundColor(nameColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !cell.mode.isEmpty {
                    // Layout-mode text — secondary semibold on the active WS,
                    // muted on the rest; no pill background (tree parity).
                    Text(layoutBadgeLabel(cell.mode))
                        .font(Font(uiFont(modeFont, .semibold)))
                        .foregroundColor(Color(nsColor: cell.isActive
                                               ? pal.secondary : pal.muted))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity)
        .frame(height: bandH)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(fillColor)
                .padding(.vertical, 1))
        .overlay {
            if headerSel {
                // Accent for the active WS, secondary for a browse target —
                // matches the old header ring + the rail.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .inset(by: 0.75)
                    .stroke(Color(nsColor: cell.isActive ? pal.primary : pal.secondary),
                            lineWidth: 1.5)
                    .padding(.vertical, 1.25)
            }
        }
        .onHover { inside in
            hovering = inside
            // The open-hand cursor only over a grabbable (workspace) header.
            if cell.sectionType == .workspace {
                (inside ? NSCursor.openHand : NSCursor.arrow).set()
            }
        }
    }
}

/// The 2-column dot grid — the universal drag-handle texture (tree / grid /
/// rail, M9-5 #4). Height-aware like the AppKit `drawGripDots`: the 2-line
/// band (≥ 28 pt) stretches to a vertical strip (±18 pt around the midline);
/// shorter bands fall back to the compact 3-row form.
struct GripDotsView: View {
    let tallForm: Bool
    let color: Color
    let alpha: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let dotR: CGFloat = 1.15
            let xs: [CGFloat] = [dotR + 1, dotR + 5]
            let midY = size.height / 2
            let ys: [CGFloat] = tallForm
                ? stride(from: -18.0, through: 18.0, by: 4.0).map { midY + $0 }
                : [midY - 4, midY, midY + 4]
            for x in xs {
                for y in ys {
                    let r = CGRect(x: x - dotR, y: y - dotR,
                                   width: dotR * 2, height: dotR * 2)
                    ctx.fill(Path(ellipseIn: r), with: .color(color.opacity(alpha)))
                }
            }
        }
    }
}
