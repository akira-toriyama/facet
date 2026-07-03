import XCTest
import Foundation
@testable import FacetCore
import Toml

/// B4 (t-hdxb): the pure `ConfigSnapshot.render` — surgical session-override →
/// config.toml back-mapping. The riskiest piece: `declOrder` (projection index)
/// vs `rawOrdinal` (raw array-of-tables position) diverge under malformed-row
/// drop, header-spelling merge, and duplicate-label drop, so these fixtures pin
/// that the RIGHT `[[desktop.N.section]]` element is edited every time.
final class ConfigSnapshotTests: XCTestCase {

    /// Re-parse a rendered snapshot back into origins for value assertions.
    private func origins(_ text: String, ordinal: Int) -> [DesktopSectionOrigin] {
        FacetConfig.decodeDesktopSectionOrigins(fromTOML: text, log: false)[ordinal] ?? []
    }

    /// Round-trip stability: a rendered snapshot re-parses to itself (byte id).
    private func assertStable(_ text: String, file: StaticString = #filePath,
                              line: UInt = #line) {
        guard let dom = try? Toml.Annotated(parsing: text) else {
            return XCTFail("rendered snapshot does not parse", file: file, line: line)
        }
        XCTAssertEqual(dom.render(), text, "snapshot is round-trip stable",
                       file: file, line: line)
    }

    // MARK: - lens match override

