import Testing
import CoreGraphics
@testable import FacetViewGrid

/// Pure layout-math contract tests. These are the bits of the grid
/// view that are easy to break inadvertently while tuning the
/// visual numbers in `Tunables.swift`.
struct GridMathTests {

    // MARK: - gridWrapIndex (M9-4 wrap nav + ragged snap)

    /// The worked example from the M9-4 design: 7 WS, 3 cols →
    /// Row0 [0 1 2] / Row1 [3 4 5] / Row2 [6 _ _].
    @Test func gridWrapRaggedWorkedExample() {
        let cols = 3, n = 7
        // RIGHT from WS6 (r2c0): phantom → snaps, stays on the row's last
        // real cell (no further right).
        #expect(gridWrapIndex(index: 6, dx: 1, dy: 0, cols: cols, count: n) == 6)
        // DOWN from WS5 (r1c2): phantom in column 2 → wrap to top of the
        // column = WS2.
        #expect(gridWrapIndex(index: 5, dx: 0, dy: 1, cols: cols, count: n) == 2)
        // DOWN from WS2 (r0c2): valid → WS5.
        #expect(gridWrapIndex(index: 2, dx: 0, dy: 1, cols: cols, count: n) == 5)
        // UP from WS6 (r2c0): valid → WS3.
        #expect(gridWrapIndex(index: 6, dx: 0, dy: -1, cols: cols, count: n) == 3)
        // RIGHT from WS2 (r0c2): wraps to WS0.
        #expect(gridWrapIndex(index: 2, dx: 1, dy: 0, cols: cols, count: n) == 0)
    }

    /// Horizontal wrap WITHIN a ragged last row that holds MORE than one
    /// real cell: 8 WS, 3 cols → Row2 = [6 7 _] (lastRowCells = 2).
    /// The `% rowCells` arithmetic must wrap over exactly those 2 cells, not
    /// the full `cols` (which would step onto the phantom index 8). Regression
    /// pins the multi-cell-last-row branch that gridWrapRaggedWorkedExample
    /// (lastRowCells = 1) leaves as a trivial no-op.
    @Test func gridWrapRaggedMultiCellLastRow() {
        // RIGHT from WS7 (r2c1): last real cell → wraps within the 2-cell row
        // back to WS6 (not onto the phantom r2c2).
        #expect(gridWrapIndex(index: 7, dx: 1, dy: 0, cols: 3, count: 8) == 6)
        // LEFT from WS6 (r2c0): wraps within the 2-cell row to WS7.
        #expect(gridWrapIndex(index: 6, dx: -1, dy: 0, cols: 3, count: 8) == 7)
        // Sanity within the same row: RIGHT from WS6 → WS7.
        #expect(gridWrapIndex(index: 6, dx: 1, dy: 0, cols: 3, count: 8) == 7)
    }

    @Test func gridWrapFullGrid() {
        // 6 WS, 3 cols → two full rows; plain modular wrap.
        #expect(gridWrapIndex(index: 2, dx: 1, dy: 0, cols: 3, count: 6) == 0)  // RIGHT wraps
        #expect(gridWrapIndex(index: 0, dx: -1, dy: 0, cols: 3, count: 6) == 2) // LEFT wraps
        #expect(gridWrapIndex(index: 1, dx: 0, dy: 1, cols: 3, count: 6) == 4)  // DOWN
        #expect(gridWrapIndex(index: 4, dx: 0, dy: -1, cols: 3, count: 6) == 1) // UP
        #expect(gridWrapIndex(index: 5, dx: 0, dy: 1, cols: 3, count: 6) == 2)  // DOWN wraps to top
    }

    @Test func gridWrapSingleCellStays() {
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            #expect(gridWrapIndex(index: 0, dx: dx, dy: dy, cols: 4, count: 1) == 0)
        }
    }

    @Test func rowCountFitsOneRowForCountEqualToCols() {
        #expect(gridRowCount(wsCount: 4, cols: 4) == 1)
    }

    @Test func rowCountWrapsToSecondRow() {
        #expect(gridRowCount(wsCount: 5, cols: 4) == 2)
        #expect(gridRowCount(wsCount: 8, cols: 4) == 2)
        #expect(gridRowCount(wsCount: 9, cols: 4) == 3)
    }

    @Test func rowCountClampsToAtLeastOneEvenWhenEmpty() {
        #expect(gridRowCount(wsCount: 0, cols: 4) == 1,
                "1-row floor avoids /0 in downstream layout")
    }

    @Test func rowCountTolerantOfNonsenseCols() {
        #expect(gridRowCount(wsCount: 5, cols: 0) == 5,
                "cols clamps to 1, so 5 workspaces → 5 rows")
        #expect(gridRowCount(wsCount: 5, cols: -3) == 5)
    }

    @Test func scaledWindowRectMapsFullScreenToFullCell() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cell   = CGRect(x: 100, y: 200, width: 384, height: 216)
        let win    = screen
        let mapped = gridScaledWindowRect(
            windowFrame: win, screenFrame: screen, cellRect: cell)
        #expect(mapped == cell)
    }

    @Test func scaledWindowRectPreservesRelativePosition() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cell   = CGRect(x: 0, y: 0, width: 192, height: 108)
        // Window at right-half of screen → right-half of cell.
        let win = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let mapped = gridScaledWindowRect(
            windowFrame: win, screenFrame: screen, cellRect: cell)
        #expect(abs(mapped.minX - 96) < 0.01)
        #expect(abs(mapped.width - 96) < 0.01)
    }

    @Test func scaledWindowRectReturnsZeroForDegenerateScreen() {
        let mapped = gridScaledWindowRect(
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenFrame: .zero,
            cellRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(mapped == .zero)
    }

    // §D: the WS caption (`gridLabel`) was retired in favour of the shared
    // FacetCore `sectionDisplayLabel(index:label:)` — its tests live in
    // `WorkspaceLabelTests`.
}

