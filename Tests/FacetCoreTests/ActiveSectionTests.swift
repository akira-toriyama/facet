import Testing
@testable import FacetCore

/// Pure tests for the `ActiveSection` concept: since the section-lens ACTIVATE
/// concept was retired (t-ec9s), a workspace is the only thing ever active — the
/// enum is a single-case value.
struct ActiveSectionTests {
    @Test func workspaceEquality() {
        #expect(ActiveSection.workspace(3) == ActiveSection.workspace(3))
        #expect(ActiveSection.workspace(2) != ActiveSection.workspace(3))
    }
}

/// EX-2b / §A: `activeSectionID` resolves the single lit section's stable id,
/// matching `overviewCellSources`'s XOR (the active lens **id** wins; else the
/// active workspace's section; degrade ⇒ `"ws:<idx>"`). Keyed on the stable id,
/// not the display label. Used by the persistent-rail re-centre to follow the
/// active section.
struct ActiveSectionIDTests {
    private func ws(_ i: Int) -> ProjectedSection {
        ProjectedSection(id: "ws:\(i)", label: "W\(i)", windows: [],
                         sourceWorkspaceIndex: i, sectionType: .workspace)
    }
    private func lens(_ order: Int, _ label: String) -> ProjectedSection {
        ProjectedSection(id: "section:\(order):\(label)", label: label, windows: [],
                         sourceWorkspaceIndex: nil, sectionType: .lens)
    }

    @Test func lensActiveWins() {
        let secs = [ws(0), ws(1), lens(2, "Web")]
        #expect(activeSectionID(activeLensID: "section:2:Web", activeIndex: 0,
                                       sections: secs) == "section:2:Web")
    }

    @Test func workspaceActiveWhenNoLens() {
        let secs = [ws(0), ws(1), lens(2, "Web")]
        #expect(activeSectionID(activeLensID: nil, activeIndex: 1, sections: secs) == "ws:1")
    }

    @Test func degradeEmptySections() {
        #expect(activeSectionID(activeLensID: nil, activeIndex: 2, sections: []) == "ws:2")
    }

    @Test func nilIndexNoLensIsNil() {
        #expect(activeSectionID(activeLensID: nil, activeIndex: nil, sections: []) == nil)
    }

    @Test func unknownLensFallsBackNil() {
        // An active lens id not present in the section list ⇒ nothing lit.
        #expect(activeSectionID(activeLensID: "section:9:Ghost", activeIndex: 0,
                                     sections: [lens(1, "Web")]) == nil)
        #expect(activeSectionID(activeLensID: "section:2:Web", activeIndex: 0,
                                     sections: [ws(0), ws(1)]) == nil)
    }
}
