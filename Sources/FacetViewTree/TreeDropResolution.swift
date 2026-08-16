import FacetCore
import ListCore

/// What a resolved tree drop MEANS — the one place the tree's drop semantics
/// live, shared by the commit (`Controller.treeDrop`) and the pre-validation
/// seam (sill's `dropTargetValidator`).
///
/// Two callers, one rule set: before this existed the commit rejected
/// placements the validator never saw, so sill happily drew an insertion line
/// on a gap whose release did nothing (the chunk-over-window-gap case) and let
/// the keyboard aim stop on it. A rejected placement must draw no affordance,
/// join no keyboard aim, and never reach `onDrop` — which is exactly what
/// returning nil here now guarantees on both paths.
public enum TreeDropResolution: Equatable, Sendable {
    /// Section chunk reorder to a boundary index in the rendered section list.
    case chunk(boundary: Int)
    /// Window move from one rendered section ordinal to another.
    case window(id: WindowID, from: Int, to: Int)
    /// Workspace-content swap between two rendered section ordinals — the
    /// by-workspace degrade's header drag (the AppKit tree's mode-3). Section
    /// mode reorders instead; an isolate desktop has no workspace headers.
    case swap(from: Int, to: Int)
}

/// Resolve a (drag, target) pair against the RENDERED sections.
///
/// - `sectionMode`: the tree is rendering config sections (vs the by-workspace
///   degrade). Chunk reorder is a section-mode gesture only.
/// - `isolateDesktop`: an isolate desktop's 1–2 synthesized sections have a
///   FIXED order (matched then holding), so reordering them is meaningless —
///   the AppKit tree gated it (`SidebarView+Drag` mode-4 `if !isolateDesktop`)
///   and the pointer path lost that gate in the render swap.
public func resolveTreeDrop(
    _ ctx: ListCore.DragContext<TreeItemID>,
    _ target: ListCore.DropTarget<TreeItemID>,
    sections secs: [ProjectedSection],
    sectionMode: Bool,
    isolateDesktop: Bool
) -> TreeDropResolution? {
    switch ctx.sourceID {
    case .header(let sid):
        guard let g = secs.firstIndex(where: { $0.id == sid }) else { return nil }
        if !sectionMode {
            // By-workspace degrade: a header drag TRADES two workspaces'
            // contents (mode-3). Any position inside another workspace's
            // section — its header, a row, a gap — is that workspace's band,
            // exactly like the retired `wsBands` hit-test. The END gap is
            // BELOW the tree, which was outside every band (release did
            // nothing) — keeping it nil also keeps the flick-below abort.
            if case .between(nil) = target.placement { return nil }
            guard secs[g].sourceWorkspaceIndex != nil,
                  let t = destinationOrdinal(target.placement, in: secs),
                  t != g, secs[t].sourceWorkspaceIndex != nil else { return nil }
            return .swap(from: g, to: t)
        }
        guard !isolateDesktop,
              case .between(let beforeID) = target.placement else { return nil }
        let boundary: Int
        switch beforeID {
        case nil:
            boundary = secs.count
        case .header(let bsid):
            guard let k = secs.firstIndex(where: { $0.id == bsid }) else { return nil }
            boundary = k
        case .window:
            // A gap BETWEEN window rows is never a chunk boundary. sill offers
            // it because its geometry knows nothing about sections; rejecting
            // it here also removes the insertion line it used to draw there.
            return nil
        }
        return .chunk(boundary: boundary)

    case .window(let g, let wid):
        guard g >= 0, g < secs.count,
              secs[g].sectionType != .holding      // inert source (t-63h2)
        else { return nil }
        let dest = destinationOrdinal(target.placement, in: secs)
        guard let t = dest, t != g, t >= 0, t < secs.count else { return nil }
        // A holding section is display-only in BOTH directions: nothing lands
        // in it (its membership is the match's complement, not a place).
        guard secs[t].sectionType != .holding else { return nil }
        // The degrade path files by workspace index; a section without one has
        // nowhere to put the window.
        if !sectionMode, secs[t].sourceWorkspaceIndex == nil { return nil }
        return .window(id: wid, from: g, to: t)
    }
}

func sectionOrdinal(of id: TreeItemID, in secs: [ProjectedSection]) -> Int? {
    switch id {
    case .header(let sid): return secs.firstIndex { $0.id == sid }
    case .window(let g, _): return (g >= 0 && g < secs.count) ? g : nil
    }
}

/// The section ordinal a placement lands in: `.onto` a row → that row's
/// section; `.between` → the section the gap belongs to (the gap ABOVE a
/// header closes the PREVIOUS section; the end gap is the last section).
/// Shared by the window-move and the degrade swap branches.
func destinationOrdinal(_ placement: ListCore.DropPlacement<TreeItemID>,
                        in secs: [ProjectedSection]) -> Int? {
    switch placement {
    case .onto(let id):
        return sectionOrdinal(of: id, in: secs)
    case .between(let beforeID):
        guard let beforeID else { return secs.count - 1 }
        guard let k = sectionOrdinal(of: beforeID, in: secs) else { return nil }
        if case .header = beforeID { return max(0, k - 1) }
        return k
    }
}
