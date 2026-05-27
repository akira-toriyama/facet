// Pure layout math for the overview grid. No AppKit, no view-side
// state — so each function gets its own unit test against
// known-good outputs (GridMathTests).

import CoreGraphics

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

/// Short label for a workspace cell. Strips a leading "workspace "
/// prefix (case-insensitive) so a user named workspace
/// "WORKSPACE Q" displays as "Q" — matches the Mission Control
/// convention of single-letter cell captions. Empty name → "WS<n>".
public func gridLabel(name: String, idx: Int) -> String {
    if name.isEmpty { return "WS\(idx + 1)" }
    let lower = name.lowercased()
    if lower.hasPrefix("workspace "),
       name.count > "workspace ".count {
        return String(name.dropFirst("workspace ".count))
    }
    return name
}
