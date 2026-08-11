import AppKit              // NSImage (TreeListItem's per-row glyphs)
import Observation
import FacetCore
import ThemeKitUI          // ListItem / Badge / BadgeRole / ListPreview
import ListCore            // pure DnD math (dragCandidates / chunkMemberIDs / DropTarget)
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

    /// The EXACT sections the current rows were built from — see `apply()`.
    public private(set) var renderedSections: [ProjectedSection] = []
    /// The raw inputs of the last `apply`, so `setQuery` can re-project
    /// without the host re-feeding sections (facet-3 live filter).
    private var sourceSections: [ProjectedSection] = []
    private var sourceActiveWS: Int?
    private var layoutModeProvider: (ProjectedSection) -> String? = { _ in nil }
    /// AX-resolved titles for windows the backend left blank, STORED for the
    /// same reason `layoutModeProvider` is: `setQuery`'s re-projection re-enters
    /// `apply` without them, and dropping them there would blank every
    /// Electron-class row (and un-find it in the filter) on the first keystroke.
    private var titleOverride: [WindowID: String] = [:]

    /// Live search filter (facet-3): re-projects rows/renderedSections from
    /// the stored inputs. Cheap no-op on an unchanged query.
    public func setQuery(_ q: String) {
        guard q != query else { return }
        query = q
        apply(sections: sourceSections, activeWorkspaceIndex: sourceActiveWS)
    }

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
                      activeWorkspaceIndex: Int? = nil,
                      titles: [WindowID: String]? = nil,
                      layoutMode: ((ProjectedSection) -> String?)? = nil) {
        sourceSections = sections
        sourceActiveWS = activeWorkspaceIndex
        // The layout-abbrev provider is STORED so the `setQuery` re-projection
        // (which re-enters apply with no `layoutMode` argument) keeps the
        // header sub-lines instead of silently dropping them.
        if let layoutMode { layoutModeProvider = layoutMode }
        if let titles { titleOverride = titles }
        rows = buildTreeRows(
            sections: sections, query: query,
            titles: titleOverride,
            layoutMode: layoutModeProvider,
            isActive: { s in
                s.sectionType == .workspace && activeWorkspaceIndex != nil
                    && s.sourceWorkspaceIndex == activeWorkspaceIndex
            })
        // The EMITTED sections, aligned with the rows' group ordinals (the
        // same zero-match drop buildTreeRows walks). Hosts resolve a
        // TreeItemID's group against THIS array — never against their own
        // section list, whose indices diverge from emitted ordinals the
        // moment a query drops a section (the t-tsxg facet-3 ordinal bug,
        // fixed at the root here).
        renderedSections = sections.filter { s in
            query.isEmpty || s.windows.contains { matches(query, $0, titleOverride) }
        }
        listItems = rows.map(TreeListItem.make(_:))   // memoize here, NOT in the view body
        rowsRebuildCount += 1
        let ids = Set(rows.map(\.id))
        collapsed.formIntersection(ids)
        if let h = highlight, !ids.contains(h) { highlight = nil }
        reconcileKbDrag(ids)

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
            let wins = s.windows.filter { matches(query, $0, titleOverride) }
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

    /// Park the cursor on a specific row — the wake-on-click path (R12) parks
    /// on the CLICKED row, not the seed's selection-or-first fallback.
    public func parkCursor(on id: TreeItemID) {
        guard rows.contains(where: { $0.id == id }) else { return }
        highlight = id
    }

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

    // MARK: - Keyboard drag (facet-2)
    //
    // The host-driven mirror of sill's internal lift/aim/commit: the host
    // monitor swallows Space/arrows/Return/Esc in nav mode (the §4.8
    // load-bearing invariant), so `ThemedListView`'s own `.onKeyPress` drag
    // can never fire — the SAME pure `ListCore` math runs here instead, and
    // the lift renders through the list's preview seam (`dragPreview`), which
    // draws the ghost / insertion line / onto band exactly as an internal
    // drag would.

    private(set) var kbDragSource: TreeItemID?
    private var kbDragChunk: [TreeItemID] = []
    private var kbDragAim: [ListCore.DropTarget<TreeItemID>] = []
    private var kbDragAimIndex = 0

    public var isKbDragging: Bool { kbDragSource != nil }

    private var visibleAsRows: [ListRow<TreeItemID>] {
        ListItem.visibleRows(listItems, collapsed: collapsed).map(\.asRow)
    }

    /// Space on the cursor: lift it. A header lifts its whole section chunk
    /// and aims at section gaps (sill `liftKeyboard` parity). A WINDOW lift
    /// aims a COARSE per-section ladder instead of sill's fine per-row run —
    /// the commit is section-granular (window order inside a workspace is
    /// backend-derived), so per-row candidates made most presses appear to
    /// change nothing and crossing an 8-window section took ~16 presses. One
    /// press = one section, and the aim STARTS on the lifted row's own
    /// section (old `kbDropWS = liftSourceWS()` parity), not the top of the
    /// tree.
    public func liftCursor() {
        guard kbDragSource == nil, let h = highlight else { return }
        let rows = visibleAsRows
        var chunk: [TreeItemID] = []
        var aim: [ListCore.DropTarget<TreeItemID>]
        var start = 0
        if case .header = h {
            chunk = chunkMemberIDs(forHeader: h, rows: rows)
            aim = dragCandidates(source: h, rows: rows, mode: .both,
                                 chunkIDs: chunk, validate: { _, _ in true })
        } else {
            (aim, start) = windowLiftAim(for: h)
        }
        guard !aim.isEmpty else { return }
        kbDragSource = h; kbDragChunk = chunk; kbDragAim = aim; kbDragAimIndex = start
    }

    /// The window lift's ladder: one `.onto(section header)` per
    /// workspace-backed section (matched/holding are not destinations, and
    /// `treeDrop` derives the destination section from the header id), plus
    /// the index of the source's OWN section to seed the aim on. sill draws
    /// `.onto(header)` as a ring on the header row, so the affordance reads
    /// "lands in THAT section" — section-granular, like the commit.
    private func windowLiftAim(for id: TreeItemID)
        -> ([ListCore.DropTarget<TreeItemID>], Int) {
        var aim: [ListCore.DropTarget<TreeItemID>] = []
        var start = 0
        guard case .window(let g, _) = id else { return ([], 0) }
        for (k, sec) in renderedSections.enumerated()
        where sec.sourceWorkspaceIndex != nil {
            if k == g { start = aim.count }
            aim.append(ListCore.DropTarget(placement: .onto(id: .header(sec.id))))
        }
        return (aim, start)
    }

    /// Arrow keys while lifted: walk the candidate ladder (clamped).
    public func aimDrag(_ delta: Int) {
        guard isKbDragging, !kbDragAim.isEmpty else { return }
        kbDragAimIndex = max(0, min(kbDragAim.count - 1, kbDragAimIndex + delta))
    }

    public func cancelDrag() {
        kbDragSource = nil; kbDragChunk = []; kbDragAim = []; kbDragAimIndex = 0
    }

    /// Return / second Space: hand the host the (context, target) to commit
    /// (nil when nothing was lifted). Clears the lift either way.
    public func commitDrag() -> (ListCore.DragContext<TreeItemID>,
                                 ListCore.DropTarget<TreeItemID>)? {
        defer { cancelDrag() }
        guard let s = kbDragSource,
              kbDragAim.indices.contains(kbDragAimIndex) else { return nil }
        let members = kbDragChunk.isEmpty ? [s] : kbDragChunk
        return (ListCore.DragContext(sourceID: s, memberIDs: members),
                kbDragAim[kbDragAimIndex])
    }

    /// The preview the view passes to sill while a keyboard lift is up.
    /// Live selection/highlight ride along — the preview seam OVERRIDES them
    /// when non-nil, so leaving them out would blank the fill mid-lift.
    var dragPreview: ListPreview<TreeItemID>? {
        guard let s = kbDragSource else { return nil }
        return ListPreview(
            selection: selection, highlight: highlight, dragSource: s,
            dropTarget: kbDragAim.indices.contains(kbDragAimIndex)
                ? kbDragAim[kbDragAimIndex] : nil,
            dragChunk: kbDragChunk.isEmpty ? nil : kbDragChunk)
    }

    /// Keep a lift honest across the 2 s refresh (`apply`): the AppKit tree's
    /// lift survived reconciles, so this one does too — re-derive the chunk +
    /// candidates against the NEW rows, clamp the aim, and only a vanished
    /// source cancels.
    private func reconcileKbDrag(_ ids: Set<TreeItemID>) {
        guard let s = kbDragSource else { return }
        guard ids.contains(s) else { cancelDrag(); return }
        let rows = visibleAsRows
        if case .header = s {
            kbDragChunk = chunkMemberIDs(forHeader: s, rows: rows)
            kbDragAim = dragCandidates(source: s, rows: rows, mode: .both,
                                       chunkIDs: kbDragChunk, validate: { _, _ in true })
        } else {
            // Same coarse per-section ladder the lift built — re-derived
            // against the refreshed sections (the aim INDEX is preserved via
            // the clamp below, matching the fine ladder's behaviour).
            (kbDragAim, _) = windowLiftAim(for: s)
        }
        if kbDragAim.isEmpty { cancelDrag() }
        else { kbDragAimIndex = min(kbDragAimIndex, kbDragAim.count - 1) }
    }

    /// The cursor row's spec (the `m`-menu needs its kind/pid), or nil.
    public func cursorRow() -> TreeRowSpec? {
        guard let h = highlight else { return nil }
        return row(h)
    }

    /// Any row's spec by id — the host's right-click hit-test resolves a rect
    /// to an id and needs the same kind/pid the cursor path gets.
    public func row(_ id: TreeItemID) -> TreeRowSpec? {
        rows.first { $0.id == id }
    }

    /// Content-space offset (y-down from the tree's top) of the row's TOP —
    /// summed sill `ListMetrics` heights over the visible rows above it — or
    /// nil when the id isn't visible. Since sill 7.0.0 the list publishes live
    /// viewport rects for laid-out rows (`PanelHost.rowScreenRect`); this sum
    /// is the scroll-blind FALLBACK `PanelHost` anchors from when the row is
    /// culled out of the viewport.
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
