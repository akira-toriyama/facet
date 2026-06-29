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
        unassigned = true
        label = "Other"
        """)
        XCTAssertEqual(s[1]?.count, 3)
        XCTAssertEqual(s[1]?[0],
            DesktopSection(type: .workspace, layout: "bsp"))
        XCTAssertEqual(s[1]?[1],
            DesktopSection(type: .lens, label: "Web", match: "tag~=web"))
        // W2.6: the receptacle is the `unassigned = true` MARKER (type defaults
        // workspace when none is authored on a flat row — projection-irrelevant).
        XCTAssertEqual(s[1]?[2],
            DesktopSection(type: .workspace, label: "Other", unassigned: true))
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
        XCTAssertEqual(note, "missing `type` (expected workspace / lens)")
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

    /// A workspace section is minimal: no field is required. §A — a non-empty
    /// `label` NAMES it (stored, reversing the old always-auto-named rule); the
    /// `match` is implicit (`workspace=<this>`), so an authored `match` is
    /// ignored with a caveat. Carries optional layout / apply seeds.
    func testWorkspaceSectionNamesFromLabelIgnoresMatch() {
        let (bare, n1) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("workspace"),
        ])
        XCTAssertEqual(bare, DesktopSection(type: .workspace))
        XCTAssertNil(n1)

        // label honored (§A); authored match dropped with a caveat.
        let (authored, n2) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("workspace"), "label": .string("Dev"),
            "match": .string("tag~=x"), "layout": .string("stack"),
        ])
        XCTAssertEqual(authored,
            DesktopSection(type: .workspace, label: "Dev", layout: "stack"))
        XCTAssertEqual(authored?.label, "Dev")  // label NAMED (§A reversal)
        XCTAssertEqual(authored?.match, "")     // match implicit → discarded
        XCTAssertNotNil(n2)                      // caveat logged loud (match ignored)

        // label set, no match → nothing ignored, so no caveat.
        let (named, n3) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("workspace"), "label": .string("Web"),
        ])
        XCTAssertEqual(named?.label, "Web")
        XCTAssertNil(n3)
    }

    /// t-qtpx: a workspace section FORBIDS `apply` (it is the exclusive spatial
    /// substrate, carrying no side-effect). An authored `apply` is dropped with
    /// a loud caveat; the section still decodes as a bare workspace.
    func testWorkspaceSectionForbidsApply() {
        // decode path: the apply is stripped to [].
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "workspace"
        apply = { tags = ["dev"], floating = true }
        """)
        XCTAssertEqual(s[1]?[0].apply, [])
        // parse path: the loud caveat names `apply`.
        let (section, note) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("workspace"),
            "apply": .table(["tags": .array([.string("dev")]),
                             "floating": .bool(true)]),
        ])
        XCTAssertEqual(section, DesktopSection(type: .workspace))
        XCTAssertEqual(section?.apply, [])
        XCTAssertTrue(note?.contains("apply") ?? false)
    }

    /// A workspace with BOTH an authored `match` and `apply` warns about each
    /// (joined into one note) and still decodes as a bare workspace.
    func testWorkspaceSectionForbidsMatchAndApplyBothWarn() {
        let (section, note) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("workspace"),
            "match": .string("tag~=x"),
            "apply": .table(["tags": .array([.string("x")])]),
        ])
        XCTAssertEqual(section, DesktopSection(type: .workspace))
        XCTAssertTrue(note?.contains("match") ?? false)
        XCTAssertTrue(note?.contains("apply") ?? false)
    }

    /// t-qtpx / W2.6: an `unassigned = true` receptacle FORBIDS both `match` and
    /// `apply` (it is the leftover by subtraction). Authored ones are dropped
    /// with a loud caveat; the section still decodes (label only, marker set).
    func testUnassignedSectionForbidsMatchAndApply() {
        let (section, note) = DesktopSection.parse(fromTOMLRow: [
            "unassigned": .bool(true), "label": .string("Lost"),
            "match": .string("tag~=x"),
            "apply": .table(["tags": .array([.string("x")])]),
        ])
        XCTAssertEqual(section,
            DesktopSection(type: .workspace, label: "Lost", unassigned: true))
        XCTAssertTrue(note?.contains("match") ?? false)
        XCTAssertTrue(note?.contains("apply") ?? false)
    }

    /// §A: a lens section needs a non-empty `match`; `label` is OPTIONAL
    /// (empty / missing decodes fine). Only the no-match row drops.
    func testLensSectionNeedsMatchLabelOptional() {
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
        // no-label + empty-label lenses now decode (label ""); only "NoMatch"
        // (no match) drops. Empty labels are exempt from the uniqueness rule,
        // so both survive. Decl order: nolabel, emptylabel, Good.
        XCTAssertEqual(s[1]?.map(\.label), ["", "", "Good"])
        XCTAssertEqual(s[1]?.map(\.match),
                       ["tag~=nolabel", "tag~=emptylabel", "tag~=good"])
    }

    /// A lens section may carry an optional `layout` seed. The value is parsed
    /// + stored verbatim here; a lens is a pure VIEW (t-0021), so the runtime
    /// IGNORES `layout` on a lens (parsed for total-parse robustness, not used).
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

    /// Any `layout` value is stored VERBATIM at parse time (parse stays total —
    /// it never rejects). On a lens the value is simply ignored at runtime
    /// (t-0021 pure VIEW); on a workspace it seeds the tiling engine.
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
    /// empty string leaking through to a layout consumer.
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

    /// §A / W2.6: a receptacle's `label` is optional — a label-less
    /// `unassigned = true` row decodes fine (both rows survive at the decode
    /// layer; FilterProjection enforces the ≤1-shown rule, not the decoder).
    func testUnassignedSectionLabelOptional() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        unassigned = true
        [[desktop.1.section]]
        unassigned = true
        label = "Other"
        """)
        XCTAssertEqual(s[1]?.map(\.label), ["", "Other"])
        XCTAssertEqual(s[1]?.map(\.unassigned), [true, true])
    }

    // MARK: - §A label uniqueness (non-empty unique per mac desktop)

    /// Within one mac desktop a NON-EMPTY label must be unique: a duplicate is
    /// dropped (loud + first-wins), keeping the first.
    func testDuplicateNonEmptyLabelFirstWins() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=first'
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=second'
        """)
        XCTAssertEqual(s[1]?.count, 1)            // first-wins
        XCTAssertEqual(s[1]?[0].match, "tag~=first")
    }

    /// EMPTY labels are exempt from uniqueness — they may repeat freely.
    func testEmptyLabelsMayRepeat() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        match = 'tag~=a'
        [[desktop.1.section]]
        type = "lens"
        match = 'tag~=b'
        [[desktop.1.section]]
        unassigned = true
        """)
        XCTAssertEqual(s[1]?.count, 3)
        XCTAssertEqual(s[1]?.map(\.label), ["", "", ""])
    }

    /// Uniqueness is PER mac desktop — the same label on two desktops is fine.
    func testSameLabelOnDifferentDesktopsAllowed() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=a'
        [[desktop.2.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=b'
        """)
        XCTAssertEqual(s[1]?[0].label, "Web")
        XCTAssertEqual(s[2]?[0].label, "Web")
    }

    /// The uniqueness pass spans header SPELLINGS that fold into one ordinal:
    /// `desktop.1` + `desktop.01` are de-duped together (first-wins by sorted
    /// header order — "01" sorts before "1", so it wins).
    func testDuplicateLabelDedupedAcrossOrdinalSpellings() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=plain'
        [[desktop.01.section]]
        type = "lens"
        label = "Web"
        match = 'tag~=zeropad'
        """)
        XCTAssertEqual(s[1]?.count, 1)
        XCTAssertEqual(s[1]?[0].match, "tag~=zeropad")
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

    // MARK: - apply inline table (lens sections — t-qtpx: tags-only)

    /// t-qtpx: a lens `apply` may ONLY add tags. The single-valued facets
    /// (workspace / floating / sticky / master) are warned + dropped; only the
    /// `addTag`s survive, in array order. (The full-op canonical order is still
    /// exercised by `RuleDecodeTests` — `[[rule]]` keeps every op.)
    func testLensApplyKeepsTagsDropsSingleValuedOps() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "Full"
        match = 'tag~=x'
        apply = { master = true, floating = false, tags = ["a", "b"], sticky = true, workspace = "Dev" }
        """)
        XCTAssertEqual(s[1]?[0].apply, [.addTag("a"), .addTag("b")])
        // parse() surfaces the loud caveat naming each dropped op.
        let (_, note) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("lens"), "label": .string("Full"),
            "match": .string("tag~=x"),
            "apply": .table(["workspace": .string("Dev"),
                             "tags": .array([.string("a")]),
                             "floating": .bool(true)]),
        ])
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("workspace") ?? false)
        XCTAssertTrue(note?.contains("floating") ?? false)
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

    func testLensApplyIgnoresUnknownKeysAndDropsNonTagOps() {
        let s = FacetConfig.decodeDesktopSectionSections(fromTOML: """
        [[desktop.1.section]]
        type = "lens"
        label = "U"
        match = 'tag~=u'
        apply = { bogus = "x", workspace = "", floating = true }
        """)
        // unknown key ignored, empty workspace dropped by ApplyOp.list, and
        // `floating` (single-valued) dropped by the lens tags-only rule → [].
        XCTAssertEqual(s[1]?[0].apply, [])
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
