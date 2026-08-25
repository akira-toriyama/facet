// The full-screen workspace rail, SwiftUI — a solid backdrop, the centre
// HERO preview, the edge-docked carousel STRIP, and the drag / border /
// commit-zoom layers. Host-side by decision (t-n3be): no sill grid kit
// underneath — the carousel geometry is the pure `railLayout`, the cell
// chrome is composed here from the sill role palette, and sill supplies
// the window shell (Controller) + the `[border]` neon frame
// (`AnimatedBorderView`).
//
// Split of responsibilities (mirrors the grid):
//   VM    — layout, carousel state, drags, keyboard verbs, zoom, gates
//   view  — pure rendering + the pointer gestures (tap / thumb drag /
//           header reorder drag); keys and scroll arrive via the
//           Controller's monitors, never SwiftUI focus (tree invariant)

import SwiftUI
import AppKit
import FacetCore
import FacetView
import Palette
import PaletteKit
import Effects
import ThemeKitUI

/// The named coordinate space every drag location uses — owned by the
/// root stack (the overlay is full-screen, so it equals rail space).
let facetRailSpace = "facetRailSpace"

public struct RailContentView: View {
    let model: RailViewModel

    public init(model: RailViewModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Backdrop — solid black hides the desktop.
                Color.black.opacity(railBackdropAlpha)
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapBackdrop() }

                railLayers
                    // Commit zoom draws EXCLUSIVELY (the old early-return)
                    // and swallows input.
                    .opacity(model.zoom == nil ? 1 : 0)
                    .allowsHitTesting(model.zoom == nil)

                ghostLayer

                if model.borderEffect != nil {
                    borderLayer
                        .allowsHitTesting(false)
                }

                zoomLayer(geo.size)
            }
            .coordinateSpace(name: facetRailSpace)
            .onAppear { model.viewSize = geo.size }
            .onChange(of: geo.size) { _, s in model.viewSize = s }
        }
        .ignoresSafeArea()
    }

    // MARK: - Hero + strip

    @ViewBuilder private var railLayers: some View {
        let lay = model.layout
        ZStack(alignment: .topLeading) {
            // Hero — the centred section, large. Its empty area is a focal
            // preview, not a target: the tap swallows so the backdrop
            // beneath can't dismiss.
            if let hero = model.heroCell, lay.heroRect != .zero {
                RailMiniScreen(model: model, cell: hero, isHero: true,
                               rect: lay.heroRect)
                    .frame(width: lay.heroRect.width, height: lay.heroRect.height)
                    .position(x: lay.heroRect.midX, y: lay.heroRect.midY)
            }
            // Browse crossfade: the previous hero fades out over the new
            // one as the rotation eases in.
            if let prev = model.prevHeroImage, model.slideProgress < 1 {
                Image(nsImage: prev)
                    .resizable()
                    .frame(width: model.prevHeroRect.width,
                           height: model.prevHeroRect.height)
                    .position(x: model.prevHeroRect.midX,
                              y: model.prevHeroRect.midY)
                    .opacity(max(0, 1 - model.slideProgress))
                    .allowsHitTesting(false)
            }

            stripLayer(lay)
        }
    }

    /// The carousel strip: cells clipped to the viewport (a rotating cell
    /// "peeks" at the ends), translated along the run while a rotation
    /// eases in. The reorder insertion line draws inside the same clip.
    @ViewBuilder private func stripLayer(_ lay: RailLayout) -> some View {
        let horizontal = model.config.edge.axis == .horizontal
        ZStack(alignment: .topLeading) {
            ForEach(Array(lay.placements.enumerated()), id: \.offset) { _, pl in
                if model.cells.indices.contains(pl.sourceIndex) {
                    let cell = model.cells[pl.sourceIndex]
                    RailHeaderView(model: model, cell: cell,
                                   bandH: pl.headerRect.height)
                        .frame(width: pl.headerRect.width,
                               height: pl.headerRect.height)
                        .position(x: pl.headerRect.midX, y: pl.headerRect.midY)
                    RailMiniScreen(model: model, cell: cell, isHero: false,
                                   rect: pl.cellRect)
                        .frame(width: pl.cellRect.width, height: pl.cellRect.height)
                        .position(x: pl.cellRect.midX, y: pl.cellRect.midY)
                }
            }
            // Section-reorder insertion line with end caps (tree/grid mirror).
            if let d = model.drag, case .reorder = d.kind,
               let line = d.reorderLine {
                let accent = Color(nsColor: model.palette.primary)
                Path { p in
                    p.move(to: line.a)
                    p.addLine(to: line.b)
                }
                .stroke(accent, lineWidth: 3)
                Circle().fill(accent).frame(width: 6, height: 6)
                    .position(line.a)
                Circle().fill(accent).frame(width: 6, height: 6)
                    .position(line.b)
            }
        }
        .offset(x: horizontal ? model.slideOffset : 0,
                y: horizontal ? 0 : model.slideOffset)
        .clipShape(RectClipShape(rect: lay.stripRect))
    }

    // MARK: - Drag ghosts (host-drawn — there is no kit under the rail)

    @ViewBuilder private var ghostLayer: some View {
        if let g = model.windowGhost {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            ZStack {
                if let img = g.image {
                    shape.fill(Color.black.opacity(0.15))
                    Image(nsImage: img)
                        .resizable()
                        .clipShape(shape)
                } else {
                    // Captures-only: no app-icon fallback — a not-yet-
                    // captured window lifts as a plain accent tile.
                    shape.fill(Color(nsColor: model.palette.primary).opacity(0.45))
                }
                shape.stroke(Color(nsColor: model.palette.primary), lineWidth: 1.5)
            }
            .frame(width: g.size.width, height: g.size.height)
            .scaleEffect(1.06)                       // the dnd-kit "lift"
            .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
            .position(g.location)
            .allowsHitTesting(false)
        }
        if let g = model.workspaceGhost {
            RailWorkspaceGhost(model: model, cell: g.cell, size: g.size)
                .frame(width: g.size.width, height: g.size.height)
                .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
                .position(g.location)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Border (`[border]` — sill's AnimatedBorderView)

    private var borderLayer: some View {
        var border = AnimatedBorderView(
            palette: model.palette,
            effect: model.borderEffect,
            in: Rectangle(),                          // square screen frame
            lineWidth: model.borderLineWidth,
            breathTo: model.borderBreathTo,
            cycleSeconds: model.borderCycleSeconds,
            glow: model.borderGlow ? .bloom : .none,
            flashToken: model.borderFlashToken)
        border.cyclesColors = model.borderCyclesColors
        return border
    }

    // MARK: - Commit zoom (hero → full screen)

    @ViewBuilder private func zoomLayer(_ size: CGSize) -> some View {
        if let z = model.zoom {
            let expanded = model.zoomExpanded
            Image(nsImage: z.image)
                .resizable()
                .frame(width: expanded ? size.width : z.from.width,
                       height: expanded ? size.height : z.from.height)
                .position(x: expanded ? size.width / 2 : z.from.midX,
                          y: expanded ? size.height / 2 : z.from.midY)
                .onAppear {
                    withAnimation(.easeOut(duration: overviewCommitZoomDuration),
                                  completionCriteria: .logicallyComplete) {
                        model.zoomExpanded = true
                    } completion: {
                        model.finishZoom()
                    }
                }
        }
    }
}

/// Clip to an absolute rect in the container's own space (the carousel
/// viewport — SwiftUI's `.clipped` clips to bounds, not a sub-rect).
struct RectClipShape: Shape {
    let rect: CGRect
    func path(in _: CGRect) -> Path { Path(rect) }
}
