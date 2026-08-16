// The full-screen overview grid, SwiftUI — sill's `ThemedGridView` fitted
// to the viewport (t-mej6 G1) with facet's mini-screen cells as content.
//
// Split of responsibilities:
//   sill kit   — fit layout, cell chrome (rest/hover), the POINTER cell
//                drag as a section REORDER (insertion line, real-cell
//                ghost, escape margin), and the drag-pose rendering for
//                the host's own drags via the `GridPreview` seam.
//   host       — the backdrop, the window-thumb move drag + its ghost,
//                the keyboard model (cell cursor / window slots / lifts —
//                fed by the Controller's local monitor; sill's own key
//                handling and focus never engage, the tree invariant),
//                the commit zoom (②), and the `[border]` neon frame
//                (sill's `AnimatedBorderView`).

import SwiftUI
import AppKit
import FacetCore
import FacetView
import Palette
import PaletteKit
import Effects
import GridCore
import ThemeKitUI

public struct GridContentView: View {
    let model: GridViewModel

    public init(model: GridViewModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Solid near-black backdrop (the old host view's layer).
                Color.black.opacity(gridBackdropAlpha)
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapBackdrop() }

                gridLayer(geo.size)
                    // Commit zoom draws EXCLUSIVELY (the old early-return) —
                    // and swallows input: opacity alone would leave the kit's
                    // gestures hit-testable under the zoom.
                    .opacity(model.zoom == nil ? 1 : 0)
                    .allowsHitTesting(model.zoom == nil)

                ghostLayer

                // Screen-edge neon frame — above the cells (old zPosition
                // 1000), only while an effect is active (no border when off).
                if model.borderEffect != nil {
                    borderLayer
                        .allowsHitTesting(false)
                }

                zoomLayer(geo.size)
            }
            .coordinateSpace(name: facetGridSpace)
            .onPreferenceChange(GridGeomKey.self) { pref in
                model.cellFrames = pref.cell
                model.miniFrames = pref.mini
                model.headerFrames = pref.header
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Grid

    @ViewBuilder private func gridLayer(_ size: CGSize) -> some View {
        let cols = model.effectiveCols
        let aspect = model.screenFrame.height > 0
            ? model.screenFrame.width / model.screenFrame.height
            : 16.0 / 9.0
        let metrics = gridFitMetrics(
            availW: size.width, availH: size.height,
            cols: cols, count: model.cells.count,
            screenAspect: aspect,
            pad: CGFloat(Space.md), gap: CGFloat(Space.md))

        ThemedGridView(
            model.cells, id: \.id,
            layout: .fixed(columns: cols),
            aspectRatio: metrics.aspect,
            palette: model.palette,
            allowsMultiSelect: false
        ) { cell, state in
            GridCellContent(model: model, cell: cell, state: state,
                            bandH: metrics.labelH)
        }
        .fitsViewport()
        .takesKeyboardFocus(false)     // host-driven keyboard (the tree invariant)
        .draggable(.reorderAt)
        .onGridDrop { ctx, target in
            // The kit's pointer reorder: display-only, session-only — the
            // Controller mutates the per-mac-desktop order and re-renders.
            if case .at(let boundary) = target.placement {
                model.commitReorder(sectionID: ctx.sourceID, toBoundary: boundary)
            }
        }
        .preview(model.kitPreview)
    }

    // MARK: - Host window-drag ghost (the kit's cell ghost covers the swap)

    @ViewBuilder private var ghostLayer: some View {
        if let g = model.windowGhost {
            let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
            ZStack {
                shape.fill(Color(nsColor: model.palette.foreground).opacity(0.18))
                if let img = g.image {
                    Image(nsImage: img)
                        .resizable()
                        .clipShape(shape)
                }
                shape.stroke(Color(nsColor: model.palette.primary), lineWidth: 1)
            }
            .frame(width: g.size.width, height: g.size.height)
            .scaleEffect(1.06)                       // the dnd-kit "lift"
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .opacity(0.9)
            .position(g.location)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Border

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
        // Colour cycling stays the explicit `[border] cycle-seconds` opt-in;
        // a bare effect rests on its steady hue (the BorderFX contract).
        border.cyclesColors = model.borderCyclesColors
        return border
    }

    // MARK: - Commit zoom (②)

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
