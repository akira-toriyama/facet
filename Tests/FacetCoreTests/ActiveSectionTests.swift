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

/// EX-2b: `activeSectionID` resolves the single lit section's stable id,
/// matching `overviewCellSources`'s XOR (lens label wins; else the active
/// workspace's section; degrade ⇒ `"ws:<idx>"`). Used by the persistent-rail
/// re-centre to follow the active section.
final class ActiveSectionIDTests: XCTestCase {
    private func ws(_ i: Int) -> ProjectedSection {
        ProjectedSection(id: "ws:\(i)", label: "W\(i)", windows: [],
                         sourceWorkspaceIndex: i, sectionType: .workspace)
    }
    private func lens(_ order: Int, _ label: String) -> ProjectedSection {
        ProjectedSection(id: "section:\(order):\(label)", label: label, windows: [],
                         sourceWorkspaceIndex: nil, sectionType: .lens)
    }

    func testLensActiveWins() {
        let secs = [ws(0), ws(1), lens(2, "Web")]
        XCTAssertEqual(activeSectionID(activeLens: "Web", activeIndex: 0, sections: secs),
                       "section:2:Web")
    }

    func testWorkspaceActiveWhenNoLens() {
        let secs = [ws(0), ws(1), lens(2, "Web")]
        XCTAssertEqual(activeSectionID(activeLens: nil, activeIndex: 1, sections: secs), "ws:1")
    }

    func testDegradeEmptySections() {
        XCTAssertEqual(activeSectionID(activeLens: nil, activeIndex: 2, sections: []), "ws:2")
    }

    func testNilIndexNoLensIsNil() {
        XCTAssertNil(activeSectionID(activeLens: nil, activeIndex: nil, sections: []))
    }

    func testUnknownLensFallsBackNil() {
        // An active lens label not present in the section list ⇒ nothing lit.
        XCTAssertNil(activeSectionID(activeLens: "Ghost", activeIndex: 0, sections: [lens(1, "Web")]))
        XCTAssertNil(activeSectionID(activeLens: "Web", activeIndex: 0, sections: [ws(0), ws(1)]))
    }
}
