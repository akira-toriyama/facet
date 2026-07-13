import Foundation
import Testing
@testable import FacetCore

/// t-r5yz — every way config.toml can lose a block the user WROTE, and the
/// promise that each one now says so.
///
/// The bug this pins shut: `facet config --validate` printed "config valid" +
/// exit 0 over a config whose `[desktop.2]` had been thrown away whole. The
/// reason existed — but it went to `Log.line`, which only reaches stderr under
/// `FACET_DEBUG`, so the ONE tool whose job is "tell me what facet will do with
/// this file" was answering the question wrong. Three of the drops below did not
/// even log: they were pure silence.
///
/// The classification rule, and the only one:
///   • something the user WROTE was discarded whole → `.error` (`--validate`
///     exits 1)
///   • a value was clamped / a stray key ignored, block intact → `.warning`
///     (exit 0 — "a typo can never break the layout" is the daemon's contract)
///
/// The daemon is NOT changed by any of this: it logs every severity and boots.
/// Severity is data, not control flow.
struct ConfigDiagnosticsTests {

    private func errors(_ toml: String) -> [String] {
        FacetConfig.load(source: toml).diagnostics
            .filter { $0.severity == .error }.map(\.message)
    }
    private func warnings(_ toml: String) -> [String] {
        FacetConfig.load(source: toml).diagnostics
            .filter { $0.severity == .warning }.map(\.message)
    }
    private func expectError(_ toml: String, contains needle: String,
                             _ comment: Comment? = nil,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        let found = errors(toml)
        #expect(found.contains { $0.contains(needle) }, comment ?? "\(found)",
                sourceLocation: sourceLocation)
    }

    // MARK: - [desktop.N] — the drop that started the task

    /// The reported symptom: `--validate` said "valid — 0 configured desktop(s)"
    /// while the whole table was in the bin.
    @Test func isolateDesktopWithoutMatchIsAnError() {
        expectError("""
        [desktop.2]
        type = "isolate"
        label = "Web"
        """, contains: "needs a non-empty `match`")
    }

    /// A missing `type` drops the table AND silently discards the `label` with
    /// it — doubly invisible.
    @Test func desktopWithoutTypeIsAnError() {
        expectError("""
        [desktop.2]
        label = "Web"
        """, contains: "missing `type`")
    }

    @Test func unknownDesktopTypeIsAnError() {
        expectError("""
        [desktop.2]
        type = "board"
        """, contains: "unknown `type`")
    }

    /// The `lens` tombstone (t-mqqw) — a dead word, never an alias.
    @Test func lensTypeIsAnError() {
        expectError("""
        [desktop.2]
        type = "lens"
        match = 'app~=Chrome'
        """, contains: "renamed to `type = \"isolate\"`")
    }

    /// A stray isolate-only key on a WORKSPACE desktop is the other severity:
    /// the table SURVIVES, facet just ignores the key. Warning → exit 0.
    @Test func strayIsolateKeyOnAWorkspaceDesktopIsOnlyAWarning() {
        let toml = """
        [desktop.1]
        type = "workspace"
        match = 'app~=Chrome'
        """
        #expect(warnings(toml).contains { $0.contains("`match` is isolate-only") })
        #expect(errors(toml).isEmpty, "the desktop still decodes — nothing was lost")
        #expect(FacetConfig.load(source: toml).macDesktopMetaConfigs[1] != nil)
    }

    /// `[desktop.0]` / `[desktop.foo]` — addressed to facet, names no ordinal.
    /// Was a bare `continue`: the table simply never existed.
    @Test func nonOrdinalDesktopHeaderIsAnError() {
        expectError("""
        [desktop.0]
        type = "workspace"
        """, contains: "not a mac-desktop ordinal")
        expectError("""
        [desktop.foo]
        type = "workspace"
        """, contains: "not a mac-desktop ordinal")
    }

    /// 🔴 The non-deterministic one. `Int` accepts a zero-pad, so `[desktop.01]`
    /// and `[desktop.1]` are the SAME ordinal — one of the user's two tables was
    /// overwritten, and WHICH one depended on the per-process Dictionary hash
    /// seed. Now the survivor is deterministic (sorted header order) AND the
    /// collision is loud. Run it twice: the winner may not wobble.
    @Test func collidingDesktopSpellingsAreLoudAndDeterministic() {
        let toml = """
        [desktop.1]
        type = "workspace"
        label = "One"

        [desktop.01]
        type = "isolate"
        label = "Zero"
        match = 'app~=Chrome'
        """
        expectError(toml, contains: "both name mac desktop 1")
        let a = FacetConfig.load(source: toml).macDesktopMetaConfigs[1]
        let b = FacetConfig.load(source: toml).macDesktopMetaConfigs[1]
        #expect(a?.label == b?.label, "the winner must not depend on the hash seed")
        #expect(a?.label == "Zero", "sorted header order: desktop.01 < desktop.1")
    }

    /// ⬅ The bug the FIRST cut of this feature shipped, caught by adversarial
    /// review running the real binary. The collision guard claimed the ordinal
    /// BEFORE the table was known to parse, so a broken spelling that sorts first
    /// evicted a perfectly valid sibling — and then, because the new opt-in rule
    /// says "declared but nothing decoded → manage nothing", facet went
    /// completely dead on a config the user had gotten right. A dropped table
    /// claims nothing.
    @Test func aDroppedSpellingDoesNotEvictAValidSibling() {
        let toml = """
        [desktop.01]
        type = "isolate"
        label = "Bad"

        [desktop.1]
        type = "workspace"
        label = "Good"
        """
        let c = FacetConfig.load(source: toml)
        #expect(c.macDesktopMetaConfigs[1]?.label == "Good",
                "the valid table must survive its broken twin")
        #expect(c.isMacDesktopManaged(ordinal: 1))
        // The [desktop.01] drop is reported against its LITERAL header — sending
        // the user to `[desktop.1]` would point at the line that is FINE.
        #expect(errors(toml).contains { $0.contains("[desktop.01]: isolate desktop") })
        // …and no collision is claimed, because there wasn't one: only one table
        // ever held the ordinal.
        #expect(!errors(toml).contains { $0.contains("both name mac desktop") })
    }

    // MARK: - [[desktop.N.section]]

    @Test func duplicateSectionLabelIsAnError() {
        expectError("""
        [[desktop.1.section]]
        label = "Code"

        [[desktop.1.section]]
        label = "Code"
        """, contains: "duplicate label")
    }

    @Test func nonOrdinalSectionHeaderIsAnError() {
        expectError("""
        [[desktop.0.section]]
        label = "Code"
        """, contains: "not a mac-desktop ordinal")
    }

    /// An isolate desktop has no sections. The DESKTOP survives, but every
    /// section block written under it is discarded → error, not warning.
    @Test func sectionsUnderAnIsolateDesktopAreAnError() {
        expectError("""
        [desktop.2]
        type = "isolate"
        match = 'app~=Chrome'

        [[desktop.2.section]]
        label = "Code"
        """, contains: "an isolate desktop has no sections")
    }

    // MARK: - [[rule]] / [[exclude]] — the three that logged NOTHING at all

    @Test func ruleWithoutMatchIsAnError() {
        expectError("""
        [[rule]]
        tags = ["web"]
        """, contains: "missing or blank `match`")
    }

    /// Two ways to have no apply op, and both used to vanish without a trace:
    /// a typo'd key (`tag`, singular) …
    @Test func ruleWithNoApplyKeyIsAnError() {
        expectError("""
        [[rule]]
        match = 'app~=Chrome'
        tag = "web"
        """, contains: "no `apply` key")
    }

    /// … and the RIGHT key with the wrong shape. `tags` takes an array; a bare
    /// string yields no op, so the rule was dropped and the user's windows simply
    /// never got tagged. (Found by this very test file getting it wrong.)
    @Test func ruleWithAScalarTagsValueIsAnError() {
        expectError("""
        [[rule]]
        match = 'app~=Chrome'
        tags = "web"
        """, contains: "no `apply` key")
    }

    @Test func exclusionWithNoConstraintIsAnError() {
        expectError("""
        [[exclude]]
        action = "ignore"
        """, contains: "no constraint")
    }

    // MARK: - match GRAMMAR (D1) — not a drop, but worse: a DEAD desktop

    /// The block survives, so this is outside "block-drop" — and it is worse. The
    /// tree paints a caret while the park side silently does nothing, so the
    /// desktop tiles nothing and parks nothing. `--validate` never looked at the
    /// predicate's syntax at all.
    @Test func malformedIsolateMatchIsAnError() {
        expectError("""
        [desktop.2]
        type = "isolate"
        match = 'app~'
        """, contains: "the predicate does not parse")
    }

    @Test func malformedRuleMatchIsAnError() {
        expectError("""
        [[rule]]
        match = 'tag~'
        tags = ["web"]
        """, contains: "the predicate does not parse")
    }

    /// An unknown FIELD is soft — the predicate parses and commits, it just
    /// selects nothing. Same verdict `classifyMatchPredicate` gives the live
    /// editor, so `--validate` and the GUI can never disagree.
    @Test func unknownMatchFieldIsOnlyAWarning() {
        let toml = """
        [desktop.2]
        type = "isolate"
        match = 'bogus=1'
        """
        #expect(warnings(toml).contains { $0.contains("unknown field") })
        #expect(errors(toml).isEmpty)
    }

    // MARK: - TOML syntax — the loudest hole of all

    /// The lenient parser DROPS each line it can't read and carries on, and the
    /// strict validate's `try?` swallowed the throw — so facet booted on a
    /// half-read config, saying absolutely nothing. (`--validate` exits 2 here
    /// via its own `validate` call; this pins that the DAEMON at least knows.)
    @Test func unparseableTOMLIsAnError() {
        expectError("""
        [theme]
        name = "terminal
        """, contains: "not parseable as TOML")
    }

    /// ⬅ Also from the review. The grammar check used to number `[[rule]] #N` over
    /// the SURVIVORS while the drop diagnostics numbered by FILE position — so one
    /// dropped rule made every later rule's match error point at the wrong table.
    /// In the one tool whose job is "which block of my file is broken", naming the
    /// wrong block is worse than saying nothing.
    @Test func ruleDiagnosticsAreNumberedByFilePositionNotBySurvivors() {
        let found = errors("""
        [[rule]]
        match = 'app~=Chrome'
        tag = "web"

        [[rule]]
        match = 'app~'
        tags = ["x"]
        """)
        #expect(found.contains { $0.contains("[[rule]] #1") && $0.contains("no `apply` key") })
        #expect(found.contains { $0.contains("[[rule]] #2 match") },
                "the malformed predicate is the file's SECOND rule: \(found)")
        #expect(!found.contains { $0.contains("[[rule]] #1 match") })
    }

    /// A tag name that fails `TagName` policy yields no op. The rule SURVIVED one
    /// tag short and nothing said so.
    @Test func aRejectedTagNameIsReported() {
        let found = errors("""
        [[rule]]
        match = 'app=Safari'
        tags = ["ok", "bad:tag"]
        """)
        #expect(found.contains { $0.contains("\"bad:tag\" is not a valid tag name") })
        // The rule itself lives — one good tag is still worth applying.
        let c = FacetConfig.load(source: """
        [[rule]]
        match = 'app=Safari'
        tags = ["ok", "bad:tag"]
        """)
        #expect(c.effectiveRules.count == 1)
        #expect(c.effectiveRules.first?.apply == [.addTag("ok")])
    }

    // MARK: - clamps that were invisible

    /// `layout = "bps"` (typo for `bsp`) is a CLAMP — the section survives, so it
    /// stays a warning and exit 0. But it was reported by NEITHER channel: the
    /// schema has no enum domain for `layout` (the registry is dynamic) and the
    /// tile path just falls through. The cell silently never tiled. A clamp the
    /// user cannot SEE is not a clamp, it is a disappearance.
    @Test func anUnknownLayoutNameIsAWarning() {
        let toml = """
        [[desktop.1.section]]
        label = "Code"
        layout = "bps"
        """
        #expect(warnings(toml).contains { $0.contains("layout \"bps\" is not a registered engine") })
        #expect(errors(toml).isEmpty, "a clamp never fails the check")
    }

    @Test func anUnknownIsolateLayoutIsAWarning() {
        let toml = """
        [desktop.2]
        type = "isolate"
        match = 'app~=Chrome'
        layout = "bps"
        """
        #expect(warnings(toml).contains { $0.contains("not a registered engine") })
        #expect(errors(toml).isEmpty)
    }

    // MARK: - the exit-code mapping

    @Test func exitCodeIsOneOnlyForErrors() {
        #expect(configValidateExitCode(schemaErrorCount: 0, diagnostics: []) == 0)
        #expect(configValidateExitCode(schemaErrorCount: 1, diagnostics: []) == 1)
        #expect(configValidateExitCode(
            schemaErrorCount: 0,
            diagnostics: [.init(.warning, "clamped")]) == 0,
                "a clamp never fails the check")
        #expect(configValidateExitCode(
            schemaErrorCount: 0,
            diagnostics: [.init(.warning, "clamped"), .init(.error, "dropped")]) == 1)
    }

    // MARK: - the unreadable file (the last door out of the opt-in flip)

    /// ⬅ From the review. `load(path:)` collapsed "file exists but can't be read"
    /// (bad perms, saved in a non-UTF-8 encoding — plausible: this config carries
    /// Japanese comments) into a bare default config — which declares no desktop
    /// blocks — so facet concluded nobody had ever configured it and seized EVERY
    /// mac desktop. Bit-for-bit the destructive flip (c) exists to close.
    /// `--validate` already refused this path (exit 2, its comment calls the
    /// lenient collapse "a trap"); the daemon walked straight into it.
    @Test func anUnreadableConfigManagesNothing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-unreadable-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml")
        // Lone 0xFF — not valid UTF-8, so `String(data:encoding:)` returns nil.
        try Data([0xFF, 0xFE, 0xFD]).write(to: path)

        let c = FacetConfig.load(path: path.path)
        #expect(c.declaresDesktopBlocks, "an existing config is a configured user")
        #expect(!c.isMacDesktopManaged(ordinal: 1),
                "facet must not seize desktops because it failed to read the file")
        #expect(!c.isMacDesktopManaged(ordinal: Int?.none))
        #expect(c.diagnostics.hasErrors)
        #expect(c.diagnostics.contains { $0.message.contains("could not be read") })
    }

    /// The contrast, and the case this must not break: NO config file at all is a
    /// fresh install, not a broken one → every mac desktop managed with defaults.
    @Test func aMissingConfigStillManagesEveryDesktop() {
        let c = FacetConfig.load(path: "/nonexistent/facet/config.toml")
        #expect(!c.declaresDesktopBlocks)
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(c.diagnostics.isEmpty)
    }

    // MARK: - a clean config stays clean

    /// The whole point of the severity split: everything facet ships as an
    /// example must decode with ZERO errors, or `--validate` becomes noise the
    /// user learns to ignore.
    @Test func aValidConfigHasNoDiagnostics() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        label = "Code"

        [[desktop.1.section]]
        layout = "bsp"

        [desktop.2]
        type = "isolate"
        label = "Web"
        match = 'app=Safari or app~=Chrome'
        layout = "bsp"
        show-non-matching = true

        [[exclude]]
        app = "com.apple.systempreferences"
        action = "float"

        
        """)
        #expect(c.diagnostics.isEmpty, "\(c.diagnostics.map(\.message))")
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(c.isMacDesktopManaged(ordinal: 2))
        #expect(!c.isMacDesktopManaged(ordinal: 3))
    }
}
