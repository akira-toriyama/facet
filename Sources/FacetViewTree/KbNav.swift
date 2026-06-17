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
    case .window(let g, _, _, let id, _): return .win(group: g, id)
    case .header(let g, _):               return .hdr(group: g)
    default:                              return nil
    }
}

func kbIndexOf(_ sel: TreeKbSel, in rows: [TreeRow]) -> Int? {
    rows.indices.first {
        switch (sel, rows[$0].kind) {
        case (.win(let g, let id), .window(let rg, _, _, let wid, _)):
            // The group disambiguates the same window shown in several
            // sections (multi-match); in the degrade path group == ws.index
            // so this stays a single match per window.
            return g == rg && id == wid
        case (.hdr(let a), .header(let b, _)):
            return a == b
        default:
            return false
        }
    }
}

/// Ordered render-group ordinals as they appear in `rows` (= the prev/next
/// "jump" order). In the by-workspace degrade these are the workspace
/// indices, so the jump behaves identically.
func kbWsOrder(rows: [TreeRow]) -> [Int] {
    var out: [Int] = []
    for r in rows {
        if case .header(let g, _) = r.kind { out.append(g) }
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

/// Jump prev/next render group from `fromGroup`: its first window, else
/// its header (empty group). Missing `fromGroup` → start at position 0
/// (matches legacy behavior when there is no selection). In the degrade
/// path the group ordinals are workspace indices, so this is the original
/// "jump prev/next workspace".
func kbJumpTarget(rows: [TreeRow],
                  fromWS curGroup: Int?,
                  dir: Int) -> TreeKbSel? {
    let order = kbWsOrder(rows: rows)
    guard !order.isEmpty else { return nil }
    let pos = curGroup.flatMap { order.firstIndex(of: $0) } ?? 0
    let g = order[min(max(pos + dir, 0), order.count - 1)]
    if let wi = rows.firstIndex(where: {
        if case .window(let rg, _, _, _, _) = $0.kind { return rg == g }
        return false
    }) {
        return kbKeyAt(wi, in: rows)
    }
    return .hdr(group: g)
}
