import XCTest
@testable import FacetCore

/// `[[rule]]` adopt-rule decode (#282/#286 Phase 3, PR-A — parse-only).
/// These pin the pure `decodeRuleSections` decoder + the flat-key → `ApplyOp`
/// reuse; the classify-gate evaluation lands in PR-B. CI-only (no XCTest on
/// CommandLineTools).
final class RuleDecodeTests: XCTestCase {

    func testDecodesMatchAndFlatApply() {
        let toml = """
        [[rule]]
        match = "app=Safari"
        tags = ["web"]
        floating = true
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.match, "app=Safari")
        XCTAssertEqual(rules.first?.apply, [.addTag("web"), .setFloating(true)])
    }

    func testApplyCanonicalOrderIgnoresAuthoredOrder() {
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
        XCTAssertEqual(rules.first?.apply, [
            .setWorkspace("Dev"), .addTag("a"), .addTag("b"),
            .setFloating(true), .setSticky(false), .setMaster(true),
        ])
    }

    func testDropsRuleWithNoMatch() {
        let toml = """
        [[rule]]
        tags = ["web"]
        """
        XCTAssertTrue(FacetConfig.decodeRuleSections(fromTOML: toml).isEmpty)
    }

    func testDropsRuleWithBlankMatch() {
        let toml = """
        [[rule]]
        match = "   "
        floating = true
        """
        XCTAssertTrue(FacetConfig.decodeRuleSections(fromTOML: toml).isEmpty)
    }

    func testDropsInertRuleWithNoApplyOp() {
        // A `match` with nothing to apply adopts nothing → dropped, like a
        // blank `[[exclude]]`.
        let toml = """
        [[rule]]
        match = "app=Safari"
        """
        XCTAssertTrue(FacetConfig.decodeRuleSections(fromTOML: toml).isEmpty)
    }

    func testMatchGrammarNotValidatedAtDecode() {
        // parse-only stays total: a malformed `match` is stored VERBATIM,
        // never rejected at config-load (the consumer compiles it loud +
        // non-fatal at eval time, PR-B).
        let toml = """
        [[rule]]
        match = "app=="
        floating = true
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        XCTAssertEqual(rules.first?.match, "app==")
        XCTAssertEqual(rules.first?.apply, [.setFloating(true)])
    }

    func testMultipleRulesKeepFileOrder() {
        let toml = """
        [[rule]]
        match = "app=Safari"
        tags = ["web"]

        [[rule]]
        match = "app=Slack"
        tags = ["chat"]
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        XCTAssertEqual(rules.map(\.match), ["app=Safari", "app=Slack"])
    }

    func testUnknownKeysIgnored() {
        let toml = """
        [[rule]]
        match = "app=Safari"
        floating = true
        bogus = 1
        """
        let rules = FacetConfig.decodeRuleSections(fromTOML: toml)
        XCTAssertEqual(rules.first?.apply, [.setFloating(true)])
    }

    func testEffectiveRulesEmptyWhenUnset() {
        XCTAssertEqual(FacetConfig().effectiveRules, [])
    }
}
