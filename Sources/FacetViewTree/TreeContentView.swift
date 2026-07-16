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
public struct TreeContentView: View {
    @Bindable var model: TreeViewModel
    var onActivate: (TreeItemID) -> Void = { _ in }
    var onToggleSection: (TreeItemID) -> Void = { _ in }
    var onHover: (TreeItemID?) -> Void = { _ in }

    /// Public so `PanelHost` (FacetApp) can host this in an `NSHostingView`.
    /// Callbacks default to no-ops — the host wires real #66 activation
    /// (Task 12), header-collapse, and hover-preview as they land.
    public init(model: TreeViewModel,
                onActivate: @escaping (TreeItemID) -> Void = { _ in },
                onToggleSection: @escaping (TreeItemID) -> Void = { _ in },
                onHover: @escaping (TreeItemID?) -> Void = { _ in }) {
        self.model = model
        self.onActivate = onActivate
        self.onToggleSection = onToggleSection
        self.onHover = onHover
    }

    public var body: some View {
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
