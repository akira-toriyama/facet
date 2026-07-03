import Testing
@testable import FacetCore

/// `DesktopTab.displayLabel` (t-wrd2 / W2.4) — the caption the tree tab bar
/// shows for a board. Unlike `sectionDisplayLabel` (always index-first), a
/// board shows its `label`; an UNNAMED board falls back to a type-default name
/// (`Workspaces` / `Lenses`) so the tab is never blank and the type reads at a
/// glance. The 1-based index is CLI-addressing only (`facet board --focus N`),
/// never shown in the tab. Pure; CI-only (CLT can't run `swift test`).
struct BoardLabelTests {

    @Test func namedWorkspaceBoardShowsItsLabel() {
        #expect(DesktopTab(type: .workspace, label: "Spaces").displayLabel ==
                       "Spaces")
    }

    @Test func namedLensBoardShowsItsLabel() {
        #expect(DesktopTab(type: .lens, label: "Views").displayLabel ==
                       "Views")
    }

    @Test func unnamedWorkspaceBoardFallsBackToTypeDefault() {
        #expect(DesktopTab(type: .workspace, label: "").displayLabel ==
                       "Workspaces")
    }

    @Test func unnamedLensBoardFallsBackToTypeDefault() {
        #expect(DesktopTab(type: .lens, label: "").displayLabel ==
                       "Lenses")
    }

    /// N2 (board review follow-up): a WHITESPACE-only label is treated as
    /// unnamed too — `displayLabel`'s contract is "never blank", so it trims
    /// before the emptiness test rather than drawing a blank tab. (Distinct
    /// from `sectionDisplayLabel`, which always prepends an index and so is
    /// never blank regardless of label.)
    @Test func whitespaceOnlyLabelFallsBackToTypeDefault() {
        #expect(DesktopTab(type: .workspace, label: "   ").displayLabel ==
                       "Workspaces")
        #expect(DesktopTab(type: .lens, label: "\t").displayLabel ==
                       "Lenses")
        #expect(DesktopTab(type: .workspace, label: "\n").displayLabel ==
                       "Workspaces")
    }
}
