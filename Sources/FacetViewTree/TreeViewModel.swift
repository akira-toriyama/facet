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
final class TreeViewModel {
    var rows: [TreeRowSpec] = []
    /// **Memoized** render-ready items — rebuilt ONLY in `apply()` (section-data
    /// change), NEVER read-derived in a SwiftUI body. The expensive per-row
    /// NSImage builds (`AppIcons.icon` / `IconResolver.phosphorImage`) live here,
    /// off the palette-tick path, so a theme animation never re-flattens the list
    /// (spec §4.6/§7.7). The view reads this array; `palette` is passed separately.
    private(set) var listItems: [ListItem<TreeItemID>] = []
    /// Test hook for success-criterion 5: increments each time `listItems` is
    /// rebuilt. A palette-only mutation must leave this UNCHANGED.
    private(set) var rowsRebuildCount = 0
    var selection: Set<TreeItemID> = []
    var highlight: TreeItemID?
    var collapsed: Set<TreeItemID> = []
    var query: String = ""
    var isLoading: Bool = false
    var palette: ResolvedPalette

    init(palette: ResolvedPalette) { self.palette = palette }

    /// Rebuild rows + memoized items from a fresh projection. Selection/highlight/
    /// collapsed are id-keyed and survive across rebuilds (dropped only if their id
    /// vanishes). Palette is NOT touched here.
    func apply(sections: [ProjectedSection]) {
        rows = buildTreeRows(sections: sections, query: query)
        listItems = rows.map(TreeListItem.make(_:))   // memoize here, NOT in the view body
        rowsRebuildCount += 1
        let ids = Set(rows.map(\.id))
        selection.formIntersection(ids)
        collapsed.formIntersection(ids)
        if let h = highlight, !ids.contains(h) { highlight = nil }
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
