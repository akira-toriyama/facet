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

/// Map a window's logical frame (backend-supplied; Y-down,
/// CG-style) onto a cell rect in the grid view. Both sides are
/// Y-down so it's a straight scale, no vertical flip. GridView
/// itself is flipped so cell-local rects share the same coord
/// convention.
public func gridScaledWindowRect(windowFrame: CGRect,
                                 screenFrame: CGRect,
                                 cellRect: CGRect) -> CGRect {
    guard screenFrame.width > 0, screenFrame.height > 0 else {
        return .zero
    }
    let scaleX = cellRect.width  / screenFrame.width
    let scaleY = cellRect.height / screenFrame.height
    let xRel = (windowFrame.minX - screenFrame.minX) * scaleX
    let yRel = (windowFrame.minY - screenFrame.minY) * scaleY
    return CGRect(x: cellRect.minX + xRel,
                  y: cellRect.minY + yRel,
                  width:  windowFrame.width  * scaleX,
                  height: windowFrame.height * scaleY)
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

/// Short label for a workspace cell — delegates to the shared
/// `workspaceShortLabel` (FacetCore) so grid / rail / tree captions
/// stay identical. Kept as a thin module-local name for the existing
/// call sites + `GridMathTests`.
public func gridLabel(name: String, idx: Int) -> String {
    workspaceShortLabel(name: name, idx: idx)
}
