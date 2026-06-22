import XCTest
@testable import FacetCore

/// `[[desktop.N.section]]` config decode (the section/lens model, parse-
/// only). The wire shape, the `type` discriminator routing, and the
/// canonical `apply` op order are FROZEN here — PR8's inversion resolver
/// depends on them. `type` is REQUIRED: an absent / unknown `type`, or a
/// per-type required field missing, DROPS the row (loud, never a silent
/// clamp). CI-only (CLT can't run `swift test`).
final class SectionDecodeTests: XCTestCase {

    // MARK: - type discriminator routing

    func testDecodesEachExplicitType() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "workspace"
        layout = "bsp"
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=web'
        [[desktop.1.section]]
        type = "unassigned"
        label = "Other"
        """)
        XCTAssertEqual(s[1]?.count, 3)
        XCTAssertEqual(s[1]?[0],
            DesktopSection(type: .workspace, layout: "bsp"))
        XCTAssertEqual(s[1]?[1],
            DesktopSection(type: .lens, label: "Web", match: "tag~=web"))
        XCTAssertEqual(s[1]?[2],
            DesktopSection(type: .unassigned, label: "Other"))
    }

    /// `type` is case-insensitive on the wire (lowercased on decode).
    func testTypeIsCaseInsensitive() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "LENS"
        label = "W"
        match = 'tag~=w'
        """)
        XCTAssertEqual(s[1]?[0].type, .lens)
    }

    /// Absent `type` → DROP (トミー 2026-06-17: warn + skip, never default-
    /// guess; this would otherwise silently mis-route the window set).
    func testAbsentTypeIsDropped() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        label = "Web"
        match = 'tag~=web'
        """)
        XCTAssertTrue(s.isEmpty)
        // The parse helper reports the loud drop reason.
        let (section, note) = DesktopSection.parse(fromTOMLRow: [
            "label": .string("Web"), "match": .string("tag~=web"),
        ])
        XCTAssertNil(section)
        XCTAssertEqual(note, "missing `type` (expected workspace / lens / unassigned)")
    }

    /// Unknown `type` → DROP (clamp-to-default would discard an authored
    /// match — the foot-gun; warn + skip instead).
    func testUnknownTypeIsDropped() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lenss"
        label = "Typo"
        match = 'tag~=t'
        """)
        XCTAssertTrue(s.isEmpty)
        let (section, note) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("lenss"), "label": .string("Typo"),
            "match": .string("tag~=t"),
        ])
        XCTAssertNil(section)
        XCTAssertTrue(note?.hasPrefix("unknown `type` \"lenss\"") ?? false)
    }

    // MARK: - per-type field rules

    /// A workspace section is auto-named: no label/match needed; carries an
    /// optional layout seed (+ optional apply seed). An authored label/match
    /// is ignored (accepted, with a caveat note) — never stored.
    func testWorkspaceSectionMinimalAndIgnoresLabelMatch() {
        let (bare, n1) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("workspace"),
        ])
        XCTAssertEqual(bare, DesktopSection(type: .workspace))
        XCTAssertNil(n1)

        let (authored, n2) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("workspace"), "label": .string("Dev"),
            "match": .string("tag~=x"), "layout": .string("stack"),
        ])
        XCTAssertEqual(authored,
            DesktopSection(type: .workspace, layout: "stack"))
        XCTAssertEqual(authored?.label, "")     // label discarded
        XCTAssertEqual(authored?.match, "")     // match discarded
        XCTAssertNotNil(n2)                      // caveat logged loud
    }

    /// A workspace section may carry an `apply` seed (canonical order).
    func testWorkspaceSectionCarriesApplySeed() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "workspace"
        apply = { tags = ["dev"], floating = true }
        """)
        XCTAssertEqual(s[1]?[0].apply, [.addTag("dev"), .setFloating(true)])
    }

    /// A lens section needs both label AND match; either missing → DROP.
    func testLensSectionNeedsLabelAndMatch() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        match = 'tag~=nolabel'
        [[desktop.1.section]]
        type = "lens"
        label = "NoMatch"
        [[desktop.1.section]]
        type = "lens"
        label = ""
        match = 'tag~=emptylabel'
        [[desktop.1.section]]
        type = "lens"
        label = "Good"
        match = 'tag~=good'
        """)
        XCTAssertEqual(s[1]?.map(\.label), ["Good"])
    }

    /// A lens section may carry an optional `layout` seed (EX-1a). The value
    /// is stored verbatim here; `LensLayout.resolve` clamps it to a stateless
    /// engine at activation time (the runtime ignores it until EX-1b).
    func testLensSectionDecodesLayout() {
        let row: [String: TOMLValue] = [
            "type": .string("lens"),
            "label": .string("Web"),
            "match": .string("app~=Chrome"),
            "layout": .string("spiral"),
        ]
        let (section, note) = DesktopSection.parse(fromTOMLRow: row)
        XCTAssertNil(note)
        XCTAssertEqual(section?.type, .lens)
        XCTAssertEqual(section?.layout, "spiral")
    }

    /// A forbidden (stateful) layout value such as "bsp" must be stored
    /// VERBATIM at parse time — the clamp to a stateless engine is deferred
    /// to `LensLayout.resolve` at activation, not at decode.
    func testLensSectionStoresForbiddenLayoutVerbatim() {
        let row: [String: TOMLValue] = [
            "type": .string("lens"),
            "label": .string("Dev"),
            "match": .string("tag~=dev"),
            "layout": .string("bsp"),
        ]
        let (section, _) = DesktopSection.parse(fromTOMLRow: row)
        XCTAssertEqual(section?.layout, "bsp")
    }

    /// An empty-string `layout` must be treated as absent (the isEmpty guard)
    /// and stored as nil, so callers see "no layout authored" rather than the
    /// empty string leaking through to `LensLayout.resolve`.
    func testLensSectionEmptyLayoutIsNil() {
        let row: [String: TOMLValue] = [
            "type": .string("lens"),
            "label": .string("Tools"),
            "match": .string("tag~=tools"),
            "layout": .string(""),
        ]
        let (section, _) = DesktopSection.parse(fromTOMLRow: row)
        XCTAssertNil(section?.layout)
    }

    /// An unassigned section needs only a label.
    func testUnassignedSectionNeedsLabel() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "unassigned"
        [[desktop.1.section]]
        type = "unassigned"
        label = "Other"
        """)
        XCTAssertEqual(s[1]?.map(\.label), ["Other"])
    }

    // MARK: - ordering / ordinals

    func testMixedTypeArrayPreservesDeclarationOrder() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "A"
        match = 'tag~=a'
        [[desktop.1.section]]
        type = "workspace"
        [[desktop.1.section]]
        type = "lens"
        label = "B"
        match = 'tag~=b'
        """)
        XCTAssertEqual(s[1]?.map(\.type), [.lens, .workspace, .lens])
        XCTAssertEqual(s[1]?.compactMap { $0.label.isEmpty ? nil : $0.label },
                       ["A", "B"])
    }

    func testMultipleDesktopsKeyedByOrdinal() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "One"
        match = 'tag~=one'
        [[desktop.3.section]]
        type = "lens"
        label = "Three"
        match = 'tag~=three'
        """)
        XCTAssertEqual(Set(s.keys), [1, 3])
        XCTAssertEqual(s[1]?[0].label, "One")
        XCTAssertEqual(s[3]?[0].label, "Three")
    }

    func testOutOfRangeAndMalformedOrdinalsSkipped() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.0.section]]
        type = "lens"
        label = "Zero"
        match = 'tag~=z'
        [[desktop.-1.section]]
        type = "lens"
        label = "Neg"
        match = 'tag~=n'
        [[desktop.section]]
        type = "lens"
        label = "NoOrdinal"
        match = 'tag~=x'
        [[desktop.1.2.section]]
        type = "lens"
        label = "Dotted"
        match = 'tag~=d'
        [[desktop.2.section]]
        type = "lens"
        label = "Good"
        match = 'tag~=g'
        """)
        XCTAssertEqual(Set(s.keys), [2])
        XCTAssertEqual(s[2]?[0].label, "Good")
    }

    /// Two spellings that normalize to the same ordinal MERGE deterministically
    /// (sorted header order), never overwrite by Dictionary hash-seed order.
    func testDuplicateOrdinalSpellingsMergeDeterministically() {
        let text = """
        [[desktop.1.section]]
        type = "lens"
        label = "Plain"
        match = 'tag~=p'
        [[desktop.01.section]]
        type = "lens"
        label = "ZeroPad"
        match = 'tag~=z'
        """
        let first = FacetConfig.decodeDesktopSectionSections(fromTOML: text)
        for _ in 0..<8 {
            XCTAssertEqual(
                FacetConfig.decodeDesktopSectionSections(fromTOML: text), first)
        }
        // Both spellings land in desktop 1; sorted header order = "01" < "1".
        XCTAssertEqual(first[1]?.map(\.label), ["ZeroPad", "Plain"])
    }

    func testNoSectionsAtAll() {
        XCTAssertTrue(FacetConfig.decodeDesktopSectionSections(
            fromTOML: "[desktop.1]\n1 = { name = \"Dev\" }\n").isEmpty)
    }

    /// A bare `[desktop.N]` table (no longer decoded — the by-name workspace
    /// seed was retired) sits in the same file as a `[[desktop.N.section]]`
    /// array; the section decode keys off the `.section` suffix only, so the
    /// bare table never shadows or pollutes it.
    func testSectionDecodeIgnoresBareDesktopTable() {
        let text = """
        [desktop.1]
        1 = { name = "Dev" }
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=web'
        """
        let sections = FacetConfig.decodeDesktopSectionSections(fromTOML: text)
        XCTAssertEqual(sections[1]?.count, 1)
        XCTAssertEqual(sections[1]?[0].label, "Web")
    }

    // MARK: - apply inline table (canonical order frozen; lens sections)

    func testApplyDecodesAllOpsInCanonicalOrder() {
        // Wire order deliberately scrambled; decode must canonicalise to
        // setWorkspace → addTag(s) → setFloating → setSticky → setMaster.
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "Full"
        match = 'tag~=x'
        apply = { master = true, floating = false, tags = ["a", "b"], sticky = true, workspace = "Dev" }
        """)
        XCTAssertEqual(s[1]?[0].apply, [
            .setWorkspace("Dev"),
            .addTag("a"),
            .addTag("b"),
            .setFloating(false),
            .setSticky(true),
            .setMaster(true),
        ])
    }

    func testApplyTagsKeepArrayOrderAndNormalize() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "T"
        match = 'tag~=t'
        apply = { tags = ["my tag", "a:b", "web"] }
        """)
        // "my tag" → "my-tag" (space→-), "a:b" dropped (forbidden ':'),
        // "web" kept; array order preserved.
        XCTAssertEqual(s[1]?[0].apply, [.addTag("my-tag"), .addTag("web")])
    }

    func testEmptyOrMissingApplyIsDropInert() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "NoApply"
        match = 'tag~=n'
        [[desktop.1.section]]
        type = "lens"
        label = "EmptyApply"
        match = 'tag~=e'
        apply = { }
        """)
        XCTAssertEqual(s[1]?[0].apply, [])
        XCTAssertEqual(s[1]?[1].apply, [])
    }

    func testApplyIgnoresUnknownKeysAndEmptyWorkspace() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "U"
        match = 'tag~=u'
        apply = { bogus = "x", workspace = "", floating = true }
        """)
        // empty workspace dropped, unknown key ignored, floating survives.
        XCTAssertEqual(s[1]?[0].apply, [.setFloating(true)])
    }

    func testNonTableApplyIsDropInert() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "StringApply"
        match = 'tag~=s'
        apply = "oops"
        [[desktop.1.section]]
        type = "lens"
        label = "IntApply"
        match = 'tag~=i'
        apply = 3
        """)
        XCTAssertEqual(s[1]?[0].apply, [])
        XCTAssertEqual(s[1]?[1].apply, [])
    }

    /// `removeTag` has NO wire key — it is never produced by `ApplyOp.list`
    /// (synthesised only by PR8's un-apply inversion).
    func testRemoveTagNeverDecoded() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "R"
        match = 'tag~=r'
        apply = { removeTag = "x", removeTags = ["y"], tags = ["keep"] }
        """)
        // Only the real `tags` key produces ops; removeTag* keys are unknown.
        XCTAssertEqual(s[1]?[0].apply, [.addTag("keep")])
    }

    // MARK: - parse stays total (frozen: match is NOT compiled at load)

    /// A syntactically GARBAGE `match` on a lens section must still decode
    /// verbatim, never be dropped or rejected — config-load stays total; the
    /// filter is compiled (and loud-rejected non-fatally) only by the
    /// consumer.
    func testMalformedMatchStoredVerbatimNotRejected() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "Garbage"
        match = '(((unbalanced and ~=~ ???'
        """)
        XCTAssertEqual(s[1]?.count, 1)
        XCTAssertEqual(s[1]?[0].match, "(((unbalanced and ~=~ ???")
    }

    // MARK: - effective accessor

    func testEffectiveSectionsPassThroughInWorkspaceMode() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs =
            [1: [DesktopSection(type: .lens, label: "W", match: "tag~=w")]]
        XCTAssertEqual(c.effectiveMacDesktopSectionConfigs[1]?[0].label, "W")
    }

    // MARK: - load() wiring (raw decode → effective pass-through)

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

    func testLoadPopulatesSectionsInWorkspaceMode() {
        let c = loadConfig("""
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=web'
        apply = { tags = ["web"] }
        """)
        XCTAssertEqual(c.macDesktopSectionConfigs[1]?[0].label, "Web")
        XCTAssertEqual(c.effectiveMacDesktopSectionConfigs[1]?[0].apply,
                       [.addTag("web")])
    }
}
