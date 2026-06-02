// Pure value-type that represents one workspace's BSP tiling
// tree.
//
// Why this exists separate from `NativeAdapter`:
//
//   - The tree (split nodes, leaves, auto-balance choices,
//     ratio updates) is testable without AX permission,
//     CGWindowList, or any AppKit thread. Same playbook as
//     `WorkspaceCatalog` (PR-B): pure data + transitions, AX
//     side stays in the adapter.
//
// Phase γ frozen decisions referenced here
//   (`facet-phase-gamma-decisions` / docs/architecture.md):
//
//   - Always-on auto-tile: every new window enters the tree
//     by splitting the currently-focused leaf.
//   - Auto-balance split: wider rect → vertical split; taller
//     → horizontal. New window lands on the bottom / right.
//   - Lazy retile: callers re-compute frames from the tree
//     only on tree-changing events (insert / remove / mode
//     flip / WS switch / `--retile`); user drags between
//     events are not reconciled.
//   - Gaps: zero, hardcoded. Tree math returns flush rects.
//   - Directional movement: only `toggleOrientation` (rotate
//     the focused leaf's parent split). `moveLeft/Right/Up/Down`
//     are out of Phase γ scope.
//
// Indexing convention
//
//   Window identity is `WindowID` (CGS server id), matching
//   `WorkspaceCatalog`. Pid is *not* stored in the tree — it
//   stays in `WorkspaceCatalog.windowMap[id].pid`; callers that
//   need to dispatch AX operations look it up there.

import CoreGraphics
import FacetCore

/// One node in the BSP tree.
///
/// Indirection via `Box` keeps `Node` a value type without
/// triggering Swift's "recursive enum needs `indirect`" cycle —
/// we want value semantics throughout (each mutation returns a
/// new tree) so equality + tests behave like data, not references.
enum LayoutNode: Equatable, Sendable {
    case leaf(WindowID)
    case split(Split)

    struct Split: Equatable, Sendable {
        enum Orientation: Sendable { case horizontal, vertical }
        let orientation: Orientation
        /// Fraction of the parent rect that the *first* child
        /// receives (0…1). Defaults to 0.5 at insert time;
        /// future drag-resize work will update this in place.
        let ratio: CGFloat
        let first: Box
        let second: Box

        init(orientation: Orientation, ratio: CGFloat,
                    first: LayoutNode, second: LayoutNode) {
            self.orientation = orientation
            self.ratio = max(0.05, min(0.95, ratio))
            self.first = Box(first)
            self.second = Box(second)
        }
    }

    /// Reference-wrapper used to satisfy Swift's recursive-enum
    /// rule without polluting the public API with `indirect`.
    /// Compared by underlying value, which keeps `Equatable`
    /// honest on tree-shape comparisons.
    final class Box: Equatable, @unchecked Sendable {
        let node: LayoutNode
        init(_ node: LayoutNode) { self.node = node }
        static func == (lhs: Box, rhs: Box) -> Bool {
            lhs.node == rhs.node
        }
    }
}

/// One workspace's BSP tree.
///
/// `nil` root means the workspace has no tiled windows yet;
/// the first `insert` populates it with a leaf, the second
/// with a 50/50 split, and so on.
struct LayoutTree: Equatable, Sendable {
    private(set) var root: LayoutNode?

    init(root: LayoutNode? = nil) {
        self.root = root
    }

    // MARK: - Insert

    /// Insert `id` into the tree.
    ///
    /// - If the tree is empty → `id` becomes the sole leaf.
    /// - Else → split the leaf currently holding `focused`.
    ///   When `focused` isn't in the tree (or is nil), fall
    ///   back to splitting the *rightmost* leaf so insertion
    ///   stays deterministic.
    /// - `rect` is the display's `visibleFrame` at insert time;
    ///   it's used to pick the auto-balance orientation (wider
    ///   rect → vertical split; taller → horizontal). The full
    ///   layout is recomputed every time `frames(in:)` runs,
    ///   so the actual `rect` passed here only matters for the
    ///   *orientation choice* at this specific insertion.
    mutating func insert(_ id: WindowID,
                                focused: WindowID?,
                                in rect: CGRect) {
        guard root != nil else {
            root = .leaf(id)
            return
        }
        let orientation = autoBalanceOrientation(for: rect)
        root = inserted(into: root!, newID: id,
                        focused: focused, fallbackRect: rect,
                        defaultOrientation: orientation)
    }

