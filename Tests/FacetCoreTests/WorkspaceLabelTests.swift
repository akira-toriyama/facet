import Testing
@testable import FacetCore

/// `sectionDisplayLabel` — the §D shared section caption the grid / rail /
/// tree all compose. `index` is the FINAL 1-based tree position (no internal
/// `+1`); an optional label follows in parens. Replaces the retired
/// `workspaceShortLabel` ("WS<n>" / "workspace " prefix-strip).
struct WorkspaceLabelTests {

    /// Parameterized reference: table-style cases fold into one `@Test` with
    /// `arguments:` — each row runs (and reports failures) independently.
    /// No prefix-strip / casing / emoji decoration — the label renders exactly
    /// as authored (§B retired the emoji pool, §D the prefix-strip).
    @Test("index alone, or index (label) verbatim", arguments: [
        (index: 1, label: "", expected: "1"),
        (index: 5, label: "", expected: "5"),
        (index: 1, label: "Code", expected: "1 (Code)"),
        (index: 4, label: "Web", expected: "4 (Web)"),
        (index: 2, label: "WORKSPACE Q", expected: "2 (WORKSPACE Q)"),
        (index: 3, label: "my workspace", expected: "3 (my workspace)"),
        (index: 7, label: "🐶", expected: "7 (🐶)"),
    ])
    func compose(index: Int, label: String, expected: String) {
        #expect(sectionDisplayLabel(index: index, label: label) == expected)
    }
}
