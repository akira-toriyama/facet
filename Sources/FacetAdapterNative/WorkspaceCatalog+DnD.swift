// Tree operations + swap / insert (real-window DnD) + edge-drag resize + layout knobs (master ratio / count).
// Extracted unchanged from WorkspaceCatalog.swift (#182 phase 2) —
// same-module extension, no logic change. Stored state stays on the
// primary declaration (WorkspaceCatalog.swift).

import CoreGraphics
import FacetCore

extension WorkspaceCatalog {

    // MARK: - Tree operations

    /// Rotate the parent split of `id`. Looks up the owning WS,
    /// then defers to `LayoutTree.toggleOrientation`. No-op when
    /// the window isn't in any tree (float / unknown / stack WS).
    mutating func toggleOrientation(of id: WindowID) {
        // orphan: no home workspace → no tree to rotate (early return).
        guard let slot = windowMap[id], let ws = slot.workspace,
              var tree = layoutTrees[ws] else { return }
        tree.toggleOrientation(of: id)
        layoutTrees[ws] = tree
    }

    /// Rotate the whole bsp tree of `n1Based` clockwise by `degrees`
    /// (90 / 180 / 270). No-op (returns false) when the WS isn't in
    /// bsp mode, has no tree, or the rotation leaves the tree
    /// unchanged (≤1 leaf). Returns whether the tree changed so the
    /// adapter can skip a pointless reflow.
    @discardableResult
    mutating func rotateTree(workspace n1Based: Int,
                                    degrees: Int) -> Bool {
        guard mode(of: n1Based) == StatefulMode.bsp,
              var tree = layoutTrees[n1Based] else { return false }
        let before = tree
        tree.rotate(degrees: degrees)
        guard tree != before else { return false }
        layoutTrees[n1Based] = tree
        return true
    }

    /// Mirror the whole bsp tree of `n1Based` across `axis`. Same
    /// no-op / change-detection contract as `rotateTree`.
    @discardableResult
    mutating func mirrorTree(workspace n1Based: Int,
                                    axis: LayoutTree.Axis) -> Bool {
        guard mode(of: n1Based) == StatefulMode.bsp,
              var tree = layoutTrees[n1Based] else { return false }
        let before = tree
        tree.mirror(axis)
        guard tree != before else { return false }
        layoutTrees[n1Based] = tree
        return true
    }

    // MARK: - Swap / insert (real-window DnD, 枠C)

    /// Swap two tiled windows within `n1Based`. bsp → swap their tree
    /// leaves; stateless / stack → swap their order slots. No-op
    /// (returns false) when the mode keeps no managed order (bsp with no
    /// tree / float), the two are the same window, or either isn't a
    /// non-floating member of the WS (membership is enforced by the
    /// order / tree lookup, so cross-WS or floating operands no-op).
    @discardableResult
    mutating func swapWindows(_ a: WindowID, _ b: WindowID,
                              workspace n1Based: Int) -> Bool {
        if mode(of: n1Based) == StatefulMode.bsp {
            guard var tree = layoutTrees[n1Based] else { return false }
            let before = tree
            tree.swap(a, b)
            guard tree != before else { return false }
            layoutTrees[n1Based] = tree
            return true
        }
        guard hasManagedOrder(n1Based),
              let next = WindowOrder.swapped(orderedMembers(of: n1Based), a, b)
        else { return false }
        stackOrders[n1Based] = next
        return true
    }

    /// Insert `moved` beside `target` on `edge` within `n1Based`. bsp →
    /// split the target leaf on that edge; stateless / stack → move
    /// `moved` before / after `target` in the order. Same no-op /
    /// change-detection contract as `swapWindows`.
    @discardableResult
    mutating func insertWindow(_ moved: WindowID, beside target: WindowID,
                               edge: InsertEdge,
                               workspace n1Based: Int) -> Bool {
        if mode(of: n1Based) == StatefulMode.bsp {
            guard var tree = layoutTrees[n1Based] else { return false }
            let before = tree
            tree.insert(moved, beside: target, edge: edge)
            guard tree != before else { return false }
            layoutTrees[n1Based] = tree
            return true
        }
        guard hasManagedOrder(n1Based),
              let next = WindowOrder.inserted(orderedMembers(of: n1Based),
                                              moving: moved, beside: target,
                                              edge: edge)
        else { return false }
        stackOrders[n1Based] = next
        return true
    }

    /// Whether `n1Based`'s mode keeps a per-WS window order that
    /// swap / insert can reorder (the `"stack"` mode + the stateless
    /// engines). bsp uses a tree (handled separately); float keeps none.
    private func hasManagedOrder(_ n1Based: Int) -> Bool {
        let m = mode(of: n1Based)
        return m == StatefulMode.stack || LayoutRegistry.engine(named: m) != nil
    }

    // MARK: - Resize (real-window edge drag, 枠C 機能2)