    private func inserted(into node: LayoutNode,
                          newID: WindowID,
                          focused: WindowID?,
                          fallbackRect: CGRect,
                          defaultOrientation: LayoutNode.Split.Orientation)
        -> LayoutNode
    {
        switch node {
        case .leaf(let existingID):
            // Split this leaf when it holds the focused window —
            // or when focused is nil / unknown and this is the
            // first leaf we found (rightmost wins below).
            let shouldSplit = (focused == existingID)
                || focused == nil
                || !contains(focused!)
            guard shouldSplit else { return node }
            return .split(.init(
                orientation: defaultOrientation,
                ratio: 0.5,
                first: .leaf(existingID),
                second: .leaf(newID)))
        case .split(let s):
            // Recurse right-first so the "no focused match"
            // fallback lands the new leaf on the right /
            // bottom-most slot — matches user intuition of
            // "newest goes last".
            let secondNew = inserted(into: s.second.node,
                                     newID: newID,
                                     focused: focused,
                                     fallbackRect: fallbackRect,
                                     defaultOrientation: defaultOrientation)
            if secondNew != s.second.node {
                return .split(.init(orientation: s.orientation,
                                    ratio: s.ratio,
                                    first: s.first.node,
                                    second: secondNew))
            }
            let firstNew = inserted(into: s.first.node,
                                    newID: newID,
                                    focused: focused,
                                    fallbackRect: fallbackRect,
                                    defaultOrientation: defaultOrientation)
            return .split(.init(orientation: s.orientation,
                                ratio: s.ratio,
                                first: firstNew,
                                second: s.second.node))
        }
    }

    private func autoBalanceOrientation(for rect: CGRect)
        -> LayoutNode.Split.Orientation
    {
        // Wider rect → vertical split (left|right halves).
        // Taller (or square) → horizontal split (top|bottom).
        rect.width >= rect.height ? .vertical : .horizontal
    }

    // MARK: - Remove

    /// Remove `id` from the tree. The sibling subtree absorbs
    /// the freed space (standard BSP healing). When the root
    /// itself is the only leaf, the tree becomes empty.
    mutating func remove(_ id: WindowID) {
        guard let r = root else { return }
        root = removed(from: r, id: id)
    }

    private func removed(from node: LayoutNode,
                         id: WindowID) -> LayoutNode?
    {
        switch node {
        case .leaf(let leafID):
            return leafID == id ? nil : node
        case .split(let s):
            let first = removed(from: s.first.node, id: id)
            let second = removed(from: s.second.node, id: id)
            switch (first, second) {
            case (nil, nil): return nil
            case (let f?, nil): return f
            case (nil, let g?): return g
            case (let f?, let g?):
                return .split(.init(orientation: s.orientation,
                                    ratio: s.ratio,
                                    first: f, second: g))
            }
        }
    }

    // MARK: - Toggle orientation

    /// Rotate the *parent split* of `id` 90°. No-op when:
    ///   - `id` isn't in the tree
    ///   - `id` is the root leaf (no parent split exists)
    mutating func toggleOrientation(of id: WindowID) {
        guard let r = root else { return }
        root = toggled(in: r, target: id).0
    }

    /// Returns (new node, "did toggle within this subtree").
    /// The flag prevents toggling the same ancestor twice when
    /// recursion bubbles up.
    private func toggled(in node: LayoutNode,
                         target: WindowID) -> (LayoutNode, Bool)
    {
        switch node {
        case .leaf:
            return (node, false)
        case .split(let s):
            // If a direct child of this split is the target
            // leaf → rotate this split.
            if case .leaf(let id) = s.first.node, id == target {
                return (rotated(s), true)
            }
            if case .leaf(let id) = s.second.node, id == target {
                return (rotated(s), true)
            }
            // Otherwise recurse — first child first; if it
            // already toggled, skip the second.
            let (newFirst, didFirst) = toggled(
                in: s.first.node, target: target)
            if didFirst {
                return (.split(.init(orientation: s.orientation,
                                     ratio: s.ratio,
                                     first: newFirst,
                                     second: s.second.node)),
                        true)
            }
            let (newSecond, didSecond) = toggled(
                in: s.second.node, target: target)
            return (.split(.init(orientation: s.orientation,
                                 ratio: s.ratio,
                                 first: s.first.node,
                                 second: newSecond)),
                    didSecond)
        }
    }

