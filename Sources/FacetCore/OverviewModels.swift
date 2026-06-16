// Backend-neutral value types shared by the grid + rail overviews — the
// two "overview" surfaces that paint workspace cells + window
// thumbnails. AppKit-free (CGRect / CGPoint, never NSRect / NSPoint) so
// they live in FacetCore alongside `cycleSlotIndex` (OverviewGeometry).
//
// Was a near-identical copy on `GridView` and `RailView` (P5b dedup).
// The two had drifted only in surface details, reconciled here into one
// vocabulary:
//   • field NAMES — grid `label` / `windows` vs rail `name` / `wins`,
//   • a dead `releaseRect` on grid's `PendingDrop` (written, never read),
//   • rail's hero-only `isHero` flag.
// So the unified `OverviewCell` keeps `label` / `windows` + an `isHero`
// that defaults to `false` (grid passes the default), and the pending
// types had no real difference left once `releaseRect` was dropped, so
// they collapse to one shared pair (`OverviewPendingDrop` /
// `OverviewPendingSwap`) that both surfaces use.

import CoreGraphics
import Foundation

/// `.window` — drag a window thumb to move it to another workspace.
/// `.workspace` — drag a cell's header to swap two workspaces' contents
/// (the backend's workspace index never changes; only the windows
/// trade). Decided at drag-promotion by which target was grabbed (thumb
/// vs header) — Theme A: the grabbed target, not a modifier key.
public enum OverviewDragKind { case window, workspace }

/// One workspace mini-screen snapshot — used for both the small cells
/// and the rail's centre hero. Recomputed on every relayout so paint and
/// hit-testing can't drift. `isHero` is rail-only (grid passes `false`).
public struct OverviewCell {
    public let wsIndex: Int
    public let rect: CGRect          // the mini-screen rect
    public let headerRect: CGRect    // label / grip band; `.zero` for the hero
    public let isActive: Bool
    public let label: String
    public let mode: String          // layout engine (bsp / stack), shown in header
    public let windows: [MiniWindowHit]
    public let isHero: Bool

    public init(wsIndex: Int, rect: CGRect, headerRect: CGRect,
                isActive: Bool, label: String, mode: String,
                windows: [MiniWindowHit], isHero: Bool = false) {
        self.wsIndex = wsIndex
        self.rect = rect
        self.headerRect = headerRect
        self.isActive = isActive
        self.label = label
        self.mode = mode
        self.windows = windows
        self.isHero = isHero
    }
}

/// Active drag-and-drop state. Captured on mouseDown over a window thumb
/// or a cell header; promoted from a pending-click to a real drag once
/// the cursor moves past the drag threshold. `.window`: real `pid` / `id`
/// and empty `srcIDs`; `.workspace`: `pid` / `id` = -1 and `srcIDs` holds
/// the source cell's whole window set. NOT cleared on mouseUp — the
/// landing gate clears it once the backend acks, so the source thumb
/// stays hidden through the round-trip (memory grid-drag-state-lifecycle).
public struct OverviewDrag {
    public let sourceWS: Int
    public let kind: OverviewDragKind
    public let pid: Int                 // .window: real; .workspace: -1
    public let id: WindowID             // .window: real; .workspace: -1
    public let sourceRect: CGRect       // .window: thumb; .workspace: cell
    public let srcIDs: [WindowID]       // .workspace: all in source; .window: []
    public var current: CGPoint         // cursor in view coords
    public var dropTargetWS: Int?       // cell != sourceWS under cursor, else nil

    public init(sourceWS: Int, kind: OverviewDragKind, pid: Int, id: WindowID,
                sourceRect: CGRect, srcIDs: [WindowID], current: CGPoint,
                dropTargetWS: Int? = nil) {
        self.sourceWS = sourceWS
        self.kind = kind
        self.pid = pid
        self.id = id
        self.sourceRect = sourceRect
        self.srcIDs = srcIDs
        self.current = current
        self.dropTargetWS = dropTargetWS
    }
}

/// Set on a window-move commit; consumed by the next `layoutCells` pass
/// that can confirm the move landed (the dropped id now lives in
/// `dstWS`). Gates the source thumb's reveal on the backend reflecting
/// the move, so a refresh tick racing the round-trip doesn't briefly show
/// a residual thumb in the source cell (残像).
public struct OverviewPendingDrop {
    public let id: WindowID
    public let dstWS: Int
    public let committedAt: Date

    public init(id: WindowID, dstWS: Int, committedAt: Date) {
        self.id = id
        self.dstWS = dstWS
        self.committedAt = committedAt
    }
}

/// Workspace-swap analogue of `OverviewPendingDrop`. Holds the expected
/// post-swap window membership so `layoutCells` can gate the "clear drag
/// + reveal cells" hand-off on the backend actually reporting both halves
/// of the swap.
public struct OverviewPendingSwap {
    public let srcWS: Int
    public let dstWS: Int
    public let srcIDs: [WindowID]       // started in srcWS → should land in dstWS
    public let dstIDs: [WindowID]       // started in dstWS → should land in srcWS
    public let committedAt: Date

    public init(srcWS: Int, dstWS: Int, srcIDs: [WindowID],
                dstIDs: [WindowID], committedAt: Date) {
        self.srcWS = srcWS
        self.dstWS = dstWS
        self.srcIDs = srcIDs
        self.dstIDs = dstIDs
        self.committedAt = committedAt
    }
}
