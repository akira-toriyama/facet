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
