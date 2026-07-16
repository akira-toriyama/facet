import Testing
@testable import FacetCore

/// t-0020: `classifyMatchPredicate` — the PURE verdict the runtime match editor
/// shows live. Contract: malformed SYNTAX is a hard `.malformed` (blocking);
/// an unknown FIELD is a soft `.unknownField` (valid-but-matches-nothing, a
/// non-blocking warning, same as a config lens `match`); everything else — incl.
/// the empty revert gesture — is `.ok`. Mirrors `FilterProjection.project`'s own
/// parse + unknown-field handling so the editor never disagrees with the seam.
struct ClassifyMatchPredicateTests {

    /// Known fields / valid syntax → `.ok`; a parseable predicate that
    /// references unknown field name(s) → a soft `.unknownField([sorted])`
    /// warning (valid-but-matches-nothing). Malformed SYNTAX is `.malformed`
    /// and stays in the two `guard case` tests below (not a clean equality).
    @Test("ok / unknownField verdicts", arguments: [
        (predicate: "app~=Chrome", expected: MatchPredicateStatus.ok),  // known field comparison
        (predicate: "floating", expected: .ok),          // known presence atom
        (predicate: "not workspace", expected: .ok),      // known presence atom (negated)
        // parse("") == .success(.all) → no fields referenced → the revert gesture.
        (predicate: "", expected: .ok),
        // A bare word is a field-PRESENCE atom; `abc` is an unknown field, so the
        // predicate is valid (commits) but matches nothing — a warning, never an
        // error. This is the exact case the user hit ("abc doesn't error").
        (predicate: "abc", expected: .unknownField(["abc"])),
        (predicate: "foo=bar", expected: .unknownField(["foo"])),  // unknown field in comparison
        // fieldsReferenced is a Set → the message order must be deterministic.
        (predicate: "zed or abc or abc", expected: .unknownField(["abc", "zed"])),
        // `app` known, `bogus` unknown → warn on `bogus` alone.
        (predicate: "app=Safari or bogus", expected: .unknownField(["bogus"])),
    ])
    func okOrUnknownFieldVerdict(predicate: String, expected: MatchPredicateStatus) {
        #expect(classifyMatchPredicate(predicate, aliases: [:]) == expected)
    }

    @Test func malformedSyntaxIsError() {
        guard case .malformed = classifyMatchPredicate("tag~~web", aliases: [:]) else {
            Issue.record("expected .malformed for a syntax error")
            return
        }
    }

    @Test func malformedCarriesAUsableMessage() {
        guard case .malformed(let err) = classifyMatchPredicate("tag~web", aliases: [:]) else {
            Issue.record("expected .malformed")
            return
        }
        #expect(!err.message.isEmpty)          // inline panel shows .message
        #expect(!err.caret(in: "tag~web").isEmpty)  // CLI shows the caret
    }

    // MARK: - filter aliases (t-5312)

    /// A resolvable alias ref is `.ok`; the unknown-field check runs on the
    /// RESOLVED filter, so a field typo hiding inside an alias's expansion
    /// surfaces at the match site; undefined refs and cycles get their own
    /// verdicts (sorted names / rendered chains, case-insensitive lookup).
    @Test("alias verdicts", arguments: [
        (predicate: "@web", aliases: ["web": "app~=Chrome"],
         expected: MatchPredicateStatus.ok),
        (predicate: "@WEB", aliases: ["web": "app~=Chrome"],
         expected: .ok),                                  // refs lowercase
        (predicate: "@work", aliases: ["work": "@web or app=Slack",
                                       "web": "app~=Chrome"],
         expected: .ok),                                  // nested
        (predicate: "tag=@web", aliases: [:],
         expected: .ok),                                  // value position: literal
        (predicate: "@typo", aliases: ["web": "app~=Chrome"],
         expected: .undefinedAlias(["typo"])),
        (predicate: "@a or @b", aliases: [:],
         expected: .undefinedAlias(["a", "b"])),          // sorted
        (predicate: "@oops", aliases: ["oops": "ap=Chrome"],
         expected: .unknownField(["ap"])),                // typo inside the expansion
        (predicate: "@a", aliases: ["a": "@b", "b": "@a"],
         expected: .aliasCycle(["@a → @b → @a"])),
        (predicate: "@self", aliases: ["self": "@self"],
         expected: .aliasCycle(["@self → @self"])),
    ])
    func aliasVerdicts(predicate: String, aliases: [String: String],
                       expected: MatchPredicateStatus) {
        #expect(classifyMatchPredicate(predicate, aliases: aliases) == expected)
    }
}
