import XCTest
@testable import FacetCore

/// `DesktopTab.displayLabel` (t-wrd2 / W2.4) — the caption the tree tab bar
/// shows for a board. Unlike `sectionDisplayLabel` (always index-first), a
/// board shows its `label`; an UNNAMED board falls back to a type-default name
/// (`Workspaces` / `Lenses`) so the tab is never blank and the type reads at a
/// glance. The 1-based index is CLI-addressing only (`facet board --focus N`),
/// never shown in the tab. Pure; CI-only (CLT can't run `swift test`).
final class BoardLabelTests: XCTestCase {

    func testNamedWorkspaceBoardShowsItsLabel() {
        XCTAssertEqual(DesktopTab(type: .workspace, label: "Spaces").displayLabel,
                       "Spaces")
    }

    func testNamedLensBoardShowsItsLabel() {
        XCTAssertEqual(DesktopTab(type: .lens, label: "Views").displayLabel,
                       "Views")
    }

    func testUnnamedWorkspaceBoardFallsBackToTypeDefault() {
        XCTAssertEqual(DesktopTab(type: .workspace, label: "").displayLabel,
                       "Workspaces")
    }

    func testUnnamedLensBoardFallsBackToTypeDefault() {
        XCTAssertEqual(DesktopTab(type: .lens, label: "").displayLabel,
                       "Lenses")
    }
}
