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

    // MARK: - gridRowCount

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

    // MARK: - gridCellSize

    @Test func cellSizeMirrorsScreenAspect() {
        // Standard 16:9 screen, plenty of room → aspect drives.
        let s = gridCellSize(usableW: 1600, usableH: 1000,
                             cols: 2, rows: 1, screenAspect: 16.0 / 9.0)
        #expect(abs(s.width / s.height - 16.0 / 9.0) < 0.001)
    }

    @Test func cellSizeShrinksWhenHeightIsTheLimit() {
        // Tall narrow region → height caps; width recomputed so the
        // aspect doesn't drift even though width could have been
        // larger.
        let s = gridCellSize(usableW: 4000, usableH: 200,
                             cols: 1, rows: 1, screenAspect: 16.0 / 9.0)
        #expect(s.height <= 200)
        #expect(abs(s.width / s.height - 16.0 / 9.0) < 0.001)
    }

    @Test func cellSizeNeverNegative() {
        // Useable area smaller than the inter-cell gap budget — pure
        // math fallback (max(1, …)) keeps values positive.
        let s = gridCellSize(usableW: 1, usableH: 1,
                             cols: 4, rows: 4, screenAspect: 1)
        #expect(s.width > 0)
        #expect(s.height > 0)
    }

    // MARK: - gridScaledWindowRect

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

    // MARK: - board band carve (t-wrd2 — gridUsableHeight / gridOriginY)

    /// With no board band (< 2 boards ⇒ height 0) the carve MUST reduce to the
    /// pre-band vertical placement — the byte-identical guarantee for flat /
    /// single-board configs.
    @Test func boardBandZeroIsByteIdentical() {
        let h: CGFloat = 1000, pad = gridOuterPad, totalH: CGFloat = 600
        #expect(abs(gridUsableHeight(boundsHeight: h, outerPad: pad,
                                     boardBandHeight: 0) - (h - 2 * pad)) < 0.0001)
        // pre-band origin was exactly `(bounds.height - totalH) / 2`.
        #expect(abs(gridOriginY(boundsHeight: h, outerPad: pad,
                                boardBandHeight: 0, totalH: totalH) - (h - totalH) / 2) < 0.0001)
    }

    /// A reserved band shrinks the usable height by exactly its height and
    /// pushes the centred cell block down by half that (re-centred in the
    /// smaller area below the band), never intruding into the band region.
    @Test func boardBandReservesHeightAndShiftsDown() {
        let h: CGFloat = 1000, pad = gridOuterPad, totalH: CGFloat = 600
        let band: CGFloat = 30
        #expect(abs(gridUsableHeight(boundsHeight: h, outerPad: pad,
                                     boardBandHeight: band) - ((h - 2 * pad) - band)) < 0.0001)
        let y0 = gridOriginY(boundsHeight: h, outerPad: pad,
                             boardBandHeight: 0, totalH: totalH)
        let yB = gridOriginY(boundsHeight: h, outerPad: pad,
                             boardBandHeight: band, totalH: totalH)
        #expect(abs(yB - (y0 + band / 2)) < 0.0001)
        // Flipped view: top = small y; the block's top stays below the band.
        #expect(yB >= pad + band - 0.0001)
    }

    // §D: the WS caption (`gridLabel`) was retired in favour of the shared
    // FacetCore `sectionDisplayLabel(index:label:)` — its tests live in
    // `WorkspaceLabelTests`.
}
