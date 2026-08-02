import AppKit              // NSImage (TreeListItem's per-row glyphs)
import Observation
import FacetCore
import ThemeKitUI          // ListItem / Badge / BadgeRole
import FacetView           // AppIcons, IconResolver, ResolvedPalette (re-exported)

/// The single @Observable box the SwiftUI tree binds to. Injected via
/// `.environment`; `Controller` is the sole writer. Palette lives here so a
/// re-theme updates ONE value — it must NOT rebuild `rows` OR `listItems`.
/// The 30 Hz animator tick sets only `palette` (spec §4.6/§7.7).
@Observable
@MainActor
public final class TreeViewModel {
    var rows: [TreeRowSpec] = []
    /// **Memoized** render-ready items — rebuilt ONLY in `apply()` (section-data
    /// change), NEVER read-derived in a SwiftUI body. The expensive per-row
    /// NSImage builds (`AppIcons.icon` / `IconResolver.phosphorImage`) live here,
    /// off the palette-tick path, so a theme animation never re-flattens the list
    /// (spec §4.6/§7.7). The view reads this array; `palette` is passed separately.
    /// Public so `PanelHost` can size the panel by summing `ListMetrics` over it
    /// (via `rowContentHeight`).
    public private(set) var listItems: [ListItem<TreeItemID>] = []
    /// Test hook for success-criterion 5: increments each time `listItems` is
    /// rebuilt. A palette-only mutation must leave this UNCHANGED.
    private(set) var rowsRebuildCount = 0
    var selection: Set<TreeItemID> = []
    var highlight: TreeItemID?
    var collapsed: Set<TreeItemID> = []
    var query: String = ""
    var isLoading: Bool = false
    /// Public get+set — `PanelHost.applyTheme()` repoints this on every theme
    /// change (hot-reload + the 30 Hz animator tick), the ONLY per-frame write.
    public var palette: ResolvedPalette

    public init(palette: ResolvedPalette) { self.palette = palette }

    /// Optimistic focus claim (Task 11): the row a click/Enter just acted on,
    /// held against the backend focus-assert race for 0.85 s (the same window
    /// `SidebarView.setOptimistic` protects). While the hold stands, `apply()`
    /// keeps `selection` on the claim instead of the projection's `isFocused`.
    private var optimisticID: TreeItemID?
    private var optimisticUntil: Date?

    /// Rebuild rows + memoized items from a fresh projection. Highlight/
    /// collapsed are id-keyed and survive across rebuilds (dropped only if their
    /// id vanishes). `selection` (the focus FILL) is derived here: the
    /// optimistic claim while its hold stands, else the projection's focused
    /// window scoped to the active section — `hot(win) && headerActive(ws)`
    /// parity with `SidebarView.update`. Palette is NOT touched here.
    public func apply(sections: [ProjectedSection],
                      activeWorkspaceIndex: Int? = nil) {
        rows = buildTreeRows(sections: sections, query: query)
        listItems = rows.map(TreeListItem.make(_:))   // memoize here, NOT in the view body
        rowsRebuildCount += 1
        let ids = Set(rows.map(\.id))
        collapsed.formIntersection(ids)
        if let h = highlight, !ids.contains(h) { highlight = nil }

        if let opt = optimisticID, let until = optimisticUntil, Date() < until {
            // A vanished claim row (moved/closed mid-hold) clears the fill —
            // same as the legacy signature dropping the O-token.
            selection = ids.contains(opt) ? [opt] : []
        } else {
            optimisticID = nil; optimisticUntil = nil
            selection = Set(focusedRowID(sections: sections,
                                         activeWorkspaceIndex: activeWorkspaceIndex)
                                .map { [$0] } ?? [])
        }
    }

    /// The focused window's row id, scoped to the ACTIVE section (a window in
    /// a parked / non-active workspace section never shows as focused). An
    /// isolate desktop's synthesized sections carry no workspace index — their
    /// focused window keeps the fill (they are the only sections shown there).
    private func focusedRowID(sections: [ProjectedSection],
                              activeWorkspaceIndex: Int?) -> TreeItemID? {
        var group = 0
        for s in sections {
            let wins = s.windows.filter { matches(query, $0) }
            if !query.isEmpty && wins.isEmpty { continue }   // mirror buildTreeRows' group numbering
            let active = s.sourceWorkspaceIndex == nil
                || s.sourceWorkspaceIndex == activeWorkspaceIndex
            if active, let w = wins.first(where: { $0.isFocused }) {
                return .window(group: group, w.id)
            }
            group += 1
        }
        return nil
    }

