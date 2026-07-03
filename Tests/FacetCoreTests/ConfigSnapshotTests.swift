import Testing
import Foundation
@testable import FacetCore
import Toml

/// B4 (t-hdxb): the pure `ConfigSnapshot.render` — surgical session-override →
/// config.toml back-mapping. The riskiest piece: `declOrder` (projection index)
/// vs `rawOrdinal` (raw array-of-tables position) diverge under malformed-row
/// drop, header-spelling merge, and duplicate-label drop, so these fixtures pin
/// that the RIGHT `[[desktop.N.section]]` element is edited every time.
struct ConfigSnapshotTests {

    /// Re-parse a rendered snapshot back into origins for value assertions.
    private func origins(_ text: String, ordinal: Int) -> [DesktopSectionOrigin] {
        FacetConfig.decodeDesktopSectionOrigins(fromTOML: text, log: false)[ordinal] ?? []
    }

    /// Round-trip stability: a rendered snapshot re-parses to itself (byte id).
    private func assertStable(_ text: String,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        guard let dom = try? Toml.Annotated(parsing: text) else {
            Issue.record("rendered snapshot does not parse",
                         sourceLocation: sourceLocation)
            return
        }
        #expect(dom.render() == text, "snapshot is round-trip stable",
                sourceLocation: sourceLocation)
    }

    // MARK: - lens match override

    @Test func lensMatchOverrideEditsCorrectBlock() {
        let cfg = """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'app=Safari'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Firefox"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        #expect(out.contains(#"match = "app=Firefox""#),
                "match rewritten (encode normalises to a basic string)")
        #expect(!(out.contains("app=Safari")), "old match gone")
        assertStable(out)
    }

    // MARK: - declOrder ≠ rawOrdinal: duplicate-label drop

    @Test func duplicateLabelDropShiftsRawOrdinal() {
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
        #expect(out.contains(#"match = "app=Xcode""#))
        #expect(out.contains("match = 'b'"),
                "the dropped dup-Web block is untouched")
        #expect(!(out.contains("match = 'c'")), "Code's old match replaced")
        assertStable(out)
    }

    // MARK: - declOrder ≠ rawOrdinal: malformed-row drop

    @Test func malformedRowDropShiftsRawOrdinal() {
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

        #expect(out.contains(#"match = "app=Safari""#))
        #expect(out.contains(#"note = "not a section — no type""#),
                "the malformed block is preserved untouched")
        assertStable(out)
    }

    // MARK: - header-spelling variant (desktop.01)

    @Test func zeroPaddedHeaderSpellingResolves() {
        let cfg = """
        [[desktop.01.section]]
        type = "lens"
        label = "Web"
        match = 'a'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.match = [1: ["section:0:Web": "app=Safari"]]  // Int("01") == ordinal 1
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        #expect(out.contains(#"match = "app=Safari""#),
                "the desktop.01 spelling is addressed by its own path")
        assertStable(out)
    }

    // MARK: - lens / unassigned label override

    @Test func lensAndUnassignedLabelOverride() {
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

        #expect(out.contains(#"label = "Browsers""#))
        #expect(out.contains(#"label = "Strays""#))
        #expect(!(out.contains(#"label = "Web""#)))
        #expect(!(out.contains(#"label = "Lost""#)))
        assertStable(out)
    }

    // MARK: - workspace label + layout: positional wsSlot mapping

    @Test func workspaceLabelAndLayoutPositional() {
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
        #expect(secs[0].label == "First")
        #expect(secs[0].layout == "stack")
        #expect(secs[2].label == "Second")
        #expect(secs[2].layout == "float")
        #expect(secs[1].label == "Web", "the lens is untouched by ws slots")
        assertStable(out)
    }

    @Test func workspaceEmptyNameIsNotWritten() {
        let cfg = """
        [[desktop.1.section]]
        type = "workspace"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: ""]]  // empty name → leave unnamed
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)
        #expect(!(out.contains("label =")),
                "an empty workspace name adds no label line")
        assertStable(out)
    }

    // MARK: - [tags] defined union

    @Test func tagsDefinedUnionsWithExisting() {
        let cfg = """
        [tags]
        defined = ["web", "code"]
        """
        var ov = ConfigSnapshot.Overrides()
        ov.definedTags = ["code", "chat"]  // "code" already present
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        let c = FacetConfig.load(source: out)
        #expect(c.effectiveDefinedTags == ["web", "code", "chat"],
                "existing-first union, first-wins dedup")
        assertStable(out)
    }

    @Test func tagsTableCreatedWhenAbsent() {
        let cfg = """
        [theme]
        name = "terminal"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.definedTags = ["web"]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        #expect(out.contains("[tags]"), "a [tags] table is created")
        #expect(FacetConfig.load(source: out).effectiveDefinedTags == ["web"])
        #expect(out.contains(#"name = "terminal""#), "theme preserved")
        assertStable(out)
    }

    @Test func emptyDefinedTagsLeavesTagsUntouched() {
        let cfg = """
        [tags]
        defined = ["web"]
        """
        let out = ConfigSnapshot.render(configText: cfg,
                                        overrides: ConfigSnapshot.Overrides())
        #expect(out == cfg, "no in-use tags → [tags] byte-identical")
    }

    // MARK: - board desktop: section edits skipped, tags still write

    @Test func boardDesktopSkipsSectionEditsButWritesTags() {
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

        #expect(out.contains("match = 'a'"),
                "board desktop → the flat section match is untouched")
        #expect(!(out.contains("app=Safari")))
        #expect(FacetConfig.load(source: out).effectiveDefinedTags == ["web"],
                "the global [tags] write still applies")
        assertStable(out)
    }

    // MARK: - multi-desktop + everything-else byte identity

    @Test func multipleDesktopsEachApplied() {
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

        #expect(out.contains(#"match = "app=Safari""#))
        #expect(out.contains(#"match = "app=Slack""#))
        assertStable(out)
    }

    // MARK: - exotic header spelling: skip rather than mis-edit

    @Test func ambiguousHeaderSpellingSkipsRatherThanMisEdits() {
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
        #expect(out.contains("match = 'a'"), "canonical Web block untouched (skipped)")
        #expect(out.contains("match = 'z'"), "unmanaged quoted block untouched")
        #expect(!(out.contains("app=Safari")), "no edit applied under ambiguity")
        assertStable(out)
    }

    // MARK: - no-op / fail-soft

    @Test func emptyOverridesReturnsInputUnchanged() {
        let cfg = """
        [[desktop.1.section]]
        type = "lens"
        label = "Web"
        match = 'a'
        """
        #expect(ConfigSnapshot.Overrides().isEmpty)
        // Even a non-empty-but-irrelevant override leaves an unrelated section be.
        let out = ConfigSnapshot.render(configText: cfg,
                                        overrides: ConfigSnapshot.Overrides())
        #expect(out == cfg)
    }

    @Test func unparseableConfigReturnedUnchanged() {
        let cfg = "this is = = not valid TOML ]["
        let out = ConfigSnapshot.render(configText: cfg,
                                        overrides: ConfigSnapshot.Overrides(
                                            definedTags: ["web"]))
        #expect(out == cfg, "fail-soft: emit an unedited copy")
    }
}