    func testLensMatchOverrideEditsCorrectBlock() {
        let cfg = """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'app=Safari'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Firefox"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        XCTAssertTrue(out.contains(#"match = "app=Firefox""#),
                      "match rewritten (encode normalises to a basic string)")
        XCTAssertFalse(out.contains("app=Safari"), "old match gone")
        assertStable(out)
    }

    // MARK: - declOrder ≠ rawOrdinal: duplicate-label drop

    func testDuplicateLabelDropShiftsRawOrdinal() {
        // Survivors: Web(declOrder 0, rawOrdinal 0), Code(declOrder 1,
        // rawOrdinal 2) — the 2nd block (dup "Web") is dropped from the
        // projection but still occupies raw ordinal 1.
        let cfg = """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'

        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'b'

        [[desktop.1.section]]
        type = "lens"
        label = "Code"
        match = 'c'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:1:Code": "app=Xcode"]]  // declOrder 1 = Code
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        // The THIRD block (Code) must be edited, NOT the second (dup Web).
        XCTAssertTrue(out.contains(#"match = "app=Xcode""#))
        XCTAssertTrue(out.contains("match = 'b'"),
                      "the dropped dup-Web block is untouched")
        XCTAssertFalse(out.contains("match = 'c'"), "Code's old match replaced")
        assertStable(out)
    }

    // MARK: - declOrder ≠ rawOrdinal: malformed-row drop

    func testMalformedRowDropShiftsRawOrdinal() {
        // Block 0 has no `type` → dropped from projection; Web is declOrder 0
        // but raw ordinal 1.
        let cfg = """
        [[desktop.1.section]]
        note = "not a section — no type"

        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Safari"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        XCTAssertTrue(out.contains(#"match = "app=Safari""#))
        XCTAssertTrue(out.contains(#"note = "not a section — no type""#),
                      "the malformed block is preserved untouched")
        assertStable(out)
    }

    // MARK: - header-spelling variant (desktop.01)

    func testZeroPaddedHeaderSpellingResolves() {
        let cfg = """
        [[desktop.01.section]]
        type = "lens"
        label = "Web"
        match = 'a'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Safari"]]  // Int("01") == ordinal 1
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        XCTAssertTrue(out.contains(#"match = "app=Safari""#),
                      "the desktop.01 spelling is addressed by its own path")
        assertStable(out)
    }

    // MARK: - lens / unassigned label override

    func testLensAndUnassignedLabelOverride() {
        let cfg = """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'

        [[desktop.1.section]]
        unassigned = true
        type = "workspace"
        label = "Lost"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.label = [1: ["section:0:Web": "Browsers",
                        "unassigned:1": "Strays"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        XCTAssertTrue(out.contains(#"label = "Browsers""#))
        XCTAssertTrue(out.contains(#"label = "Strays""#))
        XCTAssertFalse(out.contains(#"label = "Web""#))
        XCTAssertFalse(out.contains(#"label = "Lost""#))
        assertStable(out)
    }

    // MARK: - workspace label + layout: positional wsSlot mapping

    func testWorkspaceLabelAndLayoutPositional() {
        // ws(slot 0) — lens — ws(slot 1): a lens between the two workspaces
        // must NOT consume a workspace slot.
        let cfg = """
        [[desktop.1.section]]
        type = "workspace"

        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'

        [[desktop.1.section]]
        type = "workspace"
        layout = "bsp"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "First", 1: "Second"]]
        ov.workspaceLayout = [1: [0: "stack", 1: "float"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        let secs = origins(out, ordinal: 1).map(\.section)
        // secs[0] = first workspace, secs[1] = lens, secs[2] = second workspace
        XCTAssertEqual(secs[0].label, "First")
        XCTAssertEqual(secs[0].layout, "stack")
        XCTAssertEqual(secs[2].label, "Second")
        XCTAssertEqual(secs[2].layout, "float")
        XCTAssertEqual(secs[1].label, "Web", "the lens is untouched by ws slots")
        assertStable(out)
    }

    func testWorkspaceEmptyNameIsNotWritten() {
        let cfg = """
        [[desktop.1.section]]
        type = "workspace"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: ""]]  // empty name → leave unnamed
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)
        XCTAssertFalse(out.contains("label ="),
                       "an empty workspace name adds no label line")
        assertStable(out)
    }

    // MARK: - [tags] defined union

    func testTagsDefinedUnionsWithExisting() {
        let cfg = """
        [tags]
        defined = ["web", "code"]
        """
        var ov = ConfigSnapshot.Overrides()
        ov.definedTags = ["code", "chat"]  // "code" already present
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        let c = FacetConfig.load(source: out)
        XCTAssertEqual(c.effectiveDefinedTags, ["web", "code", "chat"],
                       "existing-first union, first-wins dedup")
        assertStable(out)
    }

    func testTagsTableCreatedWhenAbsent() {
        let cfg = """
        [theme]
        name = "terminal"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.definedTags = ["web"]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        XCTAssertTrue(out.contains("[tags]"), "a [tags] table is created")
        XCTAssertEqual(FacetConfig.load(source: out).effectiveDefinedTags, ["web"])
        XCTAssertTrue(out.contains(#"name = "terminal""#), "theme preserved")
        assertStable(out)
    }

    func testEmptyDefinedTagsLeavesTagsUntouched() {
        let cfg = """
        [tags]
        defined = ["web"]
        """
        let out = ConfigSnapshot.render(configText: cfg,
                                        overrides: ConfigSnapshot.Overrides())
        XCTAssertEqual(out, cfg, "no in-use tags → [tags] byte-identical")
    }

    // MARK: - board desktop: section edits skipped, tags still write

    func testBoardDesktopSkipsSectionEditsButWritesTags() {
        let cfg = """
        [[desktop.1.tab]]
        type = "workspace"
        label = "Main"

        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Safari"]]  // must be SKIPPED (board)
        ov.definedTags = ["web"]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        XCTAssertTrue(out.contains("match = 'a'"),
                      "board desktop → the flat section match is untouched")
        XCTAssertFalse(out.contains("app=Safari"))
        XCTAssertEqual(FacetConfig.load(source: out).effectiveDefinedTags, ["web"],
                       "the global [tags] write still applies")
        assertStable(out)
    }

    // MARK: - multi-desktop + everything-else byte identity

    func testMultipleDesktopsEachApplied() {
        let cfg = """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'

        [[desktop.2.section]]
        type = "lens"
        label = "Chat"
        match = 'b'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Safari"],
                    2: ["section:0:Chat": "app=Slack"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        XCTAssertTrue(out.contains(#"match = "app=Safari""#))
        XCTAssertTrue(out.contains(#"match = "app=Slack""#))
        assertStable(out)
    }

    // MARK: - exotic header spelling: skip rather than mis-edit

    func testAmbiguousHeaderSpellingSkipsRatherThanMisEdits() {
        // A quoted-key spelling decodes to the SAME path [desktop,1,section] as
        // the canonical one but is DROPPED by facet's decode (Int("\"1\"") fails).
        // swift-toml-edit still counts it under the path, so the rawOrdinal would
        // misalign — the writer must SKIP, never edit the wrong block.
        let cfg = """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'

        [[desktop."1".section]]
        type = "lens"
        label = "Ghost"
        match = 'z'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Safari"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        // Neither block is mis-edited: the canonical Web match is untouched and
        // the unmanaged quoted block keeps its value.
        XCTAssertTrue(out.contains("match = 'a'"), "canonical Web block untouched (skipped)")
        XCTAssertTrue(out.contains("match = 'z'"), "unmanaged quoted block untouched")
        XCTAssertFalse(out.contains("app=Safari"), "no edit applied under ambiguity")
        assertStable(out)
    }

    // MARK: - no-op / fail-soft

    func testEmptyOverridesReturnsInputUnchanged() {
        let cfg = """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'
        """
        XCTAssertTrue(ConfigSnapshot.Overrides().isEmpty)
        // Even a non-empty-but-irrelevant override leaves an unrelated section be.
        let out = ConfigSnapshot.render(configText: cfg,
                                        overrides: ConfigSnapshot.Overrides())
        XCTAssertEqual(out, cfg)
    }

    func testUnparseableConfigReturnedUnchanged() {
        let cfg = "this is = = not valid TOML ]["
        let out = ConfigSnapshot.render(configText: cfg,
                                        overrides: ConfigSnapshot.Overrides(
                                            definedTags: ["web"]))
        XCTAssertEqual(out, cfg, "fail-soft: emit an unedited copy")
    }
}