    /// Claim the fill for an acted-on row NOW (before the backend round-trip
    /// lands) and hold it for 0.85 s — `SidebarView.setOptimistic` parity.
    public func setOptimistic(_ id: TreeItemID) {
        optimisticID = id
        optimisticUntil = Date().addingTimeInterval(0.85)
        selection = rows.contains(where: { $0.id == id }) ? [id] : []
    }

    // MARK: - Keyboard cursor (Task 10)
    //
    // The cursor is `highlight` (sill's outline); `selection` (the fill) stays
    // the focused-window row — cursor ≠ selection, the facet tree invariant.
    // These mirror the pure `KbNav` math over `rows`: every row is selectable
    // (`TreeRowSpec` has only header/window kinds — no separators).

    /// Seed the cursor entering keyboard nav: keep a still-valid cursor, else
    /// the focused row, else the first row — `enterKbNav`/`kbDefault` parity.
    public func seedCursor() {
        if let h = highlight, rows.contains(where: { $0.id == h }) { return }
        highlight = selection.first ?? rows.first?.id
    }

    public func clearCursor() { highlight = nil }

    /// Arrow-ladder move — `kbMoveTarget` parity: no cursor anchors at the
    /// top, the ends clamp.
    public func moveCursor(_ delta: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let pos = highlight.flatMap { h in ids.firstIndex(of: h) } ?? 0
        highlight = ids[min(max(pos + delta, 0), ids.count - 1)]
    }

    /// Jump to the prev/next render group: its first window, else its header
    /// (empty group) — `kbJumpTarget` parity. Group ordinals ARE the header
    /// order: `buildTreeRows` numbers emitted sections 0…n in row order.
    public func jumpSection(_ delta: Int) {
        let headerIDs: [TreeItemID] = rows.compactMap {
            if case .header = $0.kind { return $0.id }
            return nil
        }
        guard !headerIDs.isEmpty else { return }
        let curGroup: Int? = {
            switch highlight {
            case .window(let g, _): return g
            case .header: return headerIDs.firstIndex { $0 == highlight }
            case nil: return nil
            }
        }()
        let g = min(max((curGroup ?? 0) + delta, 0), headerIDs.count - 1)
        if let firstWin = rows.first(where: {
            if case .window(let rg, _) = $0.id { return rg == g }
            return false
        }) {
            highlight = firstWin.id
        } else {
            highlight = headerIDs[g]
        }
    }

    /// The row the cursor is on — Enter's commit target.
    public func activateCursor() -> TreeItemID? { highlight }

    /// The cursor row's spec (the `m`-menu needs its kind/pid), or nil.
    public func cursorRow() -> TreeRowSpec? {
        guard let h = highlight else { return nil }
        return rows.first { $0.id == h }
    }

    /// Content-space offset (y-down from the tree's top) of the row's TOP —
    /// summed sill `ListMetrics` heights over the visible rows above it — or
    /// nil when the id isn't visible. The SwiftUI list exposes no row rects,
    /// so `PanelHost` anchors the keyboard context menu (`m`) from this.
    public func rowTop(of id: TreeItemID) -> CGFloat? {
        let m = ListMetrics.forDensity(.comfortable)
        var y: CGFloat = 0
        for item in ListItem.visibleRows(listItems, collapsed: collapsed) {
            if item.id == id { return y }
            y += Self.itemHeight(item, m)
        }
        return nil
    }

