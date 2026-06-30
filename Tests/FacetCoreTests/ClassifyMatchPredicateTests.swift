import XCTest
@testable import FacetCore

/// t-0020: `classifyMatchPredicate` — the PURE verdict the runtime match editor
/// shows live. Contract: malformed SYNTAX is a hard `.malformed` (blocking);
/// an unknown FIELD is a soft `.unknownField` (valid-but-matches-nothing, a
/// non-blocking warning, same as a config lens `match`); everything else — incl.
/// the empty revert gesture — is `.ok`. Mirrors `FilterProjection.project`'s own
/// parse + unknown-field handling so the editor never disagrees with the seam.
final class ClassifyMatchPredicateTests: XCTestCase {

    func testKnownFieldComparisonIsOK() {
        XCTAssertEqual(classifyMatchPredicate("app~=Chrome"), .ok)
    }

    func testKnownPresenceAtomIsOK() {
        XCTAssertEqual(classifyMatchPredicate("floating"), .ok)
        XCTAssertEqual(classifyMatchPredicate("not workspace"), .ok)
    }

    func testEmptyPredicateIsOK() {
        // parse("") == .success(.all) → no fields referenced → the revert gesture.
        XCTAssertEqual(classifyMatchPredicate(""), .ok)
    }

    func testBareUnknownWordWarnsNotErrors() {
        // A bare word is a field-PRESENCE atom; `abc` is an unknown field, so the
        // predicate is valid (commits) but matches nothing — a warning, never an
        // error. This is the exact case the user hit ("abc doesn't error").
        XCTAssertEqual(classifyMatchPredicate("abc"), .unknownField(["abc"]))
    }

    func testUnknownFieldInComparisonWarns() {
        XCTAssertEqual(classifyMatchPredicate("foo=bar"), .unknownField(["foo"]))
    }

    func testMultipleUnknownFieldsAreSortedAndDeduped() {
        // fieldsReferenced is a Set → the message order must be deterministic.
        XCTAssertEqual(classifyMatchPredicate("zed or abc or abc"),
                       .unknownField(["abc", "zed"]))
    }

    func testKnownAndUnknownMixReportsOnlyUnknown() {
        // `app` known, `bogus` unknown → warn on `bogus` alone.
        XCTAssertEqual(classifyMatchPredicate("app=Safari or bogus"),
                       .unknownField(["bogus"]))
    }

    func testMalformedSyntaxIsError() {
        guard case .malformed = classifyMatchPredicate("tag~~web") else {
            return XCTFail("expected .malformed for a syntax error")
        }
    }

    func testMalformedCarriesAUsableMessage() {
        guard case .malformed(let err) = classifyMatchPredicate("tag~web") else {
            return XCTFail("expected .malformed")
        }
        XCTAssertFalse(err.message.isEmpty)          // inline panel shows .message
        XCTAssertFalse(err.caret(in: "tag~web").isEmpty)  // CLI shows the caret
    }
}
