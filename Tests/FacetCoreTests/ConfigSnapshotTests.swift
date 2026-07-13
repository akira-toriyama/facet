import Testing
import Foundation
@testable import FacetCore
import Toml

/// B4 (t-hdxb): the pure `ConfigSnapshot.render` — surgical session-override →
/// config.toml back-mapping. The riskiest piece: `declOrder` (projection index)
/// vs `rawOrdinal` (raw array-of-tables position) diverge under header-spelling
/// merge and duplicate-label drop, so these fixtures pin that the RIGHT
/// `[[desktop.N.section]]` element is edited every time. Since the section-lens
/// type was retired (t-ec9s), EVERY section is a workspace SPATIAL cell — the
/// snapshot writes workspace `label`/`layout` (by wsSlot); it never writes a
/// section `match` (there are no matched section). A lens DESKTOP's retargeted
/// match (`[desktop.N] match=`, a single std table — not a section) is written
/// via `isolateMatch` (t-sgqk).
struct ConfigSnapshotTests {

    /// Re-parse a rendered snapshot back into origins for value assertions.
    private func origins(_ text: String, ordinal: Int) -> [DesktopSectionOrigin] {
        FacetConfig.decodeDesktopSectionOrigins(fromTOML: text)[ordinal] ?? []
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

    // MARK: - declOrder ≠ rawOrdinal: duplicate-label drop

    @Test func duplicateLabelDropShiftsRawOrdinal() {
        // Survivors: Web(declOrder 0, rawOrdinal 0), Code(declOrder 1,
        // rawOrdinal 2) — the 2nd block (dup "Web") is dropped from the
        // projection but still occupies raw ordinal 1. Editing Code's layout by
        // its wsSlot (1) must land on rawOrdinal 2, NOT the dropped middle.
        let cfg = """
        [[desktop.1.section]]
        label = "Web"
        layout = "a"

        [[desktop.1.section]]
        label = "Web"
        layout = "b"

        [[desktop.1.section]]
        label = "Code"
        layout = "c"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLayout = [1: [1: "xcode"]]  // wsSlot 1 = Code (survivor)
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        // The THIRD block (Code) must be edited, NOT the second (dup Web).
        #expect(out.contains(#"layout = "xcode""#))
        #expect(out.contains(#"layout = "b""#),
                "the dropped dup-Web block is untouched")
        #expect(!(out.contains(#"layout = "c""#)), "Code's old layout replaced")
        assertStable(out)
    }

    // MARK: - header-spelling variant (desktop.01)

    @Test func zeroPaddedHeaderSpellingResolves() {
        let cfg = """
        [[desktop.01.section]]
        label = "Web"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "Browsers"]]  // Int("01") == ordinal 1
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        #expect(out.contains(#"label = "Browsers""#),
                "the desktop.01 spelling is addressed by its own path")
        #expect(!(out.contains(#"label = "Web""#)))
        assertStable(out)
    }

    // MARK: - workspace label override

    @Test func workspaceLabelOverride() {
        let cfg = """
        [[desktop.1.section]]
        label = "Web"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "Browsers"]]        // wsSlot 0 = the Web cell
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        #expect(out.contains(#"label = "Browsers""#))
        #expect(!(out.contains(#"label = "Web""#)))
        assertStable(out)
    }

    /// 🪦 THE AUTO-PROMOTE ZOMBIE, pinned dead. The writer used to bake an
    /// `unassigned` receptacle's rename back into the snapshot — and with
    /// `[config] auto-promote`, the NEXT launch overwrites config.toml with that
    /// snapshot. So a retired key could have resurrected itself from a file the
    /// user never edited. The receptacle's write path is gone with the concept
    /// (t-6rbc): the snapshot must never emit an `unassigned` key, no matter
    /// what the source config still says.
    @Test func aRetiredUnassignedRowIsNeverWrittenBackOut() {
        let cfg = """
        [[desktop.1.section]]
        label = "Web"

        [[desktop.1.section]]
        unassigned = true
        label = "Lost"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "Browsers"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)
        // The surgical writer leaves untouched bytes alone, so the user's stale
        // row is still THERE verbatim (we do not silently rewrite their file) —
        // but facet added nothing to it, and re-decoding the snapshot yields
        // exactly one section, as it must.
        #expect(out.contains(#"label = "Browsers""#))
        #expect(origins(out, ordinal: 1).count == 1,
                "the retired row must not decode back into a section")
        assertStable(out)
    }

    // MARK: - workspace label + layout: positional wsSlot mapping

    @Test func workspaceLabelAndLayoutPositional() {
        // Every section is a workspace SPATIAL cell now (t-ec9s): the k-th cell
        // ↔ wsSlot k, in declaration order. Slots map positionally.
        let cfg = """
        [[desktop.1.section]]
        label = "One"

        [[desktop.1.section]]
        label = "Two"

        [[desktop.1.section]]
        layout = "bsp"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "First", 1: "Second", 2: "Third"]]
        ov.workspaceLayout = [1: [0: "stack", 1: "float", 2: "grid"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        let secs = origins(out, ordinal: 1).map(\.section)
        #expect(secs[0].label == "First")
        #expect(secs[0].layout == "stack")
        #expect(secs[1].label == "Second")
        #expect(secs[1].layout == "float")
        #expect(secs[2].label == "Third")
        #expect(secs[2].layout == "grid")
        assertStable(out)
    }

    /// ⬅ The `rawOrdinal` invariant, which the retirement leans on hard. A stale
    /// `unassigned` row sitting BETWEEN two workspaces is DROPPED at decode
    /// (t-6rbc) — so the surviving second workspace is `wsSlot 1`, and its DOM
    /// edit must still land on the THIRD array-of-tables element, not the second.
    /// `rawOrdinal` is the RAW enumeration index, so dropping a row shifts
    /// nothing; if it were ever re-derived from the surviving list, this test
    /// would catch the snapshot writing "B"'s new name onto the dead row.
    @Test func aDroppedRowShiftsNeitherTheSlotNorTheDOMTarget() {
        let cfg = """
        [[desktop.1.section]]
        label = "A"

        [[desktop.1.section]]
        unassigned = true
        label = "Lost"

        [[desktop.1.section]]
        label = "B"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "First", 1: "Second"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        // The retired middle row does not decode, so the surviving pair is
        // [First, Second] — and "Second" must have been written to the THIRD
        // element of the array-of-tables, not the second (the dead row's slot).
        let secs = origins(out, ordinal: 1).map(\.section)
        #expect(secs.count == 2)
        #expect(secs[0].label == "First")
        #expect(secs[1].label == "Second",
                "the dropped row must not steal the second workspace's DOM slot")
        #expect(out.contains(#"label = "Lost""#),
                "the user's stale row is left verbatim — facet never rewrites it")
        assertStable(out)
    }

    @Test func workspaceEmptyNameIsNotWritten() {
        let cfg = """
        [[desktop.1.section]]
        layout = "bsp"
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

    // MARK: - [desktop.N] lens-desktop match (t-sgqk)

    @Test func isolateMatchWritesOntoItsTable() {
        // The live-retargeted match lands on the single [desktop.N] table;
        // only the match VALUE token changes — every other byte (comments,
        // the section blocks, quoting of other keys) survives verbatim.
        let cfg = """
        [[desktop.1.section]]
        label = "Main"

        [desktop.2]
        type = "isolate"
        label = "Web"
        match = 'app=Safari or app~=Chrome'
        layout = "bsp"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.isolateMatch = [2: "tag~=web"]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        #expect(out == cfg.replacingOccurrences(
            of: "match = 'app=Safari or app~=Chrome'",
            with: #"match = "tag~=web""#),
            "only the match value token changes")
        assertStable(out)
    }

    @Test func isolateMatchEmptyIsNothingToBake() {
        // An empty predicate means "reverted to the config match" — the config
        // text already spells it, so the render is byte-identical. (The
        // Controller removes the key on revert; the empty-string spelling is
        // the defensive twin.) It also counts as nothing-to-bake for isEmpty.
        let cfg = """
        [desktop.2]
        type = "isolate"
        match = 'app=Safari'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.isolateMatch = [2: ""]
        #expect(ConfigSnapshot.render(configText: cfg, overrides: ov) == cfg)
        #expect(ov.isEmpty, "an empty predicate alone is nothing to bake")
    }

    @Test func isolateMatchSkipsNonIsolateOrdinals() {
        // Ordinal 1 is a workspace desktop (sections-only) and ordinal 3 has
        // no [desktop.N] table at all — a stale session override (the config
        // was re-typed / re-shaped between edits) must neither edit a
        // workspace desktop nor conjure a [desktop.3] table out of thin air.
        let cfg = """
        [[desktop.1.section]]
        label = "Main"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.isolateMatch = [1: "tag~=x", 3: "tag~=y"]
        #expect(ConfigSnapshot.render(configText: cfg, overrides: ov) == cfg)
    }

    @Test func isolateMatchResolvesZeroPaddedSpelling() {
        // `[desktop.02]` decodes to ordinal 2 but its DOM path is
        // ["desktop","02"] — the write must target the LITERAL spelling, or
        // settingValue's create-if-missing would append a junk `[desktop.2]`
        // table (which would then last-wins-shadow the real meta on the next
        // load). Mirrors `zeroPaddedHeaderSpellingResolves` for sections.
        let cfg = """
        [desktop.02]
        type = "isolate"
        match = 'app=Safari'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.isolateMatch = [2: "tag~=web"]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)
        #expect(out == cfg.replacingOccurrences(
            of: "match = 'app=Safari'", with: #"match = "tag~=web""#),
            "the zero-padded table is edited in place — no new table")
        assertStable(out)
    }

    @Test func isolateMatchAmbiguousSpellingsSkip() {
        // TWO header spellings decoding to the same ordinal (hand-broken
        // config): which table "wins" is last-wins nondeterministic at decode,
        // so the write is ambiguous — skip, byte-identical (the same verdict
        // the section loop's pathSafe guard reaches).
        let cfg = """
        [desktop.2]
        type = "isolate"
        match = 'app=Safari'

        [desktop.02]
        type = "isolate"
        match = 'app=Mail'
        """
        var ov = ConfigSnapshot.Overrides()
        ov.isolateMatch = [2: "tag~=web"]
        #expect(ConfigSnapshot.render(configText: cfg, overrides: ov) == cfg)
    }

    @Test func isolateDesktopWithoutMatchIsDroppedSoSkipped() {
        // A [desktop.N] lens table WITHOUT a match is dropped by the decode
        // (match is REQUIRED on an isolate desktop), so `desktopIsolate` is nil and
        // the renderer must not append a match key onto a dropped desktop.
        let cfg = """
        [desktop.2]
        type = "isolate"
        layout = "bsp"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.isolateMatch = [2: "tag~=web"]
        #expect(ConfigSnapshot.render(configText: cfg, overrides: ov) == cfg)
    }

    // MARK: - multi-desktop + everything-else byte identity

    @Test func multipleDesktopsEachApplied() {
        let cfg = """
        [[desktop.1.section]]
        label = "Web"

        [[desktop.2.section]]
        label = "Chat"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLabel = [1: [0: "Browsers"], 2: [0: "Slack"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        #expect(out.contains(#"label = "Browsers""#))
        #expect(out.contains(#"label = "Slack""#))
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
        label = "Web"
        layout = "a"

        [[desktop."1".section]]
        label = "Ghost"
        layout = "z"
        """
        var ov = ConfigSnapshot.Overrides()
        ov.workspaceLayout = [1: [0: "safari"]]
        let out = ConfigSnapshot.render(configText: cfg, overrides: ov)

        // Neither block is mis-edited: the canonical Web layout is untouched and
        // the unmanaged quoted block keeps its value.
        #expect(out.contains(#"layout = "a""#), "canonical Web block untouched (skipped)")
        #expect(out.contains(#"layout = "z""#), "unmanaged quoted block untouched")
        #expect(!(out.contains("safari")), "no edit applied under ambiguity")
        assertStable(out)
    }

    // MARK: - no-op / fail-soft

    @Test func emptyOverridesReturnsInputUnchanged() {
        let cfg = """
        [[desktop.1.section]]
        label = "Web"
        """
        #expect(ConfigSnapshot.Overrides().isEmpty)
        // Even a non-empty-but-irrelevant override leaves an unrelated section be.
        let out = ConfigSnapshot.render(configText: cfg,
                                        overrides: ConfigSnapshot.Overrides())
        #expect(out == cfg)
    }

    /// `isEmpty` uses `allSatisfy { $0.value.isEmpty }`, so an ordinal key that
    /// maps to an EMPTY inner dict is still "empty" — nothing to bake. Regressing
    /// to a bare outer `.isEmpty` would flip these and cause spurious disk writes.
    /// (The existing no-op test only exercises the all-defaults case.)
    @Test func isEmptyIgnoresEmptyInnerDicts() {
        #expect(ConfigSnapshot.Overrides(workspaceLabel: [1: [:]]).isEmpty,
                "outer key present but inner dict empty → still empty")
        #expect(!ConfigSnapshot.Overrides(workspaceLabel: [1: [0: "a"]]).isEmpty,
                "a non-empty inner dict makes it non-empty")
        #expect(ConfigSnapshot.Overrides(workspaceLayout: [1: [:]]).isEmpty,
                "same for workspaceLayout's empty inner dict")
    }

    @Test func unparseableConfigReturnedUnchanged() {
        let cfg = "this is = = not valid TOML ]["
        let out = ConfigSnapshot.render(configText: cfg,
                                        overrides: ConfigSnapshot.Overrides(
                                            definedTags: ["web"]))
        #expect(out == cfg, "fail-soft: emit an unedited copy")
    }
}
