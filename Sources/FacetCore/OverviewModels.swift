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

/// Which kind of section a PROJECTED / rendered overview unit is (W2.6 /
/// t-wrd2). Distinct from `SectionType` ({workspace, lens}), which now types a
/// mac DESKTOP (`[desktop.N] type = …`, t-ec9s): the rendered side has a THIRD
/// kind, the `.unassigned` lost-and-found receptacle, which no config key
/// declares as a `type` — it is produced by `FilterProjection` from a section's
/// `unassigned = true` MARKER. Keeping the rendered enum separate lets the
/// config enum stay pure (a receptacle is a marker, not a type) while the views
/// still pattern-match three rendered kinds.
public enum ProjectedSectionType: Sendable, Equatable {
    case workspace
    case lens
    case unassigned
}

/// One projected section — the pivot's unified overview unit
/// (`FilterProjection`). A `[[desktop.N.section]]` workspace SPATIAL cell (or
/// its `unassigned` receptacle), OR — in the degrade path (no sections
/// configured) — a 1:1 mirror of one facet workspace (by-workspace stays a
/// first-class citizen), OR one of the 1–2 sections a LENS DESKTOP synthesizes
/// from its `match` (`projectLensDesktop`). The tree consumes this via
/// `SidebarView.update(sections:)`; the grid + rail render each section as a
/// cell — but only on a workspace desktop, since a lens desktop is TREE-ONLY
/// (its membership is dynamic, so there is no fixed picture to thumbnail).
///
/// `sourceWorkspaceIndex` is the **0-based wire index** of the workspace
/// this section maps to (so `--focus` / `--move-to` hit the right WS),
/// mirroring `Workspace.index`. It is `nil` for a lens desktop's synthesized
/// sections, which span the desktop and have no single source WS.
/// `Sendable` (unlike the view-built `OverviewCell`): the consumer produces
/// this on the adapter's `cliQueue` and hands it to `main`, so it crosses
/// threads. All fields are already `Sendable` (`Window` is).
public struct ProjectedSection: Sendable {
    /// Stable, unique identity for view signatures / cell tracking.
    /// Degrade / workspace section: `"ws:<index>"`. A lens desktop's matched
    /// section: `"section:<declOrder>:<label>"` (`declOrder` is always 0 — it
    /// is the desktop's one lens). Unassigned section (§G):
    /// `"unassigned:<declOrder>"`.
    public let id: String
    public let label: String
    public let windows: [Window]
    public let sourceWorkspaceIndex: Int?
    /// Which section kind produced this section — `.workspace` for the spatial
    /// substrate (the degrade path + the `[[desktop.N.section]]` cells),
    /// `.lens` for the matched section a LENS DESKTOP synthesizes from its
    /// `match`, `.unassigned` for the lost-and-found receptacle. Defaulted so
    /// the degrade path + existing 4-arg call sites need no edit.
    public let sectionType: ProjectedSectionType

    public init(id: String, label: String, windows: [Window],
                sourceWorkspaceIndex: Int?,
                sectionType: ProjectedSectionType = .workspace) {
        self.id = id
        self.label = label
        self.windows = windows
        self.sourceWorkspaceIndex = sourceWorkspaceIndex
        self.sectionType = sectionType
    }
}

extension ProjectedSection: Equatable {
    /// `Window` is not `Equatable`; identity is its `id`, so sections compare
    /// by their scalar fields plus the ordered window-id list (which is the
    /// projection's actual contract — which windows land in which section).
    public static func == (a: ProjectedSection, b: ProjectedSection) -> Bool {
        a.id == b.id && a.label == b.label
            && a.sourceWorkspaceIndex == b.sourceWorkspaceIndex
            && a.sectionType == b.sectionType
            && a.windows.map(\.id) == b.windows.map(\.id)
    }
}

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
    /// Which section kind this cell renders — `.workspace` (the spatial
    /// substrate), `.unassigned` (the lost-and-found receptacle) or `.lens`.
    /// The overviews only ever run on a workspace desktop (a lens desktop is
    /// TREE-ONLY), and `FilterProjection.project` mints no `.lens` section, so
    /// the `.lens` cases here are the shared section vocabulary, not a shape
    /// the grid / rail build today. Defaulted so every existing 8-arg call site
    /// compiles unchanged.
    public let sectionType: ProjectedSectionType
    /// The `ProjectedSection.id` this cell came from (`"ws:<i>"` /
    /// `"unassigned:<declOrder>"`) — stable identity for routing /
    /// signatures. Empty for legacy workspace-built cells.
    public let sectionID: String

    /// True for a `.lens` cell — a section that spans the desktop instead of
    /// mirroring one workspace, so it is never a move/swap target (no source
    /// workspace; `wsIndex == -1`).
    public var isLens: Bool { sectionType == .lens }

    public init(wsIndex: Int, rect: CGRect, headerRect: CGRect,
                isActive: Bool, label: String, mode: String,
                windows: [MiniWindowHit], isHero: Bool = false,
                sectionType: ProjectedSectionType = .workspace,
                sectionID: String = "") {
        self.wsIndex = wsIndex
        self.rect = rect
        self.headerRect = headerRect
        self.isActive = isActive
        self.label = label
        self.mode = mode
        self.windows = windows
        self.isHero = isHero
        self.sectionType = sectionType
        self.sectionID = sectionID
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

    /// True once the backend reflects the move: the dropped `id` now
    /// lives in `dstWS`. Shared by the grid + rail landing gates.
    public func landed(in workspaces: [Workspace]) -> Bool {
        workspaces.contains { ws in
            ws.index == dstWS && ws.windows.contains { $0.id == id }
        }
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

    /// True once the backend reports both halves of the swap: every
    /// `srcID` now in `dstWS` and every `dstID` now in `srcWS`. Shared by
    /// the grid + rail landing gates.
    public func landed(in workspaces: [Workspace]) -> Bool {
        guard let s = workspaces.first(where: { $0.index == srcWS }),
              let d = workspaces.first(where: { $0.index == dstWS })
        else { return false }
        let srcNow = Set(s.windows.map(\.id))
        let dstNow = Set(d.windows.map(\.id))
        return srcIDs.allSatisfy(dstNow.contains)
            && dstIDs.allSatisfy(srcNow.contains)
    }
}
