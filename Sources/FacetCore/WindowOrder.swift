// Pure window-order operations behind the real-window-DnD verbs (枠C).
//
// The native adapter's stateless / stack layouts are driven entirely by
// a per-workspace window order, and a `LayoutEngine` is a pure function
// of that order. Keeping the reorder math here (not buried in the
// adapter) means the SAME calculation that the backend COMMITS is the
// one the prediction overlay (PR-2) DRAWS — no drift between "what you
// see" and "what lands".

/// Reorder operations on a window order list. Pure; each returns the
/// new order, or `nil` when the operation would leave it unchanged (so
/// callers get free change-detection — a `nil` means "skip the reflow").
public enum WindowOrder {

    /// Exchange the positions of `a` and `b`. `nil` when `a == b` or
    /// either is absent from `order`.
    public static func swapped(_ order: [WindowID],
                               _ a: WindowID, _ b: WindowID) -> [WindowID]? {
        guard a != b,
              let ia = order.firstIndex(of: a),
              let ib = order.firstIndex(of: b) else { return nil }
        var out = order
        out.swapAt(ia, ib)
        return out
    }

    /// Move `moved` to sit beside `target`: before it for `.left` /
    /// `.top`, after it for `.right` / `.bottom`. `nil` when
    /// `moved == target`, either is absent, or `moved` is already in
    /// that slot (no positional change).
    public static func inserted(_ order: [WindowID],
                                moving moved: WindowID,
                                beside target: WindowID,
                                edge: InsertEdge) -> [WindowID]? {
        guard moved != target,
              order.contains(moved), order.contains(target) else { return nil }
        var out = order
        out.removeAll { $0 == moved }
        guard let t = out.firstIndex(of: target) else { return nil }
        let before = (edge == .left || edge == .top)
        out.insert(moved, at: before ? t : t + 1)
        return out == order ? nil : out
    }
}
