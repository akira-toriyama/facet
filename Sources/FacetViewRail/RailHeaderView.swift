// Grid-style workspace header for the rail's strip cells, SwiftUI: a
// grip glyph + the §D caption (+ layout mode) on a faint rounded band.
// The grip + fill read as grabbable — a header drag is the display-only
// section REORDER (both workspace and lens headers arm it; the keyboard
// header lift is the content SWAP and never mixes with this), a click
// switches. Fonts track the band height with the rail's smaller clamps.

import SwiftUI
import AppKit
import FacetCore
import FacetView
import PaletteKit

struct RailHeaderView: View {
    let model: RailViewModel
    let cell: RailCellVM
    let bandH: CGFloat
    @State private var hovering = false

    private var pal: PaletteKit.ResolvedPalette { model.palette }

    /// Keyboard "whole-WS" pick: the WS-name slot is selected (Tab cycled
    /// to -1, or an arrow just landed here).
    private var kbWholeWS: Bool {
        model.drag == nil && model.kbWindowIdx == -1
            && model.selectedSectionID == cell.id
    }
    /// The browse target (carousel centre) when it ISN'T the live active
    /// WS — SECONDARY accent so "previewing" reads apart from the
    /// PRIMARY-accent active section.
    private var browseTarget: Bool { kbWholeWS && !cell.isActive }
    private var pickColor: NSColor { browseTarget ? pal.secondary : pal.primary }
    private var hot: Bool { cell.isActive || hovering || kbWholeWS }

    var body: some View {
        let nameFont = min(railHeaderNameMaxFont,
                           max(railHeaderNameMinFont,
                               (bandH * railHeaderNameFrac).rounded()))
        let nameColor: NSColor = browseTarget ? pal.secondary
            : (cell.isActive ? pal.primary : pal.foreground)
        let twoLine = !cell.mode.isEmpty && bandH >= railHeaderTwoLineMinH

        HStack(spacing: 5) {
            // Grip (left) — only WORKSPACE cells advertise the grab; a
            // non-workspace header keeps the caption without dots.
            if cell.sectionType == .workspace {
                RailGripDots(
                    tallForm: bandH >= 28,
                    color: Color(nsColor: browseTarget ? pal.secondary
                                 : (hot ? pal.primary : pal.foreground)),
                    alpha: hot ? 0.85 : 0.5)
                    .frame(width: railHeaderGripW, height: bandH)
            } else {
                Color.clear.frame(width: railHeaderGripW, height: bandH)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(cell.caption)
                    .font(Font(uiFont(nameFont, .semibold)))
                    .foregroundColor(Color(nsColor: nameColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if twoLine {
                    let modeFont = min(railHeaderModeMaxFont,
                                       max(railHeaderModeMinFont,
                                           (bandH * railHeaderModeFrac).rounded()))
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
                .fill(bandFill)
                .padding(.vertical, 1))
        .overlay {
            if kbWholeWS {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .inset(by: 0.75)
                    .stroke(Color(nsColor: pickColor), lineWidth: 1.5)
                    .padding(.vertical, 1)
            }
        }
        .contentShape(Rectangle())
        // Header drag = section reorder (both section types); a click
        // switches to the workspace (zoom iff it's the centre).
        .gesture(
            DragGesture(minimumDistance: pointerDragThreshold,
                        coordinateSpace: .named(facetRailSpace))
                .onChanged { v in
                    model.headerDragChanged(cellID: cell.id, location: v.location)
                    NSCursor.closedHand.set()
                }
                .onEnded { _ in
                    model.headerDragEnded()
                    NSCursor.arrow.set()
                })
        .gesture(TapGesture().onEnded { model.tapCell(cell.id) })
        .onHover { inside in
            hovering = inside
            model.hoverHeaderID = inside ? cell.id : nil
            // The open-hand cursor only over a WORKSPACE header (a lens
            // header reorders but never swaps — the old cursor rule).
            if cell.sectionType == .workspace {
                (inside ? NSCursor.openHand : NSCursor.arrow).set()
            }
        }
    }

    private var bandFill: Color {
        if kbWholeWS {
            return Color(nsColor: pickColor).opacity(0.30)
        }
        return Color(nsColor: cell.isActive ? pal.primary : pal.muted)
            .opacity(cell.isActive ? (hovering ? 0.20 : 0.12)
                                   : (hovering ? 0.20 : 0.10))
    }
}

/// The 2-column dot grid — the universal drag-handle texture (tree /
/// grid / rail). Height-aware: the tall band stretches to a vertical
/// strip (±18 pt around the midline); shorter bands use the compact
/// 3-row form.
struct RailGripDots: View {
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
