// A backend-neutral, per-window hit target inside a mini-thumbnail
// overview cell (grid / rail). Holds the scaled view-space rect plus
// the identity + badge data both the painter and the hit-tester read,
// so paint and click can't drift. Unified from the grid's `WindowHit`
// and the rail's `WinHit`, which carried identical fields.

import CoreGraphics

public struct MiniWindowHit: Sendable {
    public let pid: Int
    public let id: WindowID
    public let isFocused: Bool
    public let rect: CGRect
    public let mark: String?      // user mark (M9-5 #3 corner badge)

    public init(pid: Int, id: WindowID, isFocused: Bool, rect: CGRect,
                mark: String?) {
        self.pid = pid
        self.id = id
        self.isFocused = isFocused
        self.rect = rect
        self.mark = mark
    }
}

/// Map a window's logical frame (backend-supplied; Y-down, CG-style)
/// onto a cell rect in an overview view. Both sides are Y-down so it's
/// a straight scale, no vertical flip — the overview views are flipped,
/// so cell-local rects share the same coord convention. Returns `.zero`
/// for a degenerate (zero-area) screen frame. Shared by the grid + rail
/// mini-thumbnails; the `>= 2` px cull and `MiniWindowHit` construction
/// stay caller-side. Pure / testable.
public func scaledWindowRect(windowFrame: CGRect,
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

/// Sort overview thumbnails into reading order: cluster windows into
/// rows (midY within half the tallest window's height counts as the
/// same row, so a sub-pixel y difference between side-by-side windows
/// can't split them), then order each row left → right and the rows
/// top → bottom. Shared by the grid + rail keyboard navigation and
/// overlay numbering. Pure / testable.
public func readingOrder(_ wins: [MiniWindowHit]) -> [MiniWindowHit] {
    guard wins.count > 1 else { return wins }
    let band = max(1, (wins.map { $0.rect.height }.max() ?? 1) * 0.5)
    let byY = wins.sorted { $0.rect.midY < $1.rect.midY }
    var rows: [[MiniWindowHit]] = []
    for w in byY {
        if let rowY = rows.last?.first?.rect.midY, w.rect.midY - rowY <= band {
            rows[rows.count - 1].append(w)
        } else {
            rows.append([w])
        }
    }
    return rows.flatMap { $0.sorted { $0.rect.midX < $1.rect.midX } }
}
