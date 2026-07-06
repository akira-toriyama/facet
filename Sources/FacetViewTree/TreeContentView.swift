import SwiftUI
import ThemeKitUI
import FacetCore
import FacetView

/// facet-1 render surface: binds the memoized `TreeViewModel.listItems` to
/// sill's `ThemedListView`. `listItems` is rebuilt only in `apply()`, so a
/// palette tick re-runs this body cheaply (no row re-flatten / NSImage rebuild
/// — spec §4.6/§7.7). The `TreeRowSpec→ListItem` map lives in `TreeListItem`
/// (Task 6), invoked only from `apply()`. Callbacks are host-injected (real
/// #66 activation + collapse land in Tasks 8/10/12).
@MainActor
struct TreeContentView: View {
    @Bindable var model: TreeViewModel
    var onActivate: (TreeItemID) -> Void = { _ in }
    var onToggleSection: (TreeItemID) -> Void = { _ in }
    var onHover: (TreeItemID?) -> Void = { _ in }

    var body: some View {
        var style = ThemedListStyle()
        style.selectionMode = .single
        style.highlightStyle = .outline
        style.showsDividers = true
        style.zebra = true
        style.horizontalContentScroll = true
        style.hosted = false
        return ThemedListView<TreeItemID>(
            items: model.listItems,
            selection: $model.selection,
            collapsed: $model.collapsed,
            highlight: $model.highlight,
            style: style,
            palette: model.palette,
            onActivate: onActivate,
            onToggleSection: onToggleSection,
            onHover: onHover)
    }
}
