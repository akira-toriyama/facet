import Testing
@testable import FacetCore

/// t-5312: filter-alias resolution — the pure `@name` substitution step.
/// Contract: resolution is AST substitution (never text expansion), lookup is
/// case-insensitive, nesting works, an undefined / cyclic ref is REPORTED and
/// left in place as `.aliasRef` (which matches nothing at eval), and a clean
/// resolve is byte-equal to having written the expansion inline.
struct FilterAliasTests {

    private func parsed(_ s: String) -> FacetFilter {
        guard case .success(let f) = FacetFilter.parse(s) else {
            Issue.record("unexpected parse failure for \"\(s)\"")
            return .all
        }
        return f
    }

    // MARK: - parsing (@name is a primary)

    @Test func aliasRefParses() {
        #expect(parsed("@web") == .aliasRef("web"))
    }

    @Test func aliasRefComposesWithCombinators() {
        #expect(parsed("not @web") == .not(.aliasRef("web")))
        #expect(parsed("@a and @b") == .and([.aliasRef("a"), .aliasRef("b")]))
        #expect(parsed("(@web or app=Slack)")
            == .or([.aliasRef("web"),
                    .atom(.init(field: "app",
                                kind: .compare(op: .equals, value: "Slack",
                                               caseSensitive: false)))]))
    }

    @Test func atInValuePositionStaysLiteral() {
        // `tag=@web` compares against the literal string "@web" — only a
        // PRIMARY-position `@` is a reference.
        #expect(parsed("tag=@web")
            == .atom(.init(field: "tag",
                           kind: .compare(op: .equals, value: "@web",
                                          caseSensitive: false))))
    }

    @Test func atInsideQuotesStaysLiteral() {
        #expect(parsed("title*=\"a@b\"")
            == .atom(.init(field: "title",
                           kind: .compare(op: .substring, value: "a@b",
                                          caseSensitive: false))))
    }

    @Test func bareAtIsAParseError() {
        guard case .failure(let e) = FacetFilter.parse("@") else {
            Issue.record("expected a parse error for a bare '@'")
            return
        }
        #expect(e.message.contains("alias name"))
    }

    @Test func aliasRefRendersAndRoundTrips() {
        let f = parsed("not @web and app=Slack")
        #expect(FacetFilter.parse(f.description) == .success(f))
    }

    // MARK: - resolution

    @Test func substitutionEqualsInlineExpansion() {
        let res = parsed("@web or app=Slack")
            .resolvingAliases(["web": "app~=Chrome or app~=Safari"])
        #expect(res.isClean)
        #expect(res.filter == parsed("(app~=Chrome or app~=Safari) or app=Slack"))
    }

    @Test func nestedAliasesResolve() {
        let table = ["work": "@web or app=Slack", "web": "app~=Chrome"]
        let res = parsed("@work").resolvingAliases(table)
        #expect(res.isClean)
        #expect(res.filter == parsed("app~=Chrome or app=Slack"))
    }

    @Test func lookupIsCaseInsensitive() {
        let res = parsed("@WeB").resolvingAliases(["web": "floating"])
        #expect(res.isClean)
        #expect(res.filter == parsed("floating"))
    }

    @Test func undefinedRefIsReportedAndLeftInPlace() {
        let res = parsed("@typo or floating").resolvingAliases([:])
        #expect(res.undefined == ["typo"])
        #expect(res.cycles.isEmpty)
        // The ref stays in the tree — and matches nothing at eval — while
        // the REST of the expression still works.
        #expect(res.filter == .or([.aliasRef("typo"), parsed("floating")]))
    }

    @Test func cycleIsDetectedWithARenderedChain() {
        let table = ["a": "@b", "b": "@a"]
        let res = parsed("@a").resolvingAliases(table)
        #expect(res.cycles == ["@a → @b → @a"])
        #expect(res.undefined.isEmpty)
    }

    @Test func selfCycleIsDetected() {
        let res = parsed("@me").resolvingAliases(["me": "@me"])
        #expect(res.cycles == ["@me → @me"])
    }

    @Test func emptyAliasExprNeverSubstitutesMatchAll() {
        // parse("") == .success(.all) — substituting it would silently turn a
        // stray ref into match-EVERYTHING. Decode drops empties; the resolver
        // still refuses them (undefined) as the safety floor.
        let res = parsed("@blank").resolvingAliases(["blank": "   "])
        #expect(res.undefined == ["blank"])
        #expect(res.filter == .aliasRef("blank"))
    }

    @Test func unresolvedRefEvaluatesToNoMatch() {
        struct W: WindowFields {
            func filterValue(_ field: String) -> String? { "anything" }
            func filterHas(_ field: String) -> Bool { true }
        }
        #expect(FacetFilter.aliasRef("ghost").matches(W()) == false)
        // …and its negation matches everything (a total, boring degrade).
        #expect(FacetFilter.not(.aliasRef("ghost")).matches(W()) == true)
    }

    @Test func aliasesReferencedCollectsLowercased() {
        #expect(parsed("@Web or (not @dev and floating)").aliasesReferenced()
            == ["web", "dev"])
    }

    // MARK: - name policy

    @Test("kebab name shape", arguments: [
        (name: "web", ok: true),
        (name: "my-apps2", ok: true),
        (name: "a", ok: true),
        (name: "Web", ok: false),      // uppercase — refs lowercase, unreachable
        (name: "2web", ok: false),     // digit lead
        (name: "-web", ok: false),     // dash lead
        (name: "", ok: false),
        (name: "wide space", ok: false),
        (name: "under_score", ok: false),
    ])
    func aliasNameShape(name: String, ok: Bool) {
        #expect(isValidFilterAliasName(name) == ok)
    }

    // MARK: - checklist composition (t-kywh)

    @Test func checkedAliasesAreTheTopLevelOrRefs() {
        #expect(matchCheckedAliases("@web") == ["web"])
        #expect(matchCheckedAliases("@web or @dev") == ["web", "dev"])
        #expect(matchCheckedAliases("@Web or app=Slack") == ["web"])  // case + mixed
        #expect(matchCheckedAliases("") == [])                        // empty match
        #expect(matchCheckedAliases("app=Slack") == [])
        // NOT top-level OR terms: nested / negated refs stay unchecked.
        #expect(matchCheckedAliases("not @web") == [])
        #expect(matchCheckedAliases("@web and floating") == [])
        #expect(matchCheckedAliases("tag~=x") == [])                  // malformed? no — valid, no refs
        #expect(matchCheckedAliases("tag~~x") == nil)                 // malformed → nil
    }

    @Test func togglingAddsAndRemovesTopLevelOrTerms() {
        #expect(matchTogglingAlias("", name: "web") == "@web")
        #expect(matchTogglingAlias("@web", name: "dev") == "@web or @dev")
        #expect(matchTogglingAlias("@web or @dev", name: "web") == "@dev")
        #expect(matchTogglingAlias("@web", name: "web") == "")   // last off → revert gesture
        #expect(matchTogglingAlias("@Web", name: "WEB") == "")   // case-insensitive
        #expect(matchTogglingAlias("tag~~x", name: "web") == nil)  // malformed → refuse
    }

    @Test func togglingPreservesHandWrittenTerms() {
        #expect(matchTogglingAlias("app=Slack", name: "web")
            == "app=Slack or @web")
        #expect(matchTogglingAlias("app=Slack or @web", name: "web")
            == "app=Slack")
        // A tighter-binding term survives a plain " or " join (or is the
        // loosest precedence — no parens needed).
        #expect(matchTogglingAlias("app=Slack and floating", name: "web")
            == "app=Slack and floating or @web")
    }

    @Test func toggleRoundTripsThroughTheParser() {
        // The rewritten text must re-parse and re-derive the same checks.
        let t1 = matchTogglingAlias("@web or app=Slack", name: "dev")!
        #expect(matchCheckedAliases(t1) == ["web", "dev"])
        let t2 = matchTogglingAlias(t1, name: "web")!
        #expect(matchCheckedAliases(t2) == ["dev"])
    }

    // MARK: - display-name inheritance

    @Test func singleAliasRefInheritsItsName() {
        #expect(isolateAliasInheritedLabel(match: "@web", label: "") == "web")
        #expect(isolateAliasInheritedLabel(match: "  @Web  ", label: "") == "web")
    }

    @Test func explicitLabelWins() {
        #expect(isolateAliasInheritedLabel(match: "@web", label: "Browsers") == nil)
    }

    @Test func compoundOrPlainMatchInheritsNothing() {
        #expect(isolateAliasInheritedLabel(match: "@web or floating", label: "") == nil)
        #expect(isolateAliasInheritedLabel(match: "app~=Chrome", label: "") == nil)
        #expect(isolateAliasInheritedLabel(match: "not @web", label: "") == nil)
        #expect(isolateAliasInheritedLabel(match: "", label: "") == nil)
    }
}
