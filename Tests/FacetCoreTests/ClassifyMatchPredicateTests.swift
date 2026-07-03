import Testing
@testable import FacetCore

/// t-0020: `classifyMatchPredicate` — the PURE verdict the runtime match editor
/// shows live. Contract: malformed SYNTAX is a hard `.malformed` (blocking);
/// an unknown FIELD is a soft `.unknownField` (valid-but-matches-nothing, a
/// non-blocking warning, same as a config lens `match`); everything else — incl.
/// the empty revert gesture — is `.ok`. Mirrors `FilterProjection.project`'s own
/// parse + unknown-field handling so the editor never disagrees with the seam.
struct ClassifyMatchPredicateTests {

    @Test func knownFieldComparisonIsOK() {
        #expect(classifyMatchPredicate("app~=Chrome") == .ok)
    }

    @Test func knownPresenceAtomIsOK() {
        #expect(classifyMatchPredicate("floating") == .ok)
        #expect(classifyMatchPredicate("not workspace") == .ok)
    }

    @Test func emptyPredicateIsOK() {
        // parse("") == .success(.all) → no fields referenced → the revert gesture.
        #expect(classifyMatchPredicate("") == .ok)
    }

    @Test func bareUnknownWordWarnsNotErrors() {
        // A bare word is a field-PRESENCE atom; `abc` is an unknown field, so the
        // predicate is valid (commits) but matches nothing — a warning, never an
        // error. This is the exact case the user hit ("abc doesn't error").
        #expect(classifyMatchPredicate("abc") == .unknownField(["abc"]))
    }

    @Test func unknownFieldInComparisonWarns() {
        #expect(classifyMatchPredicate("foo=bar") == .unknownField(["foo"]))
    }

    @Test func multipleUnknownFieldsAreSortedAndDeduped() {
        // fieldsReferenced is a Set → the message order must be deterministic.
        #expect(classifyMatchPredicate("zed or abc or abc") ==
                       .unknownField(["abc", "zed"]))
    }

    @Test func knownAndUnknownMixReportsOnlyUnknown() {
        // `app` known, `bogus` unknown → warn on `bogus` alone.
        #expect(classifyMatchPredicate("app=Safari or bogus") ==
                       .unknownField(["bogus"]))
    }

    @Test func malformedSyntaxIsError() {
        guard case .malformed = classifyMatchPredicate("tag~~web") else {
            Issue.record("expected .malformed for a syntax error")
            return
        }
    }

    @Test func malformedCarriesAUsableMessage() {
        guard case .malformed(let err) = classifyMatchPredicate("tag~web") else {
            Issue.record("expected .malformed")
            return
        }
        #expect(!err.message.isEmpty)          // inline panel shows .message
        #expect(!err.caret(in: "tag~web").isEmpty)  // CLI shows the caret
    }
}
