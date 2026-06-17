import XCTest
@testable import FacetCore

/// `[[desktop.N.group]]` config decode (pivot PR#5, parse-only). The wire
/// shape + the canonical `apply` op order are FROZEN here — Phase 2's
/// inversion resolver depends on them.
final class DesktopGroupConfigTests: XCTestCase {

    // MARK: - basic decode

    func testDecodesLabelMatchAndOrdinal() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "Web"
        match = 'tag~=web'
        [[desktop.1.group]]
        label = "Code"
        match = 'app=Xcode'
        """)
        XCTAssertEqual(g[1]?.count, 2)
        XCTAssertEqual(g[1]?[0], DesktopGroup(label: "Web", match: "tag~=web"))
        XCTAssertEqual(g[1]?[1], DesktopGroup(label: "Code", match: "app=Xcode"))
    }

    /// `match` is stored VERBATIM — operators, spaces, quotes all survive,
    /// because compilation is deferred to the consumer (not parse-time).
    func testMatchStoredVerbatim() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.2.group]]
        label = "Mixed"
        match = '(tag~=work or tag~=urgent) and not floating'
        """)
        XCTAssertEqual(g[2]?[0].match,
                       "(tag~=work or tag~=urgent) and not floating")
    }

    func testGroupOrderIsFileOrder() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "A"
        match = 'tag~=a'
        [[desktop.1.group]]
        label = "B"
        match = 'tag~=b'
        [[desktop.1.group]]
        label = "C"
        match = 'tag~=c'
        """)
        XCTAssertEqual(g[1]?.map(\.label), ["A", "B", "C"])
    }

    /// Independent desktops keyed by their Mission Control ordinal.
    func testMultipleDesktopsKeyedByOrdinal() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "One"
        match = 'tag~=one'
        [[desktop.3.group]]
        label = "Three"
        match = 'tag~=three'
        """)
        XCTAssertEqual(Set(g.keys), [1, 3])
        XCTAssertEqual(g[1]?[0].label, "One")
        XCTAssertEqual(g[3]?[0].label, "Three")
    }

    // MARK: - apply inline table (canonical order frozen)

    func testApplyDecodesAllOpsInCanonicalOrder() {
        // Wire order deliberately scrambled; decode must canonicalise to
        // setWorkspace → addTag(s) → setFloating → setSticky → setMaster.
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "Full"
        match = 'tag~=x'
        apply = { master = true, floating = false, tags = ["a", "b"], sticky = true, workspace = "Dev" }
        """)
        XCTAssertEqual(g[1]?[0].apply, [
            .setWorkspace("Dev"),
            .addTag("a"),
            .addTag("b"),
            .setFloating(false),
            .setSticky(true),
            .setMaster(true),
        ])
    }

    func testApplyTagsKeepArrayOrderAndNormalize() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "T"
        match = 'tag~=t'
        apply = { tags = ["my tag", "a:b", "web"] }
        """)
        // "my tag" → "my-tag" (space→-), "a:b" dropped (forbidden ':'),
        // "web" kept; array order preserved.
        XCTAssertEqual(g[1]?[0].apply, [.addTag("my-tag"), .addTag("web")])
    }

    func testEmptyOrMissingApplyIsDropInert() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "NoApply"
        match = 'tag~=n'
        [[desktop.1.group]]
        label = "EmptyApply"
        match = 'tag~=e'
        apply = { }
        """)
        XCTAssertEqual(g[1]?[0].apply, [])
        XCTAssertEqual(g[1]?[1].apply, [])
    }

    func testApplyIgnoresUnknownKeysAndEmptyWorkspace() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "U"
        match = 'tag~=u'
        apply = { bogus = "x", workspace = "", floating = true }
        """)
        // empty workspace dropped, unknown key ignored, floating survives.
        XCTAssertEqual(g[1]?[0].apply, [.setFloating(true)])
    }

    // MARK: - row dropping (mirrors blank-[[exclude]])

    func testRowMissingLabelOrMatchIsDropped() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        match = 'tag~=nolabel'
        [[desktop.1.group]]
        label = "NoMatch"
        [[desktop.1.group]]
        label = ""
        match = 'tag~=emptylabel'
        [[desktop.1.group]]
        label = "Good"
        match = 'tag~=good'
        """)
        XCTAssertEqual(g[1]?.map(\.label), ["Good"])
    }

    func testDesktopWithNoUsableRowsContributesNothing() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.5.group]]
        label = "OnlyLabel"
        """)
        XCTAssertNil(g[5])
        XCTAssertTrue(g.isEmpty)
    }

    func testNoGroupsAtAll() {
        XCTAssertTrue(FacetConfig.decodeDesktopGroupSections(
            fromTOML: "[desktop.1]\n1 = { name = \"Dev\" }\n").isEmpty)
    }

    /// A `[desktop.N]` workspace table and a `[[desktop.N.group]]` array can
    /// coexist — the flat parser keys them separately, so neither shadows
    /// the other.
    func testCoexistsWithDesktopWorkspaceTable() {
        let text = """
        [desktop.1]
        1 = { name = "Dev" }
        [[desktop.1.group]]
        label = "Web"
        match = 'tag~=web'
        """
        var c = FacetConfig.from(toml: parseTOMLSubset(text))
        c.macDesktopGroupConfigs =
            FacetConfig.decodeDesktopGroupSections(fromTOML: text)
        XCTAssertEqual(c.macDesktopWorkspaceConfigs[1]?[1]?.name, "Dev")
        XCTAssertEqual(c.macDesktopGroupConfigs[1]?[0].label, "Web")
    }

    // MARK: - effective accessor (tag-mode clamp)

    func testEffectiveGroupsEmptyInTagMode() {
        var c = FacetConfig()
        c.grouping = "tag"
        c.macDesktopGroupConfigs = [1: [DesktopGroup(label: "W", match: "tag~=w")]]
        XCTAssertTrue(c.effectiveMacDesktopGroupConfigs.isEmpty)
        // raw is retained (read-through-effective idiom).
        XCTAssertFalse(c.macDesktopGroupConfigs.isEmpty)
    }

    func testEffectiveGroupsPassThroughInWorkspaceMode() {
        var c = FacetConfig()
        c.macDesktopGroupConfigs = [1: [DesktopGroup(label: "W", match: "tag~=w")]]
        XCTAssertEqual(c.effectiveMacDesktopGroupConfigs[1]?[0].label, "W")
    }

    // MARK: - parse stays total (frozen: match is NOT compiled at load)

    /// A syntactically GARBAGE `match` must still decode verbatim, never be
    /// dropped or rejected — config-load stays total; the filter is compiled
    /// (and loud-rejected non-fatally) only by the consumer. Guards against a
    /// future "helpful" load-time validation breaking the frozen decision.
    func testMalformedMatchStoredVerbatimNotRejected() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "Garbage"
        match = '(((unbalanced and ~=~ ???'
        """)
        XCTAssertEqual(g[1]?.count, 1)
        XCTAssertEqual(g[1]?[0].match, "(((unbalanced and ~=~ ???")
    }

    // MARK: - ordinal guard (frozen: 1-based, malformed headers skipped)

    func testOutOfRangeAndMalformedOrdinalsSkipped() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.0.group]]
        label = "Zero"
        match = 'tag~=z'
        [[desktop.-1.group]]
        label = "Neg"
        match = 'tag~=n'
        [[desktop.group]]
        label = "NoOrdinal"
        match = 'tag~=x'
        [[desktop.1.2.group]]
        label = "Dotted"
        match = 'tag~=d'
        [[desktop.2.group]]
        label = "Good"
        match = 'tag~=g'
        """)
        // Only the well-formed 1-based ordinal survives.
        XCTAssertEqual(Set(g.keys), [2])
        XCTAssertEqual(g[2]?[0].label, "Good")
    }

    /// Two spellings that normalize to the same ordinal MERGE deterministically
    /// (sorted header order), never overwrite by Dictionary hash-seed order.
    func testDuplicateOrdinalSpellingsMergeDeterministically() {
        let text = """
        [[desktop.1.group]]
        label = "Plain"
        match = 'tag~=p'
        [[desktop.01.group]]
        label = "ZeroPad"
        match = 'tag~=z'
        """
        // Stable across repeated decodes (would flap if it overwrote).
        let first = FacetConfig.decodeDesktopGroupSections(fromTOML: text)
        for _ in 0..<8 {
            XCTAssertEqual(
                FacetConfig.decodeDesktopGroupSections(fromTOML: text), first)
        }
        // Both spellings land in desktop 1; sorted header order = "01" < "1".
        XCTAssertEqual(first[1]?.map(\.label), ["ZeroPad", "Plain"])
    }

    // MARK: - non-table apply (frozen: any non-usable apply → drop-inert)

    func testNonTableApplyIsDropInert() {
        let g = FacetConfig.decodeDesktopGroupSections(fromTOML: """
        [[desktop.1.group]]
        label = "StringApply"
        match = 'tag~=s'
        apply = "oops"
        [[desktop.1.group]]
        label = "IntApply"
        match = 'tag~=i'
        apply = 3
        """)
        XCTAssertEqual(g[1]?[0].apply, [])
        XCTAssertEqual(g[1]?[1].apply, [])
    }

    // MARK: - load() wiring (raw retained; tag-mode loud-log + effective clamp)

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

    func testLoadPopulatesGroupsInWorkspaceMode() {
        let c = loadConfig("""
        [[desktop.1.group]]
        label = "Web"
        match = 'tag~=web'
        apply = { tags = ["web"] }
        """)
        XCTAssertEqual(c.macDesktopGroupConfigs[1]?[0].label, "Web")
        XCTAssertEqual(c.effectiveMacDesktopGroupConfigs[1]?[0].apply,
                       [.addTag("web")])
    }

    /// Tag mode RETAINS the raw decode (groups are still parsed into the
    /// dict — proves load() doesn't drop them at parse) but the effective
    /// accessor clamps to empty. The load-time loud-log fires on this path.
    func testLoadTagModeRetainsRawButClampsEffective() {
        let c = loadConfig("""
        [grouping]
        by = "tag"
        [[tag]]
        name = "web"
        [[desktop.1.group]]
        label = "Web"
        match = 'tag~=web'
        """)
        XCTAssertFalse(c.macDesktopGroupConfigs.isEmpty,
                       "raw decode retained even in tag mode")
        XCTAssertTrue(c.effectiveMacDesktopGroupConfigs.isEmpty,
                      "tag mode clamps groups to empty")
    }
}
