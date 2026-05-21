// Pure-logic helpers for the sidebar's keyboard-nav (`--active`)
// mode. SidebarView's kb methods are thin wrappers around these
// free functions so the index math can be exercised without
// instantiating an NSView or the main actor.

import FacetCore

func kbSelectableIndices(rows: [TreeRow]) -> [Int] {
    rows.indices.filter {
        switch rows[$0].kind {
        case .window, .header: return true
        default:               return false
        }
    }
}

func kbKeyAt(_ i: Int, in rows: [TreeRow]) -> TreeKbSel? {
    guard rows.indices.contains(i) else { return nil }
    switch rows[i].kind {
    case .window(_, _, let id, _): return .win(id)
    case .header(let ws):          return .hdr(workspaceIndex: ws)
    default:                       return nil
    }
}

func kbIndexOf(_ sel: TreeKbSel, in rows: [TreeRow]) -> Int? {
    rows.indices.first {
        switch (sel, rows[$0].kind) {
        case (.win(let id), .window(_, _, let wid, _)):
            return id == wid
        case (.hdr(let a), .header(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Ordered workspace indices as they appear in `rows`.
func kbWsOrder(rows: [TreeRow]) -> [Int] {
    var out: [Int] = []
    for r in rows {
        if case .header(let ws) = r.kind { out.append(ws) }
    }
    return out
}

/// Next selectable index given a sorted `selectable` list and a
/// current row index (NOT the position within `selectable`). Clamped
/// at the ends.
func kbMoveTarget(selectable ids: [Int],
                  current: Int?,
                  delta: Int) -> Int? {
    guard !ids.isEmpty else { return nil }
    let pos = current.flatMap { ids.firstIndex(of: $0) } ?? 0
    return ids[min(max(pos + delta, 0), ids.count - 1)]
}

/// Jump prev/next workspace from `fromWS`: its first window, else
/// its header (empty workspace). Missing `fromWS` → start at
/// position 0 (matches legacy behavior when there is no selection).
func kbJumpTarget(rows: [TreeRow],
                  fromWS curWS: Int?,
                  dir: Int) -> TreeKbSel? {
    let order = kbWsOrder(rows: rows)
    guard !order.isEmpty else { return nil }
    let pos = curWS.flatMap { order.firstIndex(of: $0) } ?? 0
    let ws = order[min(max(pos + dir, 0), order.count - 1)]
    if let wi = rows.firstIndex(where: {
        if case .window(let w, _, _, _) = $0.kind { return w == ws }
        return false
    }) {
        return kbKeyAt(wi, in: rows)
    }
    return .hdr(workspaceIndex: ws)
}
