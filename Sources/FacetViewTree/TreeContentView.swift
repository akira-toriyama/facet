import SwiftUI
import ThemeKitUI
import PaletteKit

/// facet-1 render surface. Placeholder body until the view-model lands (Task 7).
@MainActor
struct TreeContentView: View {
    let palette: ResolvedPalette
    var body: some View {
        var style = ThemedListStyle()
        style.selectionMode = .single
        style.highlightStyle = .outline
        return ThemedListView<String>(
            items: [
                ListItem(id: "h", primary: "workspace · 1", kind: .sectionHeader()),
                ListItem(id: "w", primary: "Safari", secondary: "GitHub"),
            ],
            style: style,
            palette: palette)
    }
}
