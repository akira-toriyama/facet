import Testing
@testable import FacetCore

/// Pure tests for the `ActiveSection` concept (EX-1): exactly one section is
/// active — a lens or a workspace. A0: `.lens` carries the STABLE ID
/// (`"section:<declOrder>:<label>"`); `lensID` returns it raw and `lensLabel`
/// parses the display label out of it (the lens-only view existing callers —
/// `currentSectionLens()`, the tree highlight — consume the label).
struct ActiveSectionTests {
    @Test func lensIDReturnsRawPayload() {
        #expect(ActiveSection.lens("section:2:Web").lensID == "section:2:Web")
        #expect(ActiveSection.workspace(2).lensID == nil)
    }

    @Test func lensLabelParsesLabelOutOfID() {
        #expect(ActiveSection.lens("section:2:Web").lensLabel == "Web")
        #expect(ActiveSection.lens("section:0:My Lens").lensLabel == "My Lens")
    }

    @Test func lensLabelKeepsColonInLabel() {
        // declOrder runs to the FIRST colon; the label is the remainder, so a
        // label that itself contains ':' round-trips (mirrors ApplyResolver).
        #expect(ActiveSection.lens("section:3:a:b").lensLabel == "a:b")
    }

    @Test func lensLabelNilForWorkspace() {
        #expect(ActiveSection.workspace(2).lensLabel == nil)
    }

    @Test func lensLabelNilForMalformedID() {
        // A non-id payload can't yield a label (never happens for an id minted
        // by FilterProjection, but the accessor stays total).
        #expect(ActiveSection.lens("Web").lensLabel == nil)
        #expect(ActiveSection.lens("section:x:Web").lensLabel == nil)   // non-numeric declOrder
    }

    @Test func equalityDiscriminatesCases() {
        // A workspace index and a lens id that happen to print the same must
        // never compare equal (the structural fix for the EX-0.5 stale-mirror
        // swallow: `.workspace(N) != .lens(id)`).
        #expect(ActiveSection.workspace(1) != ActiveSection.lens("1"))
        #expect(ActiveSection.workspace(3) == ActiveSection.workspace(3))
        #expect(ActiveSection.workspace(2) != ActiveSection.workspace(3))
        #expect(ActiveSection.lens("section:2:Web") == ActiveSection.lens("section:2:Web"))
        // Same label, different declOrder ⇒ different id ⇒ different section.
        #expect(ActiveSection.lens("section:2:Web") != ActiveSection.lens("section:5:Web"))
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
