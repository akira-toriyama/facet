import Testing
@testable import FacetCore

/// t-5312: `[alias]` decode + its integration into the desktop / rule
/// decoders. Contract: every unusable `[alias]` entry is DROPPED with a
/// `.error` (wrote-it-and-lost-it → validate exit 1; the daemon logs and
/// boots), the returned table is FULLY RESOLVABLE (drops cascade), and a
/// `match` whose alias reference doesn't resolve DROPS its whole block —
/// an isolate desktop degraded to never-match would anchor-park EVERY
/// window, so hands-off is the only safe verdict.
struct FilterAliasDecodeTests {

    private func decode(_ toml: String)
        -> (aliases: [String: String], diags: [ConfigDiagnostic])
    {
        var diags: [ConfigDiagnostic] = []
        let aliases = FacetConfig.decodeFilterAliases(fromTOML: toml,
                                                      diagnostics: &diags)
        return (aliases, diags)
    }

    private func errors(_ diags: [ConfigDiagnostic]) -> [String] {
        diags.filter { $0.severity == .error }.map(\.message)
    }

    // MARK: - [alias] table decode

    @Test func decodesAValidTable() {
        let (aliases, diags) = decode("""
        [alias]
        web = 'app~=Chrome or app~=Safari'
        work = '@web or app=Slack'
        """)
        #expect(aliases == ["web": "app~=Chrome or app~=Safari",
                            "work": "@web or app=Slack"])
        #expect(diags.isEmpty)
    }

    @Test func noAliasTableDecodesEmpty() {
        let (aliases, diags) = decode("[theme]\nname = \"terminal\"\n")
        #expect(aliases.isEmpty)
        #expect(diags.isEmpty)
    }

    @Test func nonKebabNameIsDroppedLoud() {
        let (aliases, diags) = decode("[alias]\nWeb = 'floating'\n")
        #expect(aliases.isEmpty)
        #expect(errors(diags).contains { $0.contains("kebab-case") })
    }

    @Test func emptyExpressionIsDroppedLoud() {
        // The match-all trap: parse("") == .all, so a stray @blank would
        // otherwise silently select every window.
        let (aliases, diags) = decode("[alias]\nblank = ''\n")
        #expect(aliases.isEmpty)
        #expect(errors(diags).contains { $0.contains("EVERYTHING") })
    }

    @Test func nonStringValueIsDroppedLoud() {
        let (aliases, diags) = decode("[alias]\nnum = 3\n")
        #expect(aliases.isEmpty)
        #expect(errors(diags).contains { $0.contains("expected a string") })
    }

    @Test func malformedExpressionIsDroppedLoudWithACaret() {
        let (aliases, diags) = decode("[alias]\nbad = 'tag~web'\n")
        #expect(aliases.isEmpty)
        #expect(errors(diags).contains { $0.contains("does not parse") })
    }

    @Test func unknownFieldInsideAnAliasIsAWarningNotADrop() {
        let (aliases, diags) = decode("[alias]\noops = 'ap=Chrome'\n")
        #expect(aliases == ["oops": "ap=Chrome"])   // survives
        #expect(diags.contains { $0.severity == .warning
            && $0.message.contains("unknown field") })
    }

    @Test func cycleDropsBothMembersNamingTheCycle() {
        let (aliases, diags) = decode("""
        [alias]
        a = '@b'
        b = '@a'
        """)
        #expect(aliases.isEmpty)
        let cycleErrors = errors(diags).filter { $0.contains("cycle") }
        #expect(cycleErrors.count == 2)   // both report the CYCLE, not "undefined"
    }

    @Test func dropCascades() {
        // `web` dies (malformed) → `work` (built on it) dies too, each loud.
        let (aliases, diags) = decode("""
        [alias]
        web = 'tag~broken'
        work = '@web or app=Slack'
        """)
        #expect(aliases.isEmpty)
        #expect(errors(diags).contains { $0.contains("does not parse") })
        #expect(errors(diags).contains { $0.contains("undefined filter alias '@web'") })
    }

    @Test func undefinedReferenceIsDroppedLoud() {
        let (aliases, diags) = decode("[alias]\nwork = '@ghost or floating'\n")
        #expect(aliases.isEmpty)
        #expect(errors(diags).contains { $0.contains("'@ghost'") })
    }

    // MARK: - isolate desktop `match` integration

    @Test func isolateMatchResolvingAnAliasSurvives() {
        let toml = """
        [alias]
        web = 'app~=Chrome'

        [desktop.2]
        type = "isolate"
        match = '@web'
        """
        let c = FacetConfig.load(source: toml)
        #expect(c.desktopIsolate(ordinal: 2)?.match == "@web")   // stored VERBATIM
        #expect(!c.diagnostics.contains { $0.severity == .error })
    }

    @Test func isolateMatchWithUndefinedAliasDropsTheDesktop() {
        let toml = """
        [desktop.2]
        type = "isolate"
        match = '@ghost'
        """
        let c = FacetConfig.load(source: toml)
        #expect(c.desktopIsolate(ordinal: 2) == nil)
        #expect(c.diagnostics.contains { $0.severity == .error
            && $0.message.contains("'@ghost'")
            && $0.message.contains("dropping the desktop") })
        // Opt-in survives its own blocks (t-r5yz): the dropped desktop still
        // counts as a declaration, so facet manages NOTHING rather than
        // flipping to manage-every-desktop.
        #expect(c.declaresDesktopBlocks)
    }

    @Test func aliasSmugglingTheWorkspaceFieldIsFlagged() {
        // t-j7ps closed `match = 'workspace=X'` on an isolate desktop; an
        // alias must not reopen it by indirection.
        let toml = """
        [alias]
        sneaky = 'workspace=Dev'

        [desktop.2]
        type = "isolate"
        match = '@sneaky'
        """
        let c = FacetConfig.load(source: toml)
        #expect(c.diagnostics.contains { $0.severity == .error
            && $0.message.contains("workspace") && $0.message.contains("FLAT") })
    }

    // MARK: - [[rule]] `match` integration

    @Test func ruleMatchResolvingAnAliasSurvivesVerbatim() {
        let toml = """
        [alias]
        web = 'app~=Chrome'

        [[rule]]
        match = '@web'
        tags = ["browser"]
        """
        let c = FacetConfig.load(source: toml)
        #expect(c.effectiveRules.map(\.match) == ["@web"])
        #expect(!c.diagnostics.contains { $0.severity == .error })
    }

    @Test func ruleMatchWithUndefinedAliasDropsTheRule() {
        let toml = """
        [[rule]]
        match = '@ghost'
        tags = ["browser"]
        """
        let c = FacetConfig.load(source: toml)
        #expect(c.effectiveRules.isEmpty)
        #expect(c.diagnostics.contains { $0.severity == .error
            && $0.message.contains("'@ghost'")
            && $0.message.contains("dropping the rule") })
    }
}