    private func rotated(_ s: LayoutNode.Split) -> LayoutNode {
        .split(.init(
            orientation: s.orientation == .vertical
                ? .horizontal : .vertical,
            ratio: s.ratio,
            first: s.first.node,
            second: s.second.node))
    }

    // MARK: - Rotate / mirror (whole-tree)

    /// Rotate the whole tree clockwise by `degrees` (90 / 180 / 270).
    /// A 90° CW step maps a vertical (left|right) split to a horizontal
    /// (top|bottom) one keeping child order (left → top), and a
    /// horizontal split to a vertical one with the children swapped
    /// (top → right). 180° = every split's children reversed
    /// (orientation unchanged); 270° = three CW steps (= one CCW).
    /// Unknown degree values are a no-op. Ratios are preserved.
    mutating func rotate(degrees: Int) {
        guard let r = root else { return }
        let steps = ((degrees / 90) % 4 + 4) % 4   // 90→1, 180→2, 270→3
        guard degrees % 90 == 0, steps != 0 else { return }
        var node = r
        for _ in 0..<steps { node = Self.rotated90CW(node) }
        root = node
    }

    private static func rotated90CW(_ node: LayoutNode) -> LayoutNode {
        switch node {
        case .leaf:
            return node
        case .split(let s):
            switch s.orientation {
            case .vertical:   // left|right → top|bottom, order kept
                return .split(.init(
                    orientation: .horizontal, ratio: s.ratio,
                    first: rotated90CW(s.first.node),
                    second: rotated90CW(s.second.node)))
            case .horizontal: // top|bottom → left|right, order swapped
                return .split(.init(
                    orientation: .vertical, ratio: s.ratio,
                    first: rotated90CW(s.second.node),
                    second: rotated90CW(s.first.node)))
            }
        }
    }

    /// Mirror the whole tree across an axis. `horizontal` reflects
    /// left↔right (swap the children of every *vertical* split);
    /// `vertical` reflects top↔bottom (swap the children of every
    /// *horizontal* split). Ratios are preserved. No-op on an empty
    /// tree.
    enum Axis: Sendable { case horizontal, vertical }

    mutating func mirror(_ axis: Axis) {
        guard let r = root else { return }
        root = Self.mirrored(r, axis: axis)
    }

    private static func mirrored(_ node: LayoutNode,
                                 axis: Axis) -> LayoutNode {
        switch node {
        case .leaf:
            return node
        case .split(let s):
            // Swap the children when this split runs along the
            // mirrored axis; recurse into both children either way.
            let swap = (axis == .horizontal && s.orientation == .vertical)
                || (axis == .vertical && s.orientation == .horizontal)
            let f = mirrored(s.first.node, axis: axis)
            let g = mirrored(s.second.node, axis: axis)
            return .split(.init(orientation: s.orientation, ratio: s.ratio,
                                first: swap ? g : f,
                                second: swap ? f : g))
        }
    }

    // MARK: - Swap / insert (real-window DnD, 枠C)

