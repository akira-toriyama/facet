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

/// Cell size that mirrors the display's aspect ratio, shrunk if
/// needed to keep every row + gap inside the available area.
/// `usableW` / `usableH` exclude outer padding.
public func gridCellSize(usableW: CGFloat,
                         usableH: CGFloat,
                         cols: Int,
                         rows: Int,
                         screenAspect: CGFloat) -> CGSize {
    let cs = max(1, cols), rs = max(1, rows)
    let widthAvail  = max(1, usableW - gridCellGap * CGFloat(cs - 1))
    let heightAvail = max(1, usableH - gridCellGap * CGFloat(rs - 1))
    let cellW = widthAvail / CGFloat(cs)
    let cellHByAspect = cellW / max(0.0001, screenAspect)
    let cellHByFit    = heightAvail / CGFloat(rs)
    let cellH = min(cellHByAspect, cellHByFit)
    // Recompute width so aspect stays true even if height was the
    // limiting dimension.
    let finalW = cellH * screenAspect
    return CGSize(width: min(cellW, finalW), height: cellH)
}

/// Map a window's logical frame onto a cell rect in the grid view —
/// delegates to the shared `scaledWindowRect` (FacetCore) so grid /
/// rail mini-thumbnail rects stay identical. Kept as a thin
/// module-local name for the existing call sites + `GridMathTests`.
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

/// Usable cell-area height inside the outer pad. Pure / testable.
public func gridUsableHeight(boundsHeight: CGFloat, outerPad: CGFloat) -> CGFloat {
    boundsHeight - 2 * outerPad
}

/// Y-origin (flipped view, top-down) that centres a `totalH`-tall cell block
/// in the usable area — exactly `(boundsHeight - totalH) / 2`. Pure / testable.
public func gridOriginY(boundsHeight: CGFloat, outerPad: CGFloat,
                        totalH: CGFloat) -> CGFloat {
    outerPad + (gridUsableHeight(boundsHeight: boundsHeight,
                                 outerPad: outerPad) - totalH) / 2
}
