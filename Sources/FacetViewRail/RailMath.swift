// Pure layout math for the SwiftUI rail — the geometry half of the old
// AppKit `RailView.layoutCells`, extracted so it unit-tests without a
// display (RailMathTests). Coordinates are top-left/y-down, the same
// convention the old flipped NSView used, so the numbers carry over 1:1.
//
// The primitive inputs (`railBands` / `railCarouselOffsets` /
// `railScaledPads` / `wheelSteps`) stay in FacetCore; this file composes
// them with the rail's tunables into concrete cell / hero rects.

import CoreGraphics
import FacetCore

/// One strip cell's resolved placement. `sourceIndex` points into the
/// section source list; the even-count wrap-peek ghost repeats a source
/// at the mirrored offset (`isWrapGhost` — draw-only, never hit-tested
/// first: it sits past the far viewport edge).
public struct RailCellPlacement: Equatable, Sendable {
    public let sourceIndex: Int
    public let offset: Int          // signed carousel slots from centre
    public let cellRect: CGRect     // mini-screen (thumb) box
    public let headerRect: CGRect   // header band above the thumb
    public let isWrapGhost: Bool
}

/// The rail's full resolved geometry for one (bounds, selection) state.
public struct RailLayout: Equatable, Sendable {
    public let placements: [RailCellPlacement]
    public let heroRect: CGRect     // .zero when the hero box degenerates
    public let stripRect: CGRect    // carousel viewport (clip + hit gate)
    public let slot: CGFloat        // one rotation slides the strip this far
    public let headerH: CGFloat

    public static let empty = RailLayout(placements: [], heroRect: .zero,
                                         stripRect: .zero, slot: 0, headerH: 0)
}

