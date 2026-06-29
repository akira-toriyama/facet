import XCTest
@testable import FacetCore

/// `[[desktop.N.tab]]` + nested `[[desktop.N.tab.section]]` config decode —
/// the nesting-aware reader (t-f19q) that is the prerequisite for the board
/// model (t-wrd2). PURE FacetCore, additive: nothing reads
/// `macDesktopTabConfigs` yet, so this is a no-behavior-change layer proven
/// only by these unit tests. The flat `[[desktop.N.section]]` decoder is
/// UNTOUCHED and the two read disjoint header shapes (verified in
/// `testFlatAndNestedTabsCoexistIndependently`).
///
/// Wire rules (FROZEN here):
///   • a tab's `type` is REQUIRED and may only be `workspace` / `lens`
///     (a `unassigned` / unknown / absent tab type DROPS the whole tab).
///   • child sections carry NO `type` — they INHERIT the parent tab's type;
///     the per-type field rules (`DesktopSection.parse`) re-apply at the
///     inheritance seam.
///   • a child with `unassigned = true` is the per-tab lost-and-found marker
///     (NOT a `type` value, W2.6) — it STILL inherits the parent type, with its
///     `unassigned` flag set; at most one per tab (a 2nd is dropped).
final class DesktopTabDecodeTests: XCTestCase {

    // MARK: - tab type + child inheritance