    /// The tree's own content height = summed sill `ListMetrics` row heights over
    /// the memoized `listItems` (chrome-band-free). sill's `ThemedListView` root
    /// is a greedy SwiftUI `ScrollView` that never self-reports a fitting height,
    /// so `PanelHost` sizes the shrink-to-content panel from this instead of
    /// `NSHostingView.fittingSize` (which would collapse it — spec §4.1 / Task
    /// 8.2). `PanelHost` adds the pinned chrome bands + screen clamp. Kept HERE
    /// (not in `PanelHost`) so the ThemeKitUI/`ListMetrics` dependency stays
    /// confined to `FacetViewTree`. Density matches `TreeContentView`'s
    /// `ThemedListStyle()` default (`.comfortable`).
    public var rowContentHeight: CGFloat {
        let m = ListMetrics.forDensity(.comfortable)
        // Sum over the VISIBLE rows — `ListItem.visibleRows` is the exact
        // collapse-filter `ThemedListView` renders through, so a collapsed
        // header shrinks the panel instead of leaving a blank gap below the
        // tree. Collapse is inert in facet-1 (nothing writes `collapsed`), so
        // this equals the full sum today; it stays correct when header-collapse
        // lands (F2/Task 12).
        return ListItem.visibleRows(listItems, collapsed: collapsed)
            .reduce(CGFloat(0)) { $0 + Self.itemHeight($1, m) }
    }

    /// Panel body height while the loading skeleton is up — three placeholder
    /// sections (header + two rows each), the legacy `SidebarView.skeletonHeight`
    /// shape in sill metrics. Lives here so `ListMetrics` stays confined to
    /// `FacetViewTree` (the `rowContentHeight` rationale).
    public static var skeletonContentHeight: CGFloat {
        let m = ListMetrics.forDensity(.comfortable)
        return m.header1 * 3 + m.singleRow * 6 + 12
    }

    /// One row's sill render height — the single source `rowContentHeight`
    /// (panel auto-size) and `rowTop` (menu anchor) both sum over.
    private static func itemHeight(_ item: ListItem<TreeItemID>,
                                   _ m: ListMetrics) -> CGFloat {
        switch item.kind {
        case let .sectionHeader(subtitle, _):
            return subtitle == nil ? m.header1 : m.header2
        case .row:
            return item.secondary == nil ? m.singleRow : m.twoLineRow
        case .separator:
            return m.separatorBand
        }
    }
}

/// `TreeRowSpec` → sill `ListItem` mapping. Lives here (not in the SwiftUI body)
/// so it is invoked from `apply()` and memoized — see `TreeViewModel.listItems`.
/// Palette-independent: NSImage builds key only on pid/slug, never on colour.
@MainActor
enum TreeListItem {
    static func make(_ r: TreeRowSpec) -> ListItem<TreeItemID> {
        switch r.kind {
        case let .header(type, subtitle):
            return ListItem(id: r.id, image: headerGlyph(type),
                            primary: r.primary, kind: .sectionHeader(subtitle: subtitle))
        case let .window(pid):
            return ListItem(id: r.id, image: AppIcons.icon(forPID: pid),
                            primary: r.primary, secondary: r.secondary,
                            badges: r.badges.map(badge(_:)))
        }
    }

    private static func headerGlyph(_ type: ProjectedSectionType) -> NSImage? {
        let slug: String?
        switch type {
        case .matched: slug = "funnel"
        // The isolate desktop's holding bucket is NOT the lost-and-found
        // receptacle (t-mqqw) — give it its own glyph so the chrome stops
        // asserting a kinship the model does not have.
        case .holding: slug = "tray"
        case .workspace: slug = nil
        }
        return slug.flatMap { IconResolver.phosphorImage($0, pt: 13) }
    }

    private static func badge(_ b: TreeBadge) -> Badge {
        let slug: String?
        let role: BadgeRole
        switch b.kind {
        case .master: slug = "crown"; role = .primary
        case .float: slug = "app-window"; role = .secondary
        case .sticky: slug = "push-pin"; role = .secondary
        case .hidden: slug = "eye-slash"; role = .error
        case .mark: slug = nil; role = .primary
        case .scratchpad: slug = "tray"; role = .secondary
        case .tag: slug = "tag"; role = .neutral
        case .overflow: slug = nil; role = .neutral
        }
        return Badge(b.text, symbol: slug.flatMap { IconResolver.phosphorImage($0, pt: 11) }, role: role)
    }
}
