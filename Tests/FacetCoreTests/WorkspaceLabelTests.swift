import XCTest
@testable import FacetCore

/// `sectionDisplayLabel` — the §D shared section caption the grid / rail /
/// tree all compose. `index` is the FINAL 1-based tree position (no internal
/// `+1`); an optional label follows in parens. Replaces the retired
/// `workspaceShortLabel` ("WS<n>" / "workspace " prefix-strip).
final class WorkspaceLabelTests: XCTestCase {

    func testEmptyLabelShowsIndexAlone() {
        XCTAssertEqual(sectionDisplayLabel(index: 1, label: ""), "1")
        XCTAssertEqual(sectionDisplayLabel(index: 5, label: ""), "5")
    }

    func testNonEmptyLabelShowsIndexAndLabel() {
        XCTAssertEqual(sectionDisplayLabel(index: 1, label: "Code"), "1 (Code)")
        XCTAssertEqual(sectionDisplayLabel(index: 4, label: "Web"), "4 (Web)")
    }

    func testLabelKeptVerbatim() {
        // No prefix-strip / casing / emoji decoration — the label renders
        // exactly as authored (§B retired the emoji pool, §D the prefix-strip).
        XCTAssertEqual(sectionDisplayLabel(index: 2, label: "WORKSPACE Q"),
                       "2 (WORKSPACE Q)")
        XCTAssertEqual(sectionDisplayLabel(index: 3, label: "my workspace"),
                       "3 (my workspace)")
        XCTAssertEqual(sectionDisplayLabel(index: 7, label: "🐶"), "7 (🐶)")
    }
}
