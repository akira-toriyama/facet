// Pure layout math for the overview grid. No AppKit, no view-side
// state — so each function gets its own unit test against
// known-good outputs (GridMathTests).

import CoreGraphics
import FacetCore

/// Rows needed to fit `wsCount` workspaces into a grid of `cols`
/// columns. Min 1 row even when there are no workspaces (keeps
/// layout math from dividing by zero downstream).
public func gridRowCount(wsCount: Int, cols: Int) -> Int {
    let c = max(1, cols)
    return max(1, (max(0, wsCount) + c - 1) / c)
}

/// Map a window's logical frame onto a cell rect in the grid view —
/// delegates to the shared `scaledWindowRect` (FacetCore) so grid /
/// rail mini-thumbnail rects stay identical. The SwiftUI cell feeds a
/// UNIT cell rect and scales by the live mini-screen size, so the same
/// function serves both the old absolute and the new normalized layout.
public func gridScaledWindowRect(windowFrame: CGRect,
                                 screenFrame: CGRect,
                                 cellRect: CGRect) -> CGRect {
    scaledWindowRect(windowFrame: windowFrame,
                     screenFrame: screenFrame,
                     cellRect: cellRect)
}

/// Wrap the grid cursor at `index` by `(dx, dy)` in a `cols`-wide,
/// row-major grid of `count` workspaces whose final row may be ragged
/// (M9-4). Horizontal moves wrap within the cursor's row (over the
/// cells that row actually holds); vertical moves wrap within the
/// cursor's column (over the rows that hold that column). The result is
/// always a real index in `0..<count` — a wrap toward a phantom
/// last-row slot snaps to the nearest real cell in that row/column
/// rather than no-opping. dx is tried before dy (arrows are
/// single-axis). Pure / testable.
public func gridWrapIndex(index: Int, dx: Int, dy: Int,
                          cols: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let c0 = max(1, cols)
    let rows = gridRowCount(wsCount: count, cols: c0)
    let i = max(0, min(count - 1, index))
    let r = i / c0, c = i % c0
    let lastRowCells = count - (rows - 1) * c0          // 1…c0
    if dx != 0 {
        // Wrap within the row over its present cells (ragged-safe).
        let rowCells = (r < rows - 1) ? c0 : lastRowCells
        let nc = ((c + dx) % rowCells + rowCells) % rowCells
        return r * c0 + nc
    }
    if dy != 0 {
        // Wrap within the column over the rows that have it. A column
        // past the ragged last row's width skips that phantom slot.
        let colRows = max(1, (c < lastRowCells) ? rows : rows - 1)
        let nr = ((r + dy) % colRows + colRows) % colRows
        return nr * c0 + c
    }
    return i
}

/// What `ThemedGridView.fitsViewport` needs to reproduce the grid's exact
/// old sizing rule: a full-cell `aspect` ratio that bakes in the
/// proportional header band, plus the resolved band height `labelH`.
///
/// The kit fits cells from ONE width/height ratio; the header band is an
/// absolute, clamped height (32…64 pt), so the ratio must be derived
/// against the FINAL cell width. That is a closed form, not a fixed
/// point, because the band height depends only on the ROW count:
///   width-driven:  W = (usableW − gap·(c−1)) / c,
///                  H = W/A + labelH + labelGap   (fits if H ≤ nominal)
///   height-driven: H = nominal, W = (H − labelH − labelGap)·A
/// Either way `aspect = W/H` reproduces (W, H) inside the kit's own
/// `gridFittedCellSize`, and the mini-screen keeps EXACTLY the screen's
/// aspect — the property the whole thumb map rests on. `pad`/`gap` are
/// the kit's own spacing tokens, passed in so this stays pure.
public func gridFitMetrics(availW: CGFloat, availH: CGFloat,
                           cols: Int, count: Int,
                           screenAspect: CGFloat,
                           pad: CGFloat, gap: CGFloat)
    -> (aspect: CGFloat, labelH: CGFloat) {
    let c = max(1, cols)
    let rows = gridRowCount(wsCount: count, cols: c)
    let a = max(0.0001, screenAspect)
    let usableW = max(1, availW - 2 * pad)
    let usableH = max(1, availH - 2 * pad)
    let w = max(1, (usableW - gap * CGFloat(c - 1)) / CGFloat(c))
    let nominal = max(1, (usableH - gap * CGFloat(rows - 1)) / CGFloat(rows))
    let labelH = min(gridHeaderMaxH,
                     max(gridHeaderMinH, (nominal * gridHeaderRatio).rounded()))
    let widthDrivenH = w / a + labelH + gridLabelGap
    if widthDrivenH <= nominal {
        return (aspect: w / widthDrivenH, labelH: labelH)
    }
    let h = nominal
    let w2 = max(1, (h - labelH - gridLabelGap) * a)
    return (aspect: w2 / h, labelH: labelH)
}