    /// Follow a real resize of `id` to `newFrame` (FOLLOW model — the
    /// window was resized natively, we only adjust the ratio so the
    /// neighbour tracks it). bsp → mutate the controlling `Split.ratio`;
    /// master-* → the master / stack divider (`masterRatio`)
    /// only. No-op (false) for any other mode, an off-tree window, or a
    /// drag that doesn't move a divider-controlling edge. `rect` is the
    /// active display rect.
    /// Follow a real resize of `id` to `newFrame`. Returns the set of
    /// windows a LIVE reflow must freeze (the dragged window + the same-
    /// subtree mates that comove off its divider), or `nil` when nothing
    /// changed. The settle path reflows everyone and ignores the set;
    /// master layouts have no subtree so the set is just `{id}`.
    mutating func applyResize(_ id: WindowID, to newFrame: CGRect,
                              workspace n1Based: Int, in rect: CGRect,
                              innerGap: CGFloat = 0) -> Set<WindowID>? {
        let m = mode(of: n1Based)
        if m == StatefulMode.bsp {
            guard var tree = layoutTrees[n1Based],
                  let cur = tree.frames(in: rect)[id] else { return nil }
            // The live frame is gap-inset; the tree works in un-gapped
            // coords. Map the dragged edges back, else the constant gap
            // offset reads as a cross-axis edge move and a pure vertical
            // resize wrongly nudges the horizontal neighbour. See `ungap`.
            let target = Self.ungap(newFrame, current: cur, in: rect,
                                    gap: innerGap)
            let before = tree
            let frozen = tree.resize(id, to: target, in: rect)
            guard tree != before else { return nil }
            layoutTrees[n1Based] = tree
            return frozen.union([id])
        }
        guard let cur = engineFrames(for: n1Based, in: rect)[id] else {
            return nil
        }
        let target = Self.ungap(newFrame, current: cur, in: rect, gap: innerGap)
        guard let ratio = masterRatioFromResize(id, to: target, mode: m,
                                                 workspace: n1Based, in: rect)
        else { return nil }
        let params0 = params(of: n1Based)
        let next = LayoutParams(masterRatio: ratio,
                                masterCount: params0.masterCount)
        guard next.masterRatio != params0.masterRatio else { return nil }
        layoutParams[n1Based] = next
        return [id]
    }

