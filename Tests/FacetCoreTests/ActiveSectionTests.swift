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
/// matching `overviewCellSources` (the active workspace's section; degrade ⇒
/// `"ws:<idx>"`). Keyed on the stable id, not the display label. Used by the
/// persistent-rail re-centre to follow the active section.
struct ActiveSectionIDTests {
    private func ws(_ i: Int) -> ProjectedSection {
        ProjectedSection(id: "ws:\(i)", label: "W\(i)", windows: [],
                         sourceWorkspaceIndex: i, sectionType: .workspace)
    }
    private func lens(_ order: Int, _ label: String) -> ProjectedSection {
        ProjectedSection(id: "section:\(order):\(label)", label: label, windows: [],
                         sourceWorkspaceIndex: nil, sectionType: .matched)
    }

    @Test func activeWorkspaceSectionWins() {
        let secs = [ws(0), ws(1), lens(2, "Web")]
        #expect(activeSectionID(activeIndex: 1, sections: secs) == "ws:1")
    }

    @Test func degradeEmptySections() {
        #expect(activeSectionID(activeIndex: 2, sections: []) == "ws:2")
    }

    @Test func nilIndexIsNil() {
        #expect(activeSectionID(activeIndex: nil, sections: []) == nil)
    }

    @Test func noWorkspaceSectionForActiveIndexIsNil() {
        // The active index has no workspace section here (an isolate desktop's
        // synthesized sections carry no source workspace) ⇒ nothing lit.
        #expect(activeSectionID(activeIndex: 0, sections: [lens(1, "Web")]) == nil)
        #expect(activeSectionID(activeIndex: 5, sections: [ws(0), ws(1)]) == nil)
    }
}
