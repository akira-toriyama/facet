import Testing
@testable import FacetCore

/// `[[rule]]` adopt-rule decode (#282/#286 Phase 3, PR-A — parse-only).
/// These pin the pure `decodeRuleSections` decoder + the flat-key → `ApplyOp`
/// reuse; the classify-gate evaluation lands in PR-B. CI-only (no XCTest on
/// CommandLineTools).
struct RuleDecodeTests {

    @Test func decodesMatchAndFlatApply() {
        let toml = """
        [[rule]]
        match = "app=Safari"
        tags = ["web"]
        floating = true
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        #expect(rules.count == 1)
        #expect(rules.first?.match == "app=Safari")
        #expect(rules.first?.apply == [.addTag("web"), .setFloating(true)])
    }

    @Test func applyCanonicalOrderIgnoresAuthoredOrder() {
        // Frozen order: setWorkspace → addTag(s) → setFloating → setSticky →
        // setMaster, regardless of how the keys are authored.
        let toml = """
        [[rule]]
        match = "tag~=x"
        master = true
        floating = true
        tags = ["a", "b"]
        workspace = "Dev"
        sticky = false
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        #expect(rules.first?.apply == [
            .setWorkspace("Dev"), .addTag("a"), .addTag("b"),
            .setFloating(true), .setSticky(false), .setMaster(true),
        ])
    }

    @Test func emptyWorkspaceOpDroppedSiblingSurvives() {
        // `ApplyOp.list` guards `!ws.isEmpty`: an empty `workspace = ""`
        // emits NO `.setWorkspace`, while a sibling op still survives. Pins
        // the guard directly — a regression that emitted `.setWorkspace("")`
        // in a `[[rule]]` apply would mis-route an adopted window to an
        // empty-named workspace. (The lens tags-only sanitizer drops ALL
        // non-tag ops, so it can't distinguish this guard.)
        let ops = ApplyOp.list(from: .table([
            "workspace": .string(""), "floating": .bool(true),
        ]))
        #expect(ops == [.setFloating(true)])
    }

    @Test func dropsRuleWithNoMatch() {
        let toml = """
        [[rule]]
        tags = ["web"]
        """
        #expect(FacetConfig.decodeRuleSections(fromTOML: toml).isEmpty)
    }

    @Test func dropsRuleWithBlankMatch() {
        let toml = """
        [[rule]]
        match = "   "
        floating = true
        """
        #expect(FacetConfig.decodeRuleSections(fromTOML: toml).isEmpty)
    }

    @Test func dropsInertRuleWithNoApplyOp() {
        // A `match` with nothing to apply adopts nothing → dropped, like a
        // blank `[[exclude]]`.
        let toml = """
        [[rule]]
        match = "app=Safari"
        """
        #expect(FacetConfig.decodeRuleSections(fromTOML: toml).isEmpty)
    }

    @Test func matchGrammarNotValidatedAtDecode() {
        // parse-only stays total: a malformed `match` is stored VERBATIM,
        // never rejected at config-load (the consumer compiles it loud +
        // non-fatal at eval time, PR-B).
        let toml = """
        [[rule]]
        match = "app=="
        floating = true
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        #expect(rules.first?.match == "app==")
        #expect(rules.first?.apply == [.setFloating(true)])
    }

    @Test func multipleRulesKeepFileOrder() {
        let toml = """
        [[rule]]
        match = "app=Safari"
        tags = ["web"]

        [[rule]]
        match = "app=Slack"
        tags = ["chat"]
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        #expect(rules.map(\.match) == ["app=Safari", "app=Slack"])
    }

    @Test func unknownKeysIgnored() {
        let toml = """
        [[rule]]
        match = "app=Safari"
        floating = true
        bogus = 1
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        #expect(rules.first?.apply == [.setFloating(true)])
    }

    @Test func effectiveRulesEmptyWhenUnset() {
        #expect(FacetConfig().effectiveRules == [])
    }
}