/// Compute the strip + hero geometry: the justified, band-capped thumb
/// sizing, the active-centred carousel placement (+ the even-count
/// wrap-peek ghost), and the screen-centred aspect-fit hero. Pure —
/// same inputs, same output.
public func railLayout(bounds: CGRect, edge: RailEdge, screen: CGRect,
                       count: Int, cellsTarget: Int, stripPercent: Int,
                       selectedPos: Int) -> RailLayout {
    guard count > 0, bounds.width > 1, bounds.height > 1 else { return .empty }
    let useScreen = screen.width > 1 ? screen : bounds
    let aspect = useScreen.width / max(1, useScreen.height)
    let horizontal = edge.axis == .horizontal

    let shortEdge = min(useScreen.width, useScreen.height)
    let (edgeFloat, heroGap, outer) = railScaledPads(
        screen: useScreen.size,
        edgeFloatFrac: railEdgeFloatFrac,
        heroGapFrac: railHeroGapFrac,
        outerFrac: railOuterFrac)
    let n = count
    let alongFull = horizontal ? bounds.width : bounds.height
    let availAlong = max(1, alongFull - outer * 2)
    let visible = max(1, min(cellsTarget, max(1, n)))

    // Justified thumbs: grow to fill the run with one gap between cells,
    // capped by the `[rail] strip` band (then the group centres).
    let bandCap = max(railCellMinDim,
                      (shortEdge * CGFloat(stripPercent) / 100) - edgeFloat)
    let justRun = max(railCellMinDim,
                      (availAlong - CGFloat(visible + 1) * railCellGap) / CGFloat(visible))
    let thumbH: CGFloat, thumbW: CGFloat, headerH: CGFloat
    let blockCross: CGFloat, cellRun: CGFloat
    if horizontal {
        headerH = min(railHeaderMaxH,
                      max(railHeaderMinH, (bandCap * railHeaderRatio).rounded()))
        let maxThumbH = max(railCellMinDim, bandCap - headerH - railLabelGap)
        let th = min(justRun / aspect, maxThumbH)
        thumbH = th
        thumbW = th * aspect
        blockCross = headerH + railLabelGap + th
        cellRun = thumbW
    } else {
        headerH = min(railHeaderMaxH,
                      max(railHeaderMinH, (justRun * railHeaderRatio).rounded()))
        let availH = max(railCellMinDim, justRun - headerH - railLabelGap)
        let tw = min(availH * aspect, bandCap)
        thumbW = tw
        thumbH = tw / aspect
        blockCross = tw
        cellRun = headerH + railLabelGap + thumbH
    }
    let blockH = headerH + railLabelGap + thumbH
    let thickness = (edgeFloat + blockCross).rounded()

    let peek: CGFloat = n > visible ? railPeek : 0
    let slot = max(railCellMinDim, cellRun + railCellGap)
    let viewportAlong = min(availAlong, CGFloat(visible) * slot + 2 * peek)

    let (strip, heroArea) = railBands(in: bounds, edge: edge,
                                      thickness: thickness,
                                      outerPad: outer,
                                      heroGap: heroGap)
    let stripRect = horizontal
        ? CGRect(x: (strip.midX - viewportAlong / 2).rounded(), y: strip.minY,
                 width: viewportAlong, height: strip.height)
        : CGRect(x: strip.minX, y: (strip.midY - viewportAlong / 2).rounded(),
                 width: strip.width, height: viewportAlong)

    let offsets = railCarouselOffsets(count: n, selectedPos: selectedPos)
    let alongCentre = horizontal ? strip.midX : strip.midY
    let blockOuter: CGFloat, innerEdge: CGFloat
    switch edge {
    case .bottom: blockOuter = strip.maxY - edgeFloat - blockCross; innerEdge = blockOuter
    case .top:    blockOuter = strip.minY + edgeFloat;              innerEdge = blockOuter + blockCross
    case .left:   blockOuter = strip.minX + edgeFloat;              innerEdge = blockOuter + blockCross
    case .right:  blockOuter = strip.maxX - edgeFloat - blockCross; innerEdge = blockOuter
    }

    func place(_ sourceIndex: Int, offset: Int, ghost: Bool) -> RailCellPlacement {
        let slotStart = alongCentre + CGFloat(offset) * slot - slot / 2
        let blockX: CGFloat, blockY: CGFloat
        if horizontal {
            blockX = slotStart + (slot - thumbW) / 2
            blockY = blockOuter
        } else {
            blockX = blockOuter
            blockY = slotStart + (slot - blockH) / 2
        }
        // Header band always sits above the thumb (every edge).
        let headerY = blockY
        let thumbY = blockY + headerH + railLabelGap
        return RailCellPlacement(
            sourceIndex: sourceIndex, offset: offset,
            cellRect: CGRect(x: blockX.rounded(), y: thumbY.rounded(),
                             width: thumbW, height: thumbH),
            headerRect: CGRect(x: blockX.rounded(), y: headerY.rounded(),
                               width: thumbW, height: headerH),
            isWrapGhost: ghost)
    }
    var placements = offsets.indices.map { place($0, offset: offsets[$0], ghost: false) }
    // Both-ends peek symmetry: for an EVEN count with every cell shown,
    // the far-left cell (offset −n/2) also draws at +n/2 as a wrap ghost
    // so the strip's ends mirror.
    if n % 2 == 0, n > 1, n == visible,
       let li = offsets.firstIndex(of: -(n / 2)) {
        placements.append(place(li, offset: n / 2, ghost: true))
    }

    // Hero: pull the strip-side boundary in to the cells' inner edge,
    // aspect-fit, centre on the screen, clamp into the strip-free box.
    var heroBox = heroArea
    switch edge {
    case .bottom:
        heroBox.size.height = max(0, (innerEdge - heroGap) - heroBox.minY)
    case .top:
        let top = innerEdge + heroGap
        heroBox = CGRect(x: heroBox.minX, y: top,
                         width: heroBox.width, height: max(0, heroBox.maxY - top))
    case .left:
        let left = innerEdge + heroGap
        heroBox = CGRect(x: left, y: heroBox.minY,
                         width: max(0, heroBox.maxX - left), height: heroBox.height)
    case .right:
        heroBox.size.width = max(0, (innerEdge - heroGap) - heroBox.minX)
    }
    var heroRect = CGRect.zero
    if heroBox.width > 1, heroBox.height > 1 {
        var hCellW = heroBox.width
        var hCellH = heroBox.height
        if hCellW / hCellH > aspect { hCellW = hCellH * aspect }
        else { hCellH = hCellW / aspect }
        let hx = min(max(bounds.midX - hCellW / 2, heroBox.minX),
                     heroBox.maxX - hCellW).rounded()
        let hy = min(max(bounds.midY - hCellH / 2, heroBox.minY),
                     heroBox.maxY - hCellH).rounded()
        heroRect = CGRect(x: hx, y: hy, width: hCellW, height: hCellH)
    }
    return RailLayout(placements: placements, heroRect: heroRect,
                      stripRect: stripRect, slot: slot, headerH: headerH)
}
