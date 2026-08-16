// One grid cell's CONTENT — the host-composed mini-screen the sill
// `ThemedGridView` wraps in its chrome: the proportional workspace header
// band plus the scaled window thumbs. The host's own gestures live on the
// content (inner gestures win), so a tap is facet's instant pick and a
// thumb drag is facet's window move — sill's cell-level tap/drag never
// fire from these, and its focus ring never engages (the tree invariant).

import SwiftUI
import AppKit
import FacetCore
import FacetView
import ThemeKitUI
import PaletteKit
import Palette

/// The named coordinate space every reported frame + drag location uses —
/// owned by `GridContentView`'s root stack.
let facetGridSpace = "facetGridSpace"

/// Frames the cells report up (cell chrome box / mini-screen / header band),
/// keyed by sectionID — menus, zoom, the kb ghost and right-click hit tests
/// all read these back off the view model.
struct GridGeomPref: Equatable {
    var cell: [String: CGRect] = [:]
    var mini: [String: CGRect] = [:]
    var header: [String: CGRect] = [:]
}

struct GridGeomKey: PreferenceKey {
    static let defaultValue = GridGeomPref()
    static func reduce(value: inout GridGeomPref, nextValue: () -> GridGeomPref) {
        let n = nextValue()
        value.cell.merge(n.cell) { _, b in b }
        value.mini.merge(n.mini) { _, b in b }
        value.header.merge(n.header) { _, b in b }
    }
}

struct GridCellContent: View {
    let model: GridViewModel
    let cell: GridCellVM
    let state: GridCellState
    let bandH: CGFloat

    private var pal: PaletteKit.ResolvedPalette { model.palette }

    var body: some View {
        VStack(spacing: gridLabelGap) {
            if model.config.labelPosition == "down" {
                miniScreen
                header
            } else {
                header
                miniScreen
            }
        }
        .background {
            // Active wash — the lit cell (old `activeFill`); sill's chrome
            // doesn't know "active", so the host paints it under its content.
            if cell.isActive {
                RoundedRectangle(cornerRadius: CGFloat(Radius.lg), style: .continuous)
                    .fill(Color(nsColor: pal.primary).opacity(0.10))
                RoundedRectangle(cornerRadius: CGFloat(Radius.lg), style: .continuous)
                    .strokeBorder(Color(nsColor: pal.primary).opacity(0.7), lineWidth: 1)
            }
        }
        .overlay {
            // Keyboard cell cursor — accent for the active WS, secondary for
            // a browse target (rail parity). Hidden while lifted (the drop
            // ring shows the aim then).
            if model.drag == nil, model.kbCursorID == cell.id {
                RoundedRectangle(cornerRadius: CGFloat(Radius.lg), style: .continuous)
                    .inset(by: 1.5)
                    .stroke(Color(nsColor: cell.isActive ? pal.primary : pal.secondary),
                            lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        // Empty-area / header click = instant workspace pick (no zoom — the
        // direct mouse click stays instant). Inner gesture: sill's own tap
        // (and with it its focus/cursor state) never fires.
        .gesture(TapGesture().onEnded { model.tapCell(cell.id) })
        .background(GeometryReader { g in
            Color.clear.preference(
                key: GridGeomKey.self,
                value: GridGeomPref(cell: [cell.id: g.frame(in: .named(facetGridSpace))]))
        })
    }

    @ViewBuilder private var header: some View {
        GridHeaderView(model: model, cell: cell, bandH: bandH)
            .background(GeometryReader { g in
                Color.clear.preference(
                    key: GridGeomKey.self,
                    value: GridGeomPref(header: [cell.id: g.frame(in: .named(facetGridSpace))]))
            })
    }

    @ViewBuilder private var miniScreen: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(Array(cell.thumbs.enumerated()), id: \.element.id) { ti, thumb in
                    let r = absRect(thumb.norm, in: g.size)
                    // The ≥2 px cull the old layout applied at layout time.
                    if r.width >= 2, r.height >= 2, model.hiddenThumbID != thumb.id {
                        GridThumbView(model: model, cell: cell, thumb: thumb,
                                      thumbIndex: ti, rect: r)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                }
            }
            // FLIP: a thumb whose rect changed inside a STABLE scaffold
            // slides to its new rect; the `.id(structuralEpoch)` on the
            // container resets identity on a structural re-layout, so those
            // snap instead (t-3q17).
            .animation(.easeOut(duration: gridReorderDuration), value: cell.thumbs)
        }
        .clipped()
        .id(model.structuralEpoch)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { g in
            Color.clear.preference(
                key: GridGeomKey.self,
                value: GridGeomPref(mini: [cell.id: g.frame(in: .named(facetGridSpace))]))
        })
    }

    private func absRect(_ norm: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: norm.minX * size.width, y: norm.minY * size.height,
               width: norm.width * size.width, height: norm.height * size.height)
    }
}

/// One window mini-rect: fill → capture image (stretch, like the AppKit
/// painter) or the app-icon fallback → hairline stroke → mark badge →
/// keyboard window ring. Tap = pick; drag = the host window move.
struct GridThumbView: View {
    let model: GridViewModel
    let cell: GridCellVM
    let thumb: GridThumbVM
    let thumbIndex: Int
    let rect: CGRect

    private var pal: PaletteKit.ResolvedPalette { model.palette }

    /// Is the keyboard window cursor on THIS thumb?
    private var isKbSelected: Bool {
        guard model.drag == nil, let s = model.kbSelectedThumb else { return false }
        return s.cell.id == cell.id && s.thumb.id == thumb.id
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            shape.fill(Color(nsColor: thumb.isFocused ? pal.primary : pal.foreground)
                .opacity(thumb.isFocused ? 0.32 : 0.18))
            if let img = model.thumbnails[thumb.id] {
                // Stretch into the thumb rect — the old `img.draw(in:)`
                // behaviour, no aspect fit.
                Image(nsImage: img)
                    .resizable()
                    .clipShape(shape)
            } else {
                // No capture yet — the app icon (12…48 pt, centred).
                let side = max(12, min(min(rect.width, rect.height) - 8, 48))
                if side >= 12, let icon = AppIcons.icon(forPID: thumb.pid) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: side, height: side)
                        .opacity(0.95)
                }
            }
            shape.stroke(Color(nsColor: pal.foreground).opacity(0.45), lineWidth: 0.5)
        }
        .overlay(alignment: .topLeading) {
            if let mark = thumb.mark, !mark.isEmpty {
                GridMarkBadge(mark: mark, rect: rect, pal: pal)
                    .padding(2)
            }
        }
        .overlay {
            if isKbSelected {
                // Accent fill + ring over the window front (rail parity) so
                // the Space-lift target is unmistakable.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .inset(by: 1)
                    .fill(Color(nsColor: pal.primary).opacity(0.30))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .inset(by: 1)
                    .stroke(Color(nsColor: pal.primary), lineWidth: 2.5)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: pointerDragThreshold,
                        coordinateSpace: .named(facetGridSpace))
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

/// The tiny window-mark badge: an accent pill with the mark text when it
/// fits, else just an accent dot — a marked window stays signalled even in
/// the smallest cells (M9-5 #3, mirrors the AppKit `drawMiniMarkBadge`).
struct GridMarkBadge: View {
    let mark: String
    let rect: CGRect
    let pal: PaletteKit.ResolvedPalette

    var body: some View {
        // The AppKit painter measured the text; a ~5 pt/char estimate keeps
        // this pure — marks are 1–2 chars, so the fit call matches.
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
