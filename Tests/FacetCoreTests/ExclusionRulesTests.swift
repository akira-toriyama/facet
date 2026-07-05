import CoreGraphics
import Testing
@testable import FacetCore

struct ExclusionRulesTests {

    private func probe(bundle: String? = nil, title: String = "",
                       role: String? = nil, subrole: String? = nil,
                       size: CGSize? = nil) -> WindowProbe {
        WindowProbe(bundleId: bundle, title: title,
                    role: role, subrole: subrole, size: size)
    }

    @Test func noRulesMatchesNothing() {
        let r = ExclusionRules([])
        #expect(r.action(for: probe(bundle: "com.apple.finder")) == nil)
        #expect(r.isEmpty)
    }

    @Test func emptyRuleNeverMatches() {
        // A rule with no constraints must not silently drop windows.
        let r = ExclusionRules([ExclusionRule(action: .ignore)])
        #expect(r.action(for: probe(bundle: "anything", title: "x")) == nil)
    }

    @Test func appRegexMatch() {
        let r = ExclusionRules([
            ExclusionRule(app: #"^com\.apple\.finder$"#, action: .float),
        ])
        #expect(r.action(for: probe(bundle: "com.apple.finder")) == .float)
        #expect(r.action(for: probe(bundle: "com.apple.Safari")) == nil)
        #expect(r.action(for: probe(bundle: nil)) == nil)
    }

    @Test func emptyTitleMatchesUnnamedWindow() {
        let r = ExclusionRules([
            ExclusionRule(title: "^$", action: .ignore),
        ])
        #expect(r.action(for: probe(title: "")) == .ignore)
        #expect(r.action(for: probe(title: "Untitled")) == nil)
    }

    @Test func keysWithinRuleAreANDed() {
        let r = ExclusionRules([
            ExclusionRule(app: "Chrome", title: "Save", action: .float),
        ])
        #expect(
            r.action(for: probe(bundle: "com.google.Chrome", title: "Save As")) == .float)
        // app matches but title doesn't -> no match (AND).
        #expect(
            r.action(for: probe(bundle: "com.google.Chrome", title: "GitHub")) == nil)
    }

    @Test func multipleRulesAreORedFirstWins() {
        let r = ExclusionRules([
            ExclusionRule(app: "Chrome", action: .ignore),
            ExclusionRule(title: "Palette", action: .float),
        ])
        #expect(r.action(for: probe(bundle: "com.google.Chrome")) == .ignore)
        #expect(r.action(for: probe(title: "Color Palette")) == .float)
        // First match wins: Chrome rule (ignore) precedes a title rule.
        let r2 = ExclusionRules([
            ExclusionRule(app: "Chrome", action: .ignore),
            ExclusionRule(app: "Chrome", action: .float),
        ])
        #expect(r2.action(for: probe(bundle: "com.google.Chrome")) == .ignore)
    }

    @Test func manageActionReturnedAndWinsFirstMatch() {
        // `.manage` is the inverse escape hatch — force-tile a window the
        // allowlist would otherwise float/ignore. Existing policy tests only
        // ever produce .float/.ignore, so pin that action(for:) returns
        // .manage AND that its first-match-wins precedence beats a later
        // .ignore. A refactor special-casing/filtering .manage out of
        // action(for:) would break the feature silently.
        let r = ExclusionRules([ExclusionRule(app: "Chrome", action: .manage)])
        #expect(r.action(for: probe(bundle: "com.google.Chrome")) == .manage)
        // First-match-wins: a leading .manage beats a later .ignore.
        let r2 = ExclusionRules([
            ExclusionRule(app: "Chrome", action: .manage),
            ExclusionRule(app: "Chrome", action: .ignore),
        ])
        #expect(r2.action(for: probe(bundle: "com.google.Chrome")) == .manage)
    }

    @Test func roleAndSubroleExactMatch() {
        let r = ExclusionRules([
            ExclusionRule(subrole: "AXDialog", action: .float),
        ])
        #expect(
            r.action(for: probe(role: "AXWindow", subrole: "AXDialog")) == .float)
        #expect(r.action(for: probe(role: "AXWindow", subrole: "AXStandardWindow")) == nil)
        // subrole absent (AX not probed) -> role/subrole rule can't match.
        #expect(r.action(for: probe(subrole: nil)) == nil)
    }

    @Test func sizeThresholdMatchesSmallWindows() {
        let r = ExclusionRules([
            ExclusionRule(maxWidth: 400, maxHeight: 300, action: .ignore),
        ])
        #expect(
            r.action(for: probe(size: CGSize(width: 200, height: 150))) == .ignore)
        // Too wide -> no match.
        #expect(
            r.action(for: probe(size: CGSize(width: 800, height: 150))) == nil)
        // Size unknown (no frame) -> size rule can't match.
        #expect(r.action(for: probe(size: nil)) == nil)
    }

    @Test func needsAXRoleReporting() {
        #expect(!ExclusionRule(app: "x").needsAXRole)
        #expect(ExclusionRule(role: "AXWindow").needsAXRole)
        #expect(ExclusionRule(subrole: "AXDialog").needsAXRole)
        #expect(ExclusionRules([
            ExclusionRule(app: "x"), ExclusionRule(subrole: "AXDialog"),
        ]).anyNeedsAXRole)
        #expect(!ExclusionRules([ExclusionRule(app: "x")]).anyNeedsAXRole)
    }

    // MARK: - WindowMatcher (the shared matcher; `[[exclude]]`'s sole
    // consumer since `[[assign]]` was retired in #191)

    @Test func unconstrainedMatcherNeverMatches() {
        #expect(!WindowMatcher().isConstrained)
        #expect(!WindowMatcher().matches(probe(bundle: "any", title: "x")))
    }

    @Test func matcherANDsKeys() {
        let m = WindowMatcher(app: "Chrome", title: "Save")
        #expect(m.matches(probe(bundle: "Chrome", title: "Save As")))
        #expect(!m.matches(probe(bundle: "Chrome", title: "Open")))
        #expect(!m.matches(probe(bundle: "Safari", title: "Save As")))
    }

    @Test func matcherNeedsAXRole() {
        #expect(WindowMatcher(role: "AXWindow").needsAXRole)
        #expect(WindowMatcher(subrole: "AXDialog").needsAXRole)
        #expect(!WindowMatcher(app: "X").needsAXRole)
    }

    // MARK: - Invalid-regex safety (cov-03)
    //
    // The documented contract is "an invalid pattern can't crash and
    // never matches — a typo only loses that one predicate." It was
    // comment-only; pin it before the pivot's `title:/re/` reuses or
    // replaces this exact path (e.g. a future switch to
    // NSRegularExpression, which THROWS on a bad pattern).

    @Test func regexMatchesReturnsFalseForMalformedPattern() {
        // Unbalanced bracket / paren / dangling escape — all invalid.
        #expect(!WindowMatcher.regexMatches("[", "anything"))
        #expect(!WindowMatcher.regexMatches("(", "anything"))
        #expect(!WindowMatcher.regexMatches(#"\"#, "anything"))
        // A valid pattern still works (sanity).
        #expect(WindowMatcher.regexMatches("a.c", "abc"))
    }

    @Test func malformedRuleRegexMatchesNothingNoCrash() {
        // A rule whose app pattern is malformed loses just that predicate
        // (matches nothing), never crashes, and doesn't taint sibling rules.
        let r = ExclusionRules([
            ExclusionRule(app: "[", action: .ignore),
            ExclusionRule(app: #"^com\.apple\.finder$"#, action: .float),
        ])
        #expect(r.action(for: probe(bundle: "anything")) == nil,
                "malformed pattern matches nothing")
        #expect(r.action(for: probe(bundle: "com.apple.finder")) == .float,
                "the later valid rule still matches")
    }
}
