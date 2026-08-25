// The rail's mini-screen cell (hero + strip), its window thumbs, the
// mark badge, and the floating workspace ghost — the SwiftUI render of
// the old `drawCell` / `RailDrag` painters. The host's own gestures live
// on the content (inner gestures win): a tap is the rail's instant pick,
// a thumb drag its window move, a header drag its section reorder.

import SwiftUI
import AppKit
import FacetCore
import FacetView
import PaletteKit

/// One workspace/lens mini-screen: background, scaled window thumbs, and
/// the priority-ordered chrome ring (drop target → lifted source → hero →
/// active → browse selection → hover → border). The hero passes
/// `isHero: true` — same painter, thicker focal ring, no header.
struct RailMiniScreen: View {
    let model: RailViewModel
    let cell: RailCellVM
    let isHero: Bool
    let rect: CGRect

    private var pal: PaletteKit.ResolvedPalette { model.palette }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: railCellRadius,
                                     style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Color(nsColor: pal.background ?? .windowBackgroundColor)
                .opacity(0.55))
            if let fill = overlayFill {
                shape.fill(fill)
            }

            // Window mini-thumbnails (≥2 px cull at the rendered size); the
            // dragged window hides in BOTH tiers (the ghost stands in).
            ForEach(Array(cell.thumbs.enumerated()), id: \.element.id) { ti, thumb in
                let r = model.absRect(thumb.norm,
                                      in: CGRect(origin: .zero, size: rect.size))
                if r.width >= 2, r.height >= 2 {
                    RailThumbView(model: model, cell: cell, thumb: thumb,
                                  thumbIndex: ti, rect: r, isHero: isHero)
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                        // Hide via OPACITY, never by leaving the hierarchy —
                        // removing a view whose DragGesture is live kills the
                        // gesture mid-flight (the grid's measured lesson).
                        .opacity(model.hiddenThumbID == thumb.id ? 0 : 1)
                }
            }
        }
        .clipShape(shape)
        .overlay { shape.stroke(strokeColor, lineWidth: strokeWidth) }
        .contentShape(Rectangle())
        // Empty-area click: a strip cell switches (zoom iff centred); the
        // hero is a focal preview, not a target — its tap swallows so the
        // backdrop can't dismiss through it.
        .gesture(TapGesture().onEnded {
            if !isHero { model.tapCell(cell.id) }
        })
        .onHover { inside in
            if !isHero { model.hoverID = inside ? cell.id : nil }
        }
    }

    /// The old `drawCell` fill arm of the priority chain (ring colours
    /// live in `strokeColor`).
    private var overlayFill: Color? {
        if let hl = model.dropHighlight(cell) {
            switch hl {
            case .window: return Color(nsColor: pal.primary).opacity(0.28)
            case .swap:   return Color(nsColor: pal.foreground).opacity(0.18)
            }
        }
        if model.isDragSource(cell) {
            return Color(nsColor: pal.foreground).opacity(0.06)
        }
        return nil
    }

    private var strokeColor: Color {
        if let hl = model.dropHighlight(cell) {
            switch hl {
            case .window: return Color(nsColor: pal.primary)
            case .swap:   return Color(nsColor: pal.foreground).opacity(0.85)
            }
        }
        if model.isDragSource(cell) {
            return Color(nsColor: pal.foreground).opacity(0.40)
        }
        if isHero {
            return Color(nsColor: cell.isActive ? pal.primary : pal.secondary)
        }
        if cell.isActive { return Color(nsColor: pal.primary) }
        if model.drag == nil, model.selectedSectionID == cell.id {
            return Color(nsColor: pal.secondary)
        }
        if model.hoverID == cell.id {
            return Color(nsColor: pal.foreground).opacity(0.7)
        }
        return Color(nsColor: pal.border)
    }

    private var strokeWidth: CGFloat {
        if model.dropHighlight(cell) != nil { return 2 }
        if model.isDragSource(cell) { return 1 }
        if isHero { return 2.5 }
        if cell.isActive { return 2 }
        if model.drag == nil, model.selectedSectionID == cell.id { return 2 }
        if model.hoverID == cell.id { return 1.5 }
        return 1
    }
}

/// One window mini-rect: fill → capture (stretch — the rail never falls
/// back to app icons) → hairline stroke → mark badge → keyboard ring.
/// Tap = pick; drag = the window move (hero is the primary drag source).
struct RailThumbView: View {
    let model: RailViewModel
    let cell: RailCellVM
    let thumb: RailThumbVM
    let thumbIndex: Int
    let rect: CGRect
    let isHero: Bool

