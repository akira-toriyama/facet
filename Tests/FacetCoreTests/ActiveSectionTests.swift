import XCTest
@testable import FacetCore

/// Pure tests for the `ActiveSection` concept (EX-1): exactly one section is
/// active — a lens or a workspace. A0: `.lens` carries the STABLE ID
/// (`"section:<declOrder>:<label>"`); `lensID` returns it raw and `lensLabel`
/// parses the display label out of it (the lens-only view existing callers —
/// `currentSectionLens()`, the tree highlight — consume the label).
final class ActiveSectionTests: XCTestCase {
    func testLensIDReturnsRawPayload() {
        XCTAssertEqual(ActiveSection.lens("section:2:Web").lensID, "section:2:Web")
        XCTAssertNil(ActiveSection.workspace(2).lensID)
    }

    func testLensLabelParsesLabelOutOfID() {
        XCTAssertEqual(ActiveSection.lens("section:2:Web").lensLabel, "Web")
        XCTAssertEqual(ActiveSection.lens("section:0:My Lens").lensLabel, "My Lens")
    }

    func testLensLabelKeepsColonInLabel() {
        // declOrder runs to the FIRST colon; the label is the remainder, so a
        // label that itself contains ':' round-trips (mirrors ApplyResolver).
        XCTAssertEqual(ActiveSection.lens("section:3:a:b").lensLabel, "a:b")
    }

    func testLensLabelNilForWorkspace() {
        XCTAssertNil(ActiveSection.workspace(2).lensLabel)
    }

    func testLensLabelNilForMalformedID() {
        // A non-id payload can't yield a label (never happens for an id minted
        // by FilterProjection, but the accessor stays total).
        XCTAssertNil(ActiveSection.lens("Web").lensLabel)
        XCTAssertNil(ActiveSection.lens("section:x:Web").lensLabel)   // non-numeric declOrder
    }

    func testEqualityDiscriminatesCases() {
        // A workspace index and a lens id that happen to print the same must
        // never compare equal (the structural fix for the EX-0.5 stale-mirror
        // swallow: `.workspace(N) != .lens(id)`).
        XCTAssertNotEqual(ActiveSection.workspace(1), ActiveSection.lens("1"))
        XCTAssertEqual(ActiveSection.workspace(3), ActiveSection.workspace(3))
        XCTAssertNotEqual(ActiveSection.workspace(2), ActiveSection.workspace(3))
        XCTAssertEqual(ActiveSection.lens("section:2:Web"), ActiveSection.lens("section:2:Web"))
        // Same label, different declOrder ⇒ different id ⇒ different section.
        XCTAssertNotEqual(ActiveSection.lens("section:2:Web"), ActiveSection.lens("section:5:Web"))
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
