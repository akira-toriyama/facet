import SwiftUI
import ThemeKitUI
import ListCore
import FacetCore
import FacetView

/// facet-1 render surface: binds the memoized `TreeViewModel.listItems` to
/// sill's `ThemedListView`. `listItems` is rebuilt only in `apply()`, so a
/// palette tick re-runs this body cheaply (no row re-flatten / NSImage rebuild
/// — spec §4.6/§7.7). The `TreeRowSpec→ListItem` map lives in `TreeListItem`
/// (Task 6), invoked only from `apply()`. Callbacks are host-injected (real
/// #66 activation + collapse land in Tasks 8/10/12).
@MainActor
public struct TreeContentView: View {
    @Bindable var model: TreeViewModel
    var onActivate: (TreeItemID) -> Void = { _ in }
    var onToggleSection: (TreeItemID) -> Void = { _ in }
    var onHover: (TreeItemID?) -> Void = { _ in }
    var onDrop: (ListCore.DragContext<TreeItemID>,
                 ListCore.DropTarget<TreeItemID>) -> Void = { _, _ in }
    var onRowRects: ([TreeItemID: CGRect]) -> Void = { _ in }
    /// Host pre-validation (sill's `dropTargetValidator`): the SAME rule set the
    /// commit uses, so a placement the host would refuse draws no affordance and
    /// joins no keyboard aim. Default accepts everything (the pre-wiring
    /// behaviour), so a bare preview/prism call site is unchanged.
    var dropIsValid: (ListCore.DragContext<TreeItemID>,
                      ListCore.DropTarget<TreeItemID>) -> Bool = { _, _ in true }
    /// Host veto over BEGINNING a lift (sill's `dragSourceValidator`): the
    /// holding rows are display-only (t-63h2) — no ghost, no dim, while click
    /// / hover / selection stay alive (`isDisabled` would take those down).
    var dragSourceIsValid: (TreeItemID) -> Bool = { _ in true }
    /// What a pointer lift carries (sill's `dragChunk`): the model's rule —
    /// section mode chunks a header (reorder), the degrade lifts it alone
    /// (workspace swap aims `.onto`).
    var dragChunk: (TreeItemID) -> [TreeItemID]
    /// The rows a resolved drop actually affects (sill's `dropBand`): the
    /// destination SECTION painted as an area for the section-granular
    /// commits (window move / workspace swap); `[]` keeps the line/ring.
    var dropBand: (ListCore.DropTarget<TreeItemID>) -> [TreeItemID] = { _ in [] }

    /// Public so `PanelHost` (FacetApp) can host this in an `NSHostingView`.
    /// Callbacks default to no-ops — the host wires real #66 activation
    /// (Task 12), the drop commits (facet-2), and hover-preview as they land.
    /// `onRowRects` streams the LIVE per-row viewport frames (scroll-true) —
    /// the host anchors the thumbnail previews + the `m`-menu from them.
    public init(model: TreeViewModel,
                onActivate: @escaping (TreeItemID) -> Void = { _ in },
                onToggleSection: @escaping (TreeItemID) -> Void = { _ in },
                onHover: @escaping (TreeItemID?) -> Void = { _ in },
                onDrop: @escaping (ListCore.DragContext<TreeItemID>,
                                   ListCore.DropTarget<TreeItemID>) -> Void = { _, _ in },
                onRowRects: @escaping ([TreeItemID: CGRect]) -> Void = { _ in },
                dropIsValid: @escaping (ListCore.DragContext<TreeItemID>,
                                        ListCore.DropTarget<TreeItemID>) -> Bool = { _, _ in true },
                dragSourceIsValid: @escaping (TreeItemID) -> Bool = { _ in true },
                dropBand: @escaping (ListCore.DropTarget<TreeItemID>)
                    -> [TreeItemID] = { _ in [] }) {
        self.model = model
        self.onActivate = onActivate
        self.onToggleSection = onToggleSection
        self.onHover = onHover
        self.onDrop = onDrop
        self.onRowRects = onRowRects
        self.dropIsValid = dropIsValid
        self.dragSourceIsValid = dragSourceIsValid
        // The chunk rule lives on the model (it owns the rows + render mode);
        // an injected closure would just re-derive the same thing.
        self.dragChunk = { [weak model] id in
            model?.dragChunkMembers(for: id) ?? []
        }
        self.dropBand = dropBand
    }

    public var body: some View {
        var style = ThemedListStyle()
        style.selectionMode = .single
        style.highlightStyle = .outline
        style.showsDividers = true
        style.zebra = true
        // Vertical-only scroll: the two-axis ScrollView CENTERS content
        // shorter/narrower than the viewport (measured on-host 2026-08-03 —
        // the tree floated mid-panel), while vertical-only keeps rows
        // top-anchored and full-width. Long titles truncate with … (they
        // already did — the horizontal axis never visibly engaged); the full
        // text stays reachable via the title tooltip below (ledger M6).
        style.horizontalContentScroll = false
        style.hosted = false
        // facet-2: sill-native mouse DnD (drag gesture + ghost + insertion /
        // onto visuals). `.both` resolves onto-vs-between by row fraction;
        // what a header drag carries is the model's `dragChunkMembers` rule
        // (section mode chunks = reorder, degrade lifts alone = swap).
        style.draggable = true
        style.dragMode = .both
        // The hover restorations (ledger M1 + t-ak5e): the flat row hover
        // fill, and the pointer shapes (rows = link, draggable headers =
        // grab) the old `SidebarView.hoverCursor` pair carried.
        style.showsHoverFill = true
        style.showsPointerAffordances = true
        // Full-title tooltips — the read-the-long-title affordance replacing
        // the retired horizontal scroll (ledger M6 / t-q6ay).
        style.showsTitleTooltips = true
        return ThemedListView<TreeItemID>(
            items: model.listItems,
            selection: $model.selection,
            collapsed: $model.collapsed,
            highlight: $model.highlight,
            style: style,
            palette: model.palette,
            onActivate: onActivate,
            onToggleSection: onToggleSection,
            onHover: onHover,
            onDrop: onDrop,
            onRowRects: onRowRects,
            // The host-driven keyboard lift renders through the preview seam
            // (nil while idle — the live bindings then drive as usual).
            preview: model.dragPreview)
        .dropTargetValidator(dropIsValid)
        .dragSourceValidator(dragSourceIsValid)
        .dragChunk(dragChunk)
        .dropBand(dropBand)
    }
}