    func testDecodesWorkspaceAndLensTabs() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspace"
        label = "Spaces"
        [[desktop.1.tab.section]]
        label = "Main"
        [[desktop.1.tab.section]]
        label = "Side"
        [[desktop.1.tab]]
        type = "lens"
        label = "Views"
        [[desktop.1.tab.section]]
        label = "Web"
        match = 'tag~=web'
        """)
        XCTAssertEqual(t[1]?.count, 2)
        XCTAssertEqual(t[1]?[0].type, .workspace)
        XCTAssertEqual(t[1]?[0].label, "Spaces")
        XCTAssertEqual(t[1]?[0].sections.map(\.label), ["Main", "Side"])
        XCTAssertEqual(t[1]?[1].type, .lens)
        XCTAssertEqual(t[1]?[1].label, "Views")
        XCTAssertEqual(t[1]?[1].sections.first,
                       DesktopSection(type: .lens, label: "Web", match: "tag~=web"))
    }

    /// Child sections never author `type`; they inherit the parent tab's type.
    func testChildSectionsInheritParentType() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        [[desktop.1.tab.section]]
        label = "A"
        match = 'tag~=a'
        [[desktop.1.tab.section]]
        label = "B"
        match = 'tag~=b'
        """)
        XCTAssertEqual(t[1]?[0].sections.map(\.type), [.lens, .lens])
    }

    /// A tab's `type` is case-insensitive on the wire (lowercased on decode).
    func testTabTypeIsCaseInsensitive() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "WORKSPACE"
        label = "W"
        """)
        XCTAssertEqual(t[1]?[0].type, .workspace)
    }

    // MARK: - tab type validation (workspace | lens only)

    func testTabMissingTypeIsDropped() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        label = "NoType"
        [[desktop.1.tab.section]]
        label = "child"
        """)
        XCTAssertTrue(t.isEmpty)
    }

    func testTabUnknownTypeIsDropped() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspce"
        [[desktop.1.tab.section]]
        label = "child"
        """)
        XCTAssertTrue(t.isEmpty)
    }

    /// `unassigned` is NOT a valid tab type (it is a per-section marker, not a
    /// tab grouping) — a tab declaring it is dropped whole.
    func testTabTypeUnassignedIsDropped() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "unassigned"
        label = "Bad"
        [[desktop.1.tab.section]]
        label = "child"
        """)
        XCTAssertTrue(t.isEmpty)
    }

    /// A valid tab survives even with zero child sections (a grouping the user
    /// may fill later) — keep it, don't silently drop.
    func testEmptyTabKept() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspace"
        label = "Empty"
        """)
        XCTAssertEqual(t[1]?.count, 1)
        XCTAssertTrue(t[1]?[0].sections.isEmpty ?? false)
    }

    // MARK: - `unassigned = true` per-tab marker

    /// A child with `unassigned = true` inherits the parent tab's type AND
    /// carries the marker (W2.6 — the receptacle is a flag, not a type).
    func testUnassignedMarkerChildInheritsTypeWithMarker() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        [[desktop.1.tab.section]]
        label = "Web"
        match = 'tag~=web'
        [[desktop.1.tab.section]]
        unassigned = true
        label = "Other"
        """)
        XCTAssertEqual(t[1]?[0].sections.map(\.type), [.lens, .lens])
        XCTAssertEqual(t[1]?[0].sections.map(\.unassigned), [false, true])
        XCTAssertEqual(t[1]?[0].sections.last,
                       DesktopSection(type: .lens, label: "Other", unassigned: true))
    }

    /// At most one `unassigned = true` section per tab; a 2nd is dropped.
    func testSecondUnassignedMarkerDropped() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspace"
        [[desktop.1.tab.section]]
        unassigned = true
        label = "First"
        [[desktop.1.tab.section]]
        unassigned = true
        label = "Second"
        """)
        XCTAssertEqual(t[1]?[0].sections.count, 1)
        XCTAssertEqual(t[1]?[0].sections.first,
                       DesktopSection(type: .workspace, label: "First",
                                      unassigned: true))
    }

    /// An `unassigned = true` section forbids `match` / `apply` (leftover by
    /// subtraction) — authored ones are ignored, the section decodes label-only.
    func testUnassignedMarkerIgnoresMatchAndApply() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        [[desktop.1.tab.section]]
        unassigned = true
        label = "Lost"
        match = 'tag~=x'
        apply = { tags = ["x"] }
        """)
        XCTAssertEqual(t[1]?[0].sections.first,
                       DesktopSection(type: .lens, label: "Lost", unassigned: true))
    }

    // MARK: - per-type child rules inherited from `DesktopSection.parse`

    /// A lens-tab child still needs a non-empty `match` (the lens rule); a
    /// match-less child drops.
    func testLensChildNeedsMatch() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        [[desktop.1.tab.section]]
        label = "NoMatch"
        [[desktop.1.tab.section]]
        label = "Good"
        match = 'tag~=g'
        """)
        XCTAssertEqual(t[1]?[0].sections.map(\.label), ["Good"])
    }

    /// A workspace-tab child forbids `match` / `apply`; authored ones are
    /// ignored and it decodes as a bare workspace section.
    func testWorkspaceChildForbidsMatchAndApply() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspace"
        [[desktop.1.tab.section]]
        label = "W"
        match = 'tag~=x'
        apply = { tags = ["x"] }
        """)
        XCTAssertEqual(t[1]?[0].sections.first,
                       DesktopSection(type: .workspace, label: "W"))
    }

    /// A lens-tab child's `apply` keeps tags only (t-qtpx) — single-valued ops
    /// are dropped at the inheritance seam, exactly as a flat lens section.
    func testLensChildApplyKeepsTagsDropsSingleValued() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        [[desktop.1.tab.section]]
        label = "Full"
        match = 'tag~=x'
        apply = { tags = ["a", "b"], floating = true, workspace = "Dev" }
        """)
        XCTAssertEqual(t[1]?[0].sections.first?.apply, [.addTag("a"), .addTag("b")])
    }

    // MARK: - ordinals / coexistence with the flat decoder

    func testMultipleDesktopsKeyedByOrdinal() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspace"
        label = "One"
        [[desktop.3.tab]]
        type = "lens"
        label = "Three"
        """)
        XCTAssertEqual(Set(t.keys), [1, 3])
        XCTAssertEqual(t[1]?[0].label, "One")
        XCTAssertEqual(t[3]?[0].label, "Three")
    }

    /// Ordinal spellings fold (`desktop.01` → 1); `0`, missing, and dotted
    /// ordinals are skipped — matching the flat decoder's leniency.
    func testOrdinalSpellingsFoldAndMalformedSkipped() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.01.tab]]
        type = "workspace"
        label = "ZeroPad"
        [[desktop.0.tab]]
        type = "workspace"
        label = "Zero"
        [[desktop.tab]]
        type = "workspace"
        label = "NoOrdinal"
        [[desktop.2.tab]]
        type = "lens"
        label = "Good"
        """)
        XCTAssertEqual(Set(t.keys), [1, 2])
        XCTAssertEqual(t[1]?[0].label, "ZeroPad")
        XCTAssertEqual(t[2]?[0].label, "Good")
    }

    func testNoTabsReturnsEmpty() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "Flat"
        match = 'tag~=f'
        """)
        XCTAssertTrue(t.isEmpty)
    }

    /// The flat `[[desktop.N.section]]` decoder and the nested
    /// `[[desktop.N.tab]]` decoder read DISJOINT header shapes from the same
    /// text — neither pollutes the other.
    func testFlatAndNestedTabsCoexistIndependently() {
        let text = """
        [[desktop.1.section]]
        type = "lens"
        label = "Flat"
        match = 'tag~=f'
        [[desktop.2.tab]]
        type = "workspace"
        label = "Nested"
        [[desktop.2.tab.section]]
        label = "n1"
        """
        let tabs = FacetConfig.decodeDesktopTabs(fromTOML: text)
        XCTAssertEqual(Set(tabs.keys), [2])
        XCTAssertEqual(tabs[2]?[0].sections.map(\.label), ["n1"])

        let flat = FacetConfig.decodeDesktopSectionSections(fromTOML: text)
        XCTAssertEqual(Set(flat.keys), [1])
        XCTAssertEqual(flat[1]?[0].label, "Flat")
    }

    // MARK: - label uniqueness (mirrors the §A flat rule)

    /// Within one mac desktop a NON-EMPTY tab label must be unique (it is the
    /// `facet board --focus "label"` handle) — a duplicate is dropped, first-wins.
    func testTabLabelUniquenessFirstWins() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspace"
        label = "Dup"
        [[desktop.1.tab]]
        type = "lens"
        label = "Dup"
        """)
        XCTAssertEqual(t[1]?.count, 1)
        XCTAssertEqual(t[1]?[0].type, .workspace)   // first-wins
    }

    /// EMPTY tab labels are exempt from uniqueness — they may repeat freely.
    func testEmptyTabLabelsMayRepeat() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspace"
        [[desktop.1.tab]]
        type = "lens"
        """)
        XCTAssertEqual(t[1]?.count, 2)
    }

    /// The same tab label on two desktops is fine — uniqueness is PER desktop.
    func testSameTabLabelOnDifferentDesktopsAllowed() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "workspace"
        label = "Main"
        [[desktop.2.tab]]
        type = "workspace"
        label = "Main"
        """)
        XCTAssertEqual(t[1]?[0].label, "Main")
        XCTAssertEqual(t[2]?[0].label, "Main")
    }

    /// Within ONE tab a non-empty section label must be unique — first-wins.
    func testSectionLabelUniquenessWithinTabFirstWins() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        [[desktop.1.tab.section]]
        label = "Web"
        match = 'tag~=first'
        [[desktop.1.tab.section]]
        label = "Web"
        match = 'tag~=second'
        """)
        XCTAssertEqual(t[1]?[0].sections.count, 1)
        XCTAssertEqual(t[1]?[0].sections.first?.match, "tag~=first")
    }

    /// Section-label uniqueness is PER tab — the same label in two tabs is fine.
    func testSameSectionLabelInDifferentTabsAllowed() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        label = "A"
        [[desktop.1.tab.section]]
        label = "Web"
        match = 'tag~=a'
        [[desktop.1.tab]]
        type = "lens"
        label = "B"
        [[desktop.1.tab.section]]
        label = "Web"
        match = 'tag~=b'
        """)
        XCTAssertEqual(t[1]?[0].sections.map(\.label), ["Web"])
        XCTAssertEqual(t[1]?[1].sections.map(\.label), ["Web"])
    }

    /// Empty section labels may repeat within a tab.
    func testEmptySectionLabelsMayRepeatWithinTab() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        [[desktop.1.tab.section]]
        match = 'tag~=a'
        [[desktop.1.tab.section]]
        match = 'tag~=b'
        """)
        XCTAssertEqual(t[1]?[0].sections.count, 2)
    }

    // MARK: - parseTOMLNestedTabs (syntax-level grouping)

    func testNestedReaderGroupsChildrenUnderTheirTab() {
        let g = parseTOMLNestedTabs("""
        [[desktop.1.tab]]
        type = "workspace"
        label = "A"
        [[desktop.1.tab.section]]
        label = "s1"
        [[desktop.1.tab.section]]
        label = "s2"
        """)
        XCTAssertEqual(g[1]?.count, 1)
        XCTAssertEqual(g[1]?[0].tab["type"]?.asString, "workspace")
        XCTAssertEqual(g[1]?[0].tab["label"]?.asString, "A")
        XCTAssertEqual(g[1]?[0].sections.count, 2)
        XCTAssertEqual(g[1]?[0].sections.first?["label"]?.asString, "s1")
    }

    /// A `.tab.section` attaches to the MOST RECENT `.tab` of the same ordinal
    /// (document order), so a 2nd tab's children don't leak into the 1st.
    func testNestedReaderAttachesToMostRecentTabOfSameOrdinal() {
        let g = parseTOMLNestedTabs("""
        [[desktop.1.tab]]
        type = "workspace"
        label = "A"
        [[desktop.1.tab.section]]
        label = "a1"
        [[desktop.1.tab]]
        type = "workspace"
        label = "B"
        [[desktop.1.tab.section]]
        label = "b1"
        """)
        XCTAssertEqual(g[1]?.count, 2)
        XCTAssertEqual(g[1]?[0].sections.first?["label"]?.asString, "a1")
        XCTAssertEqual(g[1]?[1].sections.first?["label"]?.asString, "b1")
    }

    /// A `.tab.section` with no preceding `.tab` for its ordinal has nowhere to
    /// attach — it is dropped (not promoted to a phantom tab).
    func testNestedReaderOrphanSectionWithoutTabDropped() {
        let g = parseTOMLNestedTabs("""
        [[desktop.1.tab.section]]
        label = "orphan"
        [[desktop.1.tab]]
        type = "workspace"
        [[desktop.1.tab.section]]
        label = "real"
        """)
        XCTAssertEqual(g[1]?.count, 1)
        XCTAssertEqual(g[1]?[0].sections.map { $0["label"]?.asString }, ["real"])
    }

    /// The nested reader ignores flat `[[desktop.N.section]]` blocks (handled
    /// by the legacy decoder).
    func testNestedReaderIgnoresFlatSections() {
        let g = parseTOMLNestedTabs("""
        [[desktop.1.section]]
        type = "lens"
        match = 'tag~=x'
        """)
        XCTAssertTrue(g.isEmpty)
    }

    /// `Toml.Annotated` parsing is STRICT (throws on a malformed line); the
    /// nested reader is line-drop-lenient by degrading the WHOLE read to
    /// "no tabs" so the rest of config load (which uses the lenient flat
    /// parser) is never broken.
    func testNestedReaderLenientDegradesToEmptyOnMalformed() {
        let g = parseTOMLNestedTabs("""
        [[desktop.1.tab]]
        type = "workspace"
        broken line no equals
        """)
        XCTAssertTrue(g.isEmpty)
    }

    // MARK: - effective accessor + load() wiring

    func testEffectiveTabConfigsPassThrough() {
        var c = FacetConfig()
        c.macDesktopTabConfigs =
            [1: [DesktopTab(type: .workspace, label: "W")]]
        XCTAssertEqual(c.effectiveMacDesktopTabConfigs[1]?[0].label, "W")
    }

    private func loadConfig(_ toml: String) -> FacetConfig {
        let path = NSTemporaryDirectory()
            + "facet-test-\(UUID().uuidString)/config.toml"
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try? toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return FacetConfig.load(path: path)
    }

    func testLoadPopulatesTabConfigs() {
        let c = loadConfig("""
        [[desktop.1.tab]]
        type = "lens"
        label = "Views"
        [[desktop.1.tab.section]]
        label = "Web"
        match = 'tag~=web'
        apply = { tags = ["web"] }
        """)
        XCTAssertEqual(c.macDesktopTabConfigs[1]?[0].label, "Views")
        XCTAssertEqual(c.effectiveMacDesktopTabConfigs[1]?[0].sections.first?.apply,
                       [.addTag("web")])
    }
}
