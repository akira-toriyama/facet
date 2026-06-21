import XCTest
@testable import FacetCore

/// Pure tests for the `ActiveSection` concept (EX-1): exactly one section is
/// active — a lens or a workspace — and `lensLabel` derives the lens-only view
/// existing callers (`currentSectionLens()`, the tree highlight) consume.
final class ActiveSectionTests: XCTestCase {
    func testLensLabelExtractsLabel() {
        XCTAssertEqual(ActiveSection.lens("Web").lensLabel, "Web")
    }

    func testLensLabelNilForWorkspace() {
        XCTAssertNil(ActiveSection.workspace(2).lensLabel)
    }

    func testEqualityDiscriminatesCases() {
        // A workspace index and a lens label that happen to print the same
        // must never compare equal (the structural fix for the EX-0.5
        // stale-mirror swallow: `.workspace(N) != .lens(label)`).
        XCTAssertNotEqual(ActiveSection.workspace(1), ActiveSection.lens("1"))
        XCTAssertEqual(ActiveSection.workspace(3), ActiveSection.workspace(3))
        XCTAssertNotEqual(ActiveSection.workspace(2), ActiveSection.workspace(3))
        XCTAssertEqual(ActiveSection.lens("Web"), ActiveSection.lens("Web"))
        XCTAssertNotEqual(ActiveSection.lens("Web"), ActiveSection.lens("Code"))
    }
}