    private var pal: PaletteKit.ResolvedPalette { model.palette }

    /// The keyboard ring draws in BOTH tiers — the hero (large) and the
    /// selected strip cell (small) — matched by window id, suppressed
    /// while lifted (the ghost carries the selection then).
    private var isKbSelected: Bool {
        guard model.drag == nil, let s = model.kbSelectedThumb else { return false }
        return s.cell.id == cell.id && s.thumb.id == thumb.id
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            shape.fill(Color(nsColor: thumb.isFocused ? pal.primary : pal.foreground)
                .opacity(thumb.isFocused ? 0.30 : 0.16))
            if let img = model.thumbnails[thumb.id] {
                // Stretch into the thumb rect — the old `img.draw(in:)`.
                Image(nsImage: img)
                    .resizable()
                    .clipShape(shape)
            }
            // Captures only: no image yet → just the subtle fill above.
            shape.stroke(Color(nsColor: pal.foreground).opacity(0.40),
                         lineWidth: 0.5)
        }
        .overlay(alignment: .topLeading) {
            if let mark = thumb.mark, !mark.isEmpty {
                RailMarkBadge(mark: mark, rect: rect, pal: pal)
                    .padding(2)
            }
        }
        .overlay {
            if isKbSelected {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .inset(by: 1)
                    .fill(Color(nsColor: pal.primary).opacity(0.30))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .inset(by: 1)
                    .stroke(Color(nsColor: pal.primary),
                            lineWidth: isHero ? 3 : 2)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: pointerDragThreshold,
                        coordinateSpace: .named(facetRailSpace))
                .onChanged { v in
                    model.thumbDragChanged(cellID: cell.id, thumb: thumb,
                                           thumbIndex: thumbIndex,
                                           location: v.location)
                    NSCursor.closedHand.set()
                }
                .onEnded { _ in
                    model.thumbDragEnded()
                    NSCursor.arrow.set()
                })
        .gesture(TapGesture().onEnded {
            model.tapThumb(cellID: cell.id, thumb: thumb)
        })
    }
}

/// The tiny window-mark badge: an accent pill when it fits, else an
/// accent dot (mirrors the shared AppKit `drawMiniMarkBadge`).
struct RailMarkBadge: View {
    let mark: String
    let rect: CGRect
    let pal: PaletteKit.ResolvedPalette

    var body: some View {
        let pillFits = rect.height >= 13
            && rect.width >= CGFloat(mark.count) * 5 + 10
        if pillFits {
            Text(mark)
                .font(Font(uiFont(7, .bold)))
                .foregroundColor(Color(nsColor: pal.primary))
                .lineLimit(1)
                .padding(.horizontal, 3)
                .frame(height: 9)
                .background(
                    Capsule().fill(Color(nsColor: pal.background ?? .black).opacity(0.6)))
                .overlay(
                    Capsule().stroke(Color(nsColor: pal.primary), lineWidth: 0.75))
        } else {
            Circle()
                .fill(Color(nsColor: pal.primary))
                .frame(width: 4, height: 4)
        }
    }
}

/// The floating cell card for a workspace-swap lift or a section-reorder
/// drag: the source cell's thumbs in their backend positions (capture /
/// placeholder fill — captures-only, like every rail thumb), or the
/// centred WS label when the cell is empty.
struct RailWorkspaceGhost: View {
    let model: RailViewModel
    let cell: RailCellVM
    let size: CGSize

    private var pal: PaletteKit.ResolvedPalette { model.palette }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: railCellRadius,
                                     style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Color(nsColor: pal.foreground).opacity(0.10))
            if cell.thumbs.isEmpty {
                Text(cell.caption)
                    .font(Font(uiFont(railGhostLabelSize, .bold)))
                    .foregroundColor(Color(nsColor: pal.foreground).opacity(0.95))
                    .frame(width: size.width, height: size.height)
            } else {
                ForEach(Array(cell.thumbs.enumerated()), id: \.element.id) { _, thumb in
                    let r = model.absRect(thumb.norm,
                                          in: CGRect(origin: .zero, size: size))
                    if r.width >= 2, r.height >= 2 {
                        Group {
                            if let img = model.thumbnails[thumb.id] {
                                Image(nsImage: img)
                                    .resizable()
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            } else {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: pal.foreground).opacity(0.22))
                            }
                        }
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color(nsColor: pal.foreground).opacity(0.85),
                              lineWidth: 2))
    }
}