/// `gridFitMetrics` — the closed form that lets sill's `fitsViewport` grid
/// reproduce the old sizing rule exactly: the returned `aspect`, pushed
/// through the kit's own width-first/height-clamped fit, must yield a cell
/// whose mini-screen area (cell minus the returned band minus the label gap)
/// keeps EXACTLY the screen's aspect.
struct GridFitMetricsTests {

    /// Mirror of sill GridCore's `gridFittedCellSize` (width-first, shrink to
    /// row height, ratio-preserving) — small enough to restate for the test.
    private func kitFit(availW: CGFloat, availH: CGFloat, cols: Int, rows: Int,
                        gap: CGFloat, ratio: CGFloat) -> CGSize {
        let w = max((availW - gap * CGFloat(cols - 1)) / CGFloat(cols), 1)
        let h = w / ratio
        let maxH = max((availH - gap * CGFloat(rows - 1)) / CGFloat(rows), 1)
        guard h > maxH else { return CGSize(width: w, height: h) }
        return CGSize(width: maxH * ratio, height: maxH)
    }

    private func assertRoundTrip(availW: CGFloat, availH: CGFloat,
                                 cols: Int, count: Int, aspect: CGFloat,
                                 pad: CGFloat = 8, gap: CGFloat = 8) {
        let m = gridFitMetrics(availW: availW, availH: availH, cols: cols,
                               count: count, screenAspect: aspect,
                               pad: pad, gap: gap)
        let rows = gridRowCount(wsCount: count, cols: cols)
        let cell = kitFit(availW: availW - 2 * pad, availH: availH - 2 * pad,
                          cols: cols, rows: rows, gap: gap, ratio: m.aspect)
        let miniH = cell.height - m.labelH - 4          // gridLabelGap
        #expect(miniH > 1, "mini-screen collapsed")
        #expect(abs(cell.width / miniH - aspect) < 0.01,
                "mini-screen must keep the screen aspect (got \(cell.width / miniH) want \(aspect))")
        // The band the kit's cell actually leaves for the header is the one
        // we predicted.
        #expect(m.labelH >= 32 && m.labelH <= 64)
    }

    /// Plenty of room → width drives; 16:9 mini-screens.
    @Test func widthDrivenKeepsScreenAspect() {
        assertRoundTrip(availW: 1920, availH: 1080, cols: 4, count: 8,
                        aspect: 16.0 / 9.0)
    }

    /// One wide row on a short screen → the row height caps the cell and the
    /// width is recomputed from the remaining mini height.
    @Test func heightDrivenKeepsScreenAspect() {
        assertRoundTrip(availW: 3840, availH: 500, cols: 2, count: 2,
                        aspect: 16.0 / 9.0)
    }

    /// Many rows shrink the nominal cell; the band clamps at its 32 pt floor
    /// yet the mini-screen still keeps aspect.
    @Test func manyRowsClampBandAtFloor() {
        let m = gridFitMetrics(availW: 1200, availH: 800, cols: 3, count: 12,
                               screenAspect: 16.0 / 9.0, pad: 8, gap: 8)
        #expect(m.labelH == 32)
        assertRoundTrip(availW: 1200, availH: 800, cols: 3, count: 12,
                        aspect: 16.0 / 9.0)
    }

    /// A single huge cell rides the 64 pt ceiling.
    @Test func singleCellClampBandAtCeiling() {
        let m = gridFitMetrics(availW: 1920, availH: 1200, cols: 1, count: 1,
                               screenAspect: 16.0 / 9.0, pad: 8, gap: 8)
        #expect(m.labelH == 64)
    }

    /// Degenerate inputs stay positive (the old `max(1, …)` discipline).
    @Test func degenerateInputsStayPositive() {
        let m = gridFitMetrics(availW: 10, availH: 10, cols: 4, count: 9,
                               screenAspect: 1, pad: 8, gap: 8)
        #expect(m.aspect > 0)
    }
}