    /// Map a gap-inset on-screen frame back to the un-gapped layout coords
    /// the tree / engine math uses. `applyInnerGap` shrinks every edge that
    /// has a neighbour by `gap/2`; this adds exactly that back per edge,
    /// using `current` (the window's computed un-gapped frame) to tell
    /// which edges are interior — so the resize ratio is read from the true
    /// divider position, not a gap-offset one. `gap <= 0` is identity.
    private static func ungap(_ f: CGRect, current cur: CGRect,
                              in rect: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return f }
        let key = WindowID(serverID: 0)
        let g = applyInnerGap([key: cur], in: rect, gap: gap)[key] ?? cur
        let minX = f.minX - (g.minX - cur.minX)
        let maxX = f.maxX - (g.maxX - cur.maxX)
        let minY = f.minY - (g.minY - cur.minY)
        let maxY = f.maxY - (g.maxY - cur.maxY)
        return CGRect(x: minX, y: minY,
                      width: maxX - minX, height: maxY - minY)
    }

    /// The master/stack divider fraction implied by resizing `id` to
    /// `newFrame` in a stateless master layout — `nil` when the mode has
    /// no master divider or `id`'s divider-facing edge didn't move (the
    /// caller's change-detection then no-ops). The divider is always the
    /// master band's inner edge: master-left = master right edge / stack
    /// left edge, master-right = the X mirror (master left / stack
    /// right), master-top = master bottom / stack top, master-bottom =
    /// the Y mirror, master-center = (symmetric) the master's own width
    /// fraction.
    private func masterRatioFromResize(_ id: WindowID, to f: CGRect,
                                       mode m: String, workspace n1Based: Int,
                                       in rect: CGRect) -> CGFloat? {
        guard rect.width > 0, rect.height > 0,
              let idx = orderedMembers(of: n1Based).firstIndex(of: id)
        else { return nil }
        let isMaster = idx < params(of: n1Based).masterCount
        switch m {
        case "master-left":
            return isMaster ? (f.maxX - rect.minX) / rect.width
                            : (f.minX - rect.minX) / rect.width
        case "master-right":
            return isMaster ? (rect.maxX - f.minX) / rect.width
                            : (rect.maxX - f.maxX) / rect.width
        case "master-top":
            return isMaster ? (f.maxY - rect.minY) / rect.height
                            : (f.minY - rect.minY) / rect.height
        case "master-bottom":
            return isMaster ? (rect.maxY - f.minY) / rect.height
                            : (rect.maxY - f.maxY) / rect.height
        case "master-center":
            return isMaster ? f.width / rect.width : nil   // sides: not v1
        default:
            return nil
        }
    }

    /// Tree-computed frames for every tiled window in the WS,
    /// keyed by `WindowID`. Empty when the WS isn't in `"bsp"`
    /// mode or has no tree.
    func tiledFrames(for n1Based: Int,
                            in rect: CGRect) -> [WindowID: CGRect] {
        guard mode(of: n1Based) == StatefulMode.bsp,
              let tree = layoutTrees[n1Based] else { return [:] }
        return tree.frames(in: rect)
    }

    /// Non-floating windows of `n1Based`, sorted by `serverID` for a
    /// stable, deterministic order. Shared by `setMode` (tree / stack
    /// seeding) and the stateless layout-engine path so both agree on
    /// "which windows, in what order".
    func nonFloatingMembers(of n1Based: Int) -> [WindowID] {
        windowMap
            .filter { $0.value.workspace == n1Based
                && !floatingWindows.contains($0.key)
                // Hidden (Cmd+H / minimized) windows give up their tile
                // slot — excluding them here makes every stateless engine
                // and the bsp re-seed reclaim it (memory
                // `facet-hide-reclaim-decisions`).
                && !hiddenMembers.contains($0.key)
                // Section-lens-parked windows (EX-1 exclusive model) give up
                // their slot the same way — the in-lens windows reclaim it.
                // `lensParkedMembers` can hold windows from any workspace, so
                // per-WS preview excludes them exactly where they live.
                && !lensParkedMembers.contains($0.key) }
            .map(\.key)
            .sorted { $0.serverID < $1.serverID }
    }

    /// The WS's non-floating windows in maintained order
    /// (`stackOrders`), reconciled against current membership: stale
    /// ids dropped, any member missing from the order appended. Feeds
    /// stateless engines a stable + complete order even if the order
    /// and membership briefly drift (a missing member would otherwise
    /// get no frame and be left wherever it was).
    func orderedMembers(of n1Based: Int) -> [WindowID] {
        let members = nonFloatingMembers(of: n1Based)
        let memberSet = Set(members)
        let maintained = (stackOrders[n1Based] ?? [])
            .filter { memberSet.contains($0) }
        let have = Set(maintained)
        return maintained + members.filter { !have.contains($0) }
    }

    /// Frames from the registered stateless `LayoutEngine` for
    /// `n1Based`'s mode, or empty when the mode isn't a registered
    /// engine (bsp / stack / float). The engine is pure; this hands
    /// it the WS's stable, complete member order + the rect to carve.
    func engineFrames(for n1Based: Int,
                             in rect: CGRect) -> [WindowID: CGRect] {
        guard let engine = LayoutRegistry.engine(named: mode(of: n1Based))
        else { return [:] }
        return engine.frames(order: orderedMembers(of: n1Based),
                             focused: nil,
                             params: params(of: n1Based),
                             in: rect)
    }

    // MARK: - Layout knobs (master ratio / count)

    /// Per-WS layout knobs, or defaults when none set.
    func params(of n1Based: Int) -> LayoutParams {
        layoutParams[n1Based] ?? LayoutParams()
    }

    /// Nudge the master ratio by `delta` (clamped 0.05…0.95 by
    /// `LayoutParams`). Returns whether the value actually changed
    /// (false at the clamp boundary, so the caller can skip a
    /// pointless re-tile).
    @discardableResult
    mutating func adjustMasterRatio(workspace n1Based: Int,
                                           delta: CGFloat) -> Bool {
        let cur = params(of: n1Based)
        let next = LayoutParams(masterRatio: cur.masterRatio + delta,
                                masterCount: cur.masterCount)
        layoutParams[n1Based] = next
        return next.masterRatio != cur.masterRatio
    }

    /// Nudge the master count by `delta` (clamped ≥ 1). Returns
    /// whether the value actually changed.
    @discardableResult
    mutating func adjustMasterCount(workspace n1Based: Int,
                                           delta: Int) -> Bool {
        let cur = params(of: n1Based)
        let next = LayoutParams(masterRatio: cur.masterRatio,
                                masterCount: cur.masterCount + delta)
        layoutParams[n1Based] = next
        return next.masterCount != cur.masterCount
    }

    /// Reset a workspace's master knobs to defaults (`balance`):
    /// master ratio → 0.5, master count → 1. Undoes accumulated
    /// `grow`/`shrink`/`inc`/`dec` nudges so the layout returns to its
    /// even baseline. Returns whether anything actually changed (false
    /// when already at defaults, so the caller can skip a re-tile).
    @discardableResult
    mutating func resetParams(workspace n1Based: Int) -> Bool {
        guard layoutParams[n1Based] != nil,
              layoutParams[n1Based] != LayoutParams() else { return false }
        layoutParams[n1Based] = nil          // nil reads back as defaults
        return true
    }

}
