// Pure carousel-geometry contract tests for `railLayout` — the extracted
// geometry half of the old AppKit `layoutCells`, checked against the same
// invariants that painter enforced by construction: justified thumbs
// capped by the `[rail] strip` band, exact screen aspect, the selected
// cell pinned to the strip centre, the even-count wrap-peek ghost, and
// the strip-free, screen-centred hero.

import Testing
import CoreGraphics
import FacetCore
@testable import FacetViewRail

struct RailMathTests {

    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func layout(count: Int, edge: RailEdge = .bottom,
                        cells: Int = 7, strip: Int = 30,
                        selected: Int = 0) -> RailLayout {
        railLayout(bounds: bounds, edge: edge, screen: screen,
                   count: count, cellsTarget: cells, stripPercent: strip,
                   selectedPos: selected)
    }

    @Test func emptyAndDegenerateInputsAreEmpty() {
        #expect(railLayout(bounds: .zero, edge: .bottom, screen: .zero,
                           count: 0, cellsTarget: 7, stripPercent: 30,
                           selectedPos: 0) == .empty)
        #expect(railLayout(bounds: bounds, edge: .bottom, screen: screen,
                           count: 0, cellsTarget: 7, stripPercent: 30,
                           selectedPos: 0) == .empty)
    }

    @Test func bottomEdgeAnatomy() {
        let lay = layout(count: 3)
        #expect(lay.placements.count == 3)          // odd count → no ghost
        // Strip band docks at the bottom; hero sits fully above it.
        for pl in lay.placements {
            #expect(pl.cellRect.maxY <= bounds.maxY)
            #expect(pl.headerRect.maxY <= pl.cellRect.minY)   // header above thumb
            #expect(lay.heroRect.maxY <= pl.headerRect.minY)
        }
        // The mini-screen keeps the SCREEN's aspect exactly.
        let a = screen.width / screen.height
        for pl in lay.placements {
            let cellA = pl.cellRect.width / pl.cellRect.height
            #expect(abs(cellA - a) < 0.01)
        }
        let heroA = lay.heroRect.width / lay.heroRect.height
        #expect(abs(heroA - a) < 0.01)
        // Hero centres on the screen midline.
        #expect(abs(lay.heroRect.midX - bounds.midX) <= 1)
    }

    @Test func selectedCellPinsToStripCentre() {
        for sel in 0..<5 {
            let lay = layout(count: 5, selected: sel)
            let centre = lay.placements.first { $0.sourceIndex == sel && !$0.isWrapGhost }!
            #expect(centre.offset == 0)
            #expect(abs(centre.cellRect.midX - lay.stripRect.midX) <= lay.slot / 2)
        }
    }

    @Test func evenFullCountAddsWrapPeekGhost() {
        let lay = layout(count: 4, selected: 0)
        // 4 real placements + 1 ghost mirroring the far-left cell at +n/2.
        #expect(lay.placements.count == 5)
        let ghost = lay.placements.last!
        #expect(ghost.isWrapGhost)
        #expect(ghost.offset == 2)
        let farLeft = lay.placements.first { $0.offset == -2 && !$0.isWrapGhost }!
        #expect(ghost.sourceIndex == farLeft.sourceIndex)
        // Overflow (n > visible): the natural ±cells already peek — no ghost.
        #expect(layout(count: 8, cells: 7).placements.count == 8)
        // Odd full count: no ghost either.
        #expect(layout(count: 5).placements.count == 5)
    }

    @Test func overflowCapsViewportWithPeek() {
        let lay = layout(count: 12, cells: 5)
        // Viewport = 5 slots + both-ends peek, capped by the padded run.
        let expected = min(bounds.width - 2 * 35,     // outer = round(1000*0.035)
                           5 * lay.slot + 2 * 18)
        #expect(abs(lay.stripRect.width - expected) <= 1)
        // Cells beyond the viewport still exist (they rotate through).
        #expect(lay.placements.count == 12)
        #expect(lay.placements.contains { !lay.stripRect.intersects($0.cellRect) })
    }

    @Test func stripPercentCapsThumbScale() {
        let small = layout(count: 2, strip: 12)
        let large = layout(count: 2, strip: 40)
        let smallH = small.placements[0].cellRect.height
        let largeH = large.placements[0].cellRect.height
        #expect(smallH < largeH)
        // The capped band bounds the whole block: float + header + gap + thumb.
        let shortEdge = min(screen.width, screen.height)
        let bandCap = shortEdge * 12 / 100
        #expect(small.headerH + smallH + 6 <= bandCap + 1)
    }

    @Test func topEdgeMirrorsBottom() {
        let lay = layout(count: 3, edge: .top)
        for pl in lay.placements {
            #expect(pl.headerRect.minY >= bounds.minY)
            #expect(pl.headerRect.maxY <= pl.cellRect.minY)   // header still above
            #expect(lay.heroRect.minY >= pl.cellRect.maxY)    // hero below strip
        }
        #expect(lay.stripRect.minY == bounds.minY)
    }

    @Test func verticalEdgesRunTopToBottom() {
        let left = layout(count: 4, edge: .left)
        #expect(left.stripRect.minX == bounds.minX)
        #expect(left.heroRect.minX >= left.stripRect.maxX - 1)
        // Cells stack along Y; the selected (offset 0) centres vertically.
        let centre = left.placements.first { $0.offset == 0 && !$0.isWrapGhost }!
        #expect(abs(centre.cellRect.midY - left.stripRect.midY) <= left.slot / 2)

        let right = layout(count: 4, edge: .right)
        #expect(abs(right.stripRect.maxX - bounds.maxX) <= 1)
        #expect(right.heroRect.maxX <= right.stripRect.minX + 1)
    }

    @Test func placementsAreSlotSpaced() {
        let lay = layout(count: 5)
        let sorted = lay.placements.sorted { $0.offset < $1.offset }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let d = b.cellRect.midX - a.cellRect.midX
            #expect(abs(d - lay.slot * CGFloat(b.offset - a.offset)) <= 1)
        }
    }
}