    /// Exchange the leaves holding `a` and `b` — the two windows trade
    /// on-screen frames while the split structure (orientations /
    /// ratios) stays put. No-op when `a == b` or either isn't in the
    /// tree.
    mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard a != b, let r = root, contains(a), contains(b) else { return }
        root = Self.swapped(r, a, b)
    }

    private static func swapped(_ node: LayoutNode,
                                _ a: WindowID, _ b: WindowID) -> LayoutNode {
        switch node {
        case .leaf(let id):
            if id == a { return .leaf(b) }
            if id == b { return .leaf(a) }
            return node
        case .split(let s):
            return .split(.init(orientation: s.orientation, ratio: s.ratio,
                                first: swapped(s.first.node, a, b),
                                second: swapped(s.second.node, a, b)))
        }
    }

    /// Move `moved` to sit beside `target`, splitting `target`'s leaf
    /// 50/50 on `edge` (`left` / `top` puts `moved` first, `right` /
    /// `bottom` second). `moved` is first removed from its current slot
    /// — its sibling heals — so the rest of the tree re-balances. No-op
    /// when `moved == target` or either isn't in the tree.
    mutating func insert(_ moved: WindowID, beside target: WindowID,
                         edge: InsertEdge) {
        guard moved != target, root != nil,
              contains(moved), contains(target) else { return }
        guard let healed = removed(from: root!, id: moved) else { return }
        root = Self.splitBeside(healed, target: target,
                                moved: moved, edge: edge)
    }

    private static func splitBeside(_ node: LayoutNode, target: WindowID,
                                    moved: WindowID,
                                    edge: InsertEdge) -> LayoutNode {
        switch node {
        case .leaf(let id):
            guard id == target else { return node }
            let vertical = (edge == .left || edge == .right)
            let movedFirst = (edge == .left || edge == .top)
            return .split(.init(
                orientation: vertical ? .vertical : .horizontal,
                ratio: 0.5,
                first: .leaf(movedFirst ? moved : target),
                second: .leaf(movedFirst ? target : moved)))
        case .split(let s):
            return .split(.init(orientation: s.orientation, ratio: s.ratio,
                                first: splitBeside(s.first.node,
                                                   target: target,
                                                   moved: moved, edge: edge),
                                second: splitBeside(s.second.node,
                                                    target: target,
                                                    moved: moved, edge: edge)))
        }
    }

    // MARK: - Resize (real-window edge drag, 枠C 機能2)

    /// Follow a real resize of leaf `id` to `newFrame`: for each edge
    /// that moved vs its current tiled position, find the *controlling
    /// split* — the nearest ancestor whose divider IS that edge — and set
    /// its ratio so the divider lands on the new edge. The opposite
    /// subtree reflows; `id` keeps its place in the tree. No-op when `id`
    /// isn't tiled, nothing moved, or the edge is a screen boundary (no
    /// ancestor split on that side). Ratios clamp to [0.05, 0.95].
    ///
    /// Algorithm = yabai's `window_node_fence` adapted to the value tree:
    /// the controlling split for the right edge is the deepest ancestor
    /// `.vertical` split where `id` is in the FIRST (left) child, etc.
    /// The new ratio is computed from `newFrame`'s ABSOLUTE edge against
    /// the split's rect (snapshot, not per-tick delta — no drift).
    /// Returns the leaves that COMOVE with the dragged window — the
    /// dragged side of every fence touched. A live reflow must FREEZE
    /// these (not re-tile them): they're positioned off the divider that's
    /// anchored to the dragged window's actual frame, which the live reflow
    /// deliberately leaves alone, so re-tiling them to their computed slots
    /// would drift them off it and open a gap. Only the OPPOSITE subtree
    /// follows. Empty when no fence moved.
    @discardableResult
    mutating func resize(_ id: WindowID, to newFrame: CGRect,
                         in rect: CGRect) -> Set<WindowID> {
        guard let cur = frames(in: rect)[id], root != nil else { return [] }
        let eps: CGFloat = 0.5
        var frozen: Set<WindowID> = []
        // X axis — whichever vertical edge moved more is the dragged one.
        let dMaxX = newFrame.maxX - cur.maxX, dMinX = newFrame.minX - cur.minX
        if abs(dMaxX) > eps, abs(dMaxX) >= abs(dMinX) {
            let (r, f) = setFence(root!, rect, id, axis: .vertical,
                                  leafInFirst: true, edgePos: newFrame.maxX)
            root = r; frozen.formUnion(f)
        } else if abs(dMinX) > eps {
            let (r, f) = setFence(root!, rect, id, axis: .vertical,
                                  leafInFirst: false, edgePos: newFrame.minX)
            root = r; frozen.formUnion(f)
        }
        // Y axis — likewise. facet `.horizontal`: first = top (minY).
        let dMaxY = newFrame.maxY - cur.maxY, dMinY = newFrame.minY - cur.minY
        if abs(dMaxY) > eps, abs(dMaxY) >= abs(dMinY) {
            let (r, f) = setFence(root!, rect, id, axis: .horizontal,
                                  leafInFirst: true, edgePos: newFrame.maxY)
            root = r; frozen.formUnion(f)
        } else if abs(dMinY) > eps {
            let (r, f) = setFence(root!, rect, id, axis: .horizontal,
                                  leafInFirst: false, edgePos: newFrame.minY)
            root = r; frozen.formUnion(f)
        }
        return frozen
    }

    /// Recurse toward `id`; the DEEPEST split matching (`axis`,
    /// `leafInFirst`) is the fence — set its ratio from `edgePos`. Returns
    /// (rebuilt node, leaves to freeze). `rect` is this node's rect. The
    /// freeze set is the leaves on the dragged window's side of the fence
    /// (incl. `id`); empty when this branch holds no fence.
    private func setFence(_ node: LayoutNode, _ rect: CGRect, _ id: WindowID,
                          axis: LayoutNode.Split.Orientation,
                          leafInFirst: Bool, edgePos: CGFloat)
        -> (LayoutNode, Set<WindowID>)
    {
        guard case .split(let s) = node else { return (node, []) }
        let (firstRect, secondRect) = splitRect(rect, orientation: s.orientation,
                                                ratio: s.ratio)
        let inFirst = contains(s.first.node, id: id)
        guard inFirst || contains(s.second.node, id: id) else {
            return (node, [])               // id not under this split
        }
        let childRect = inFirst ? firstRect : secondRect
        let childNode = inFirst ? s.first.node : s.second.node
        let (newChild, deepFrozen) = setFence(childNode, childRect, id, axis: axis,
                                              leafInFirst: leafInFirst,
                                              edgePos: edgePos)
        func rebuilt(ratio: CGFloat) -> LayoutNode {
            .split(.init(orientation: s.orientation, ratio: ratio,
                         first: inFirst ? newChild : s.first.node,
                         second: inFirst ? s.second.node : newChild))
        }
        if !deepFrozen.isEmpty { return (rebuilt(ratio: s.ratio), deepFrozen) }
        // Is THIS split the fence? matching orientation + leaf on the
        // required side → its divider is the dragged edge. The dragged
        // window's whole child subtree comoves off this divider → freeze it.
        if s.orientation == axis, inFirst == leafInFirst {
            let ratio = axis == .vertical
                ? (edgePos - rect.minX) / rect.width
                : (edgePos - rect.minY) / rect.height
            let frozen = Set(collectLeaves(inFirst ? s.first.node : s.second.node))
            return (rebuilt(ratio: ratio), frozen)
        }
        return (rebuilt(ratio: s.ratio), [])
    }

    // MARK: - Queries

    func contains(_ id: WindowID) -> Bool {
        guard let r = root else { return false }
        return contains(r, id: id)
    }

    private func contains(_ node: LayoutNode,
                          id: WindowID) -> Bool {
        switch node {
        case .leaf(let leafID): return leafID == id
        case .split(let s):
            return contains(s.first.node, id: id)
                || contains(s.second.node, id: id)
        }
    }

    /// Flat list of every leaf id in left-to-right / top-to-bottom
    /// order. Useful for `snapshot` ordering + reconcile diffs.
    var leaves: [WindowID] {
        guard let r = root else { return [] }
        return collectLeaves(r)
    }

    private func collectLeaves(_ node: LayoutNode) -> [WindowID] {
        switch node {
        case .leaf(let id): return [id]
        case .split(let s):
            return collectLeaves(s.first.node)
                + collectLeaves(s.second.node)
        }
    }

    // MARK: - Frame computation

    /// Recursively compute the on-screen rect for every leaf
    /// against `rect` (typically the active display's
    /// `visibleFrame`). Empty tree → empty dictionary.
    func frames(in rect: CGRect) -> [WindowID: CGRect] {
        guard let r = root else { return [:] }
        var out: [WindowID: CGRect] = [:]
        compute(r, in: rect, into: &out)
        return out
    }

    private func compute(_ node: LayoutNode,
                         in rect: CGRect,
                         into out: inout [WindowID: CGRect])
    {
        switch node {
        case .leaf(let id):
            out[id] = rect
        case .split(let s):
            let (first, second) = splitRect(rect,
                                            orientation: s.orientation,
                                            ratio: s.ratio)
            compute(s.first.node, in: first, into: &out)
            compute(s.second.node, in: second, into: &out)
        }
    }

    private func splitRect(_ rect: CGRect,
                           orientation: LayoutNode.Split.Orientation,
                           ratio: CGFloat) -> (CGRect, CGRect)
    {
        switch orientation {
        case .vertical:
            let w1 = rect.width * ratio
            return (CGRect(x: rect.minX, y: rect.minY,
                           width: w1, height: rect.height),
                    CGRect(x: rect.minX + w1, y: rect.minY,
                           width: rect.width - w1,
                           height: rect.height))
        case .horizontal:
            let h1 = rect.height * ratio
            return (CGRect(x: rect.minX, y: rect.minY,
                           width: rect.width, height: h1),
                    CGRect(x: rect.minX,
                           y: rect.minY + h1,
                           width: rect.width,
                           height: rect.height - h1))
        }
    }
}
