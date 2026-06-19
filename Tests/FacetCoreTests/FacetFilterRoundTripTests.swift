import XCTest
@testable import FacetCore

/// `FacetFilter` round-trip: `parse → description → parse`. The
/// `CustomStringConvertible` rendering is documented as the inverse of
/// `parse` for any filter built from clean field/value tokens, with
/// precedence-driven parenthesisation (or = 1 < and = 2 < not = 3). This
/// table pins the edges #22 calls out — empty values, parentheses, not/and
/// precedence — plus the two documented NON-round-tripping forms
/// (`.not(.all)` and a value carrying a `"`). Pure; CI-only (CLT can't run
/// `swift test`).
final class FacetFilterRoundTripTests: XCTestCase {

    // MARK: - helpers

    /// Parse `input`, failing the test loudly if it is malformed.
    private func parsed(_ input: String,
                        file: StaticString = #filePath, line: UInt = #line)
        -> FacetFilter
    {
        switch FacetFilter.parse(input) {
        case .success(let f): return f
        case .failure(let e):
            XCTFail("parse failed: \(input) — \(e.message)", file: file, line: line)
            return .all
        }
    }

    /// The canonical serialized form of `input` (parse → description).
    private func serialized(_ input: String,
                            file: StaticString = #filePath, line: UInt = #line)
        -> String
    {
        parsed(input, file: file, line: line).description
    }

    /// Assert that one round-trip reaches a stable fixed point: the parsed AST
    /// re-serializes + re-parses to the SAME AST and the SAME string. Robust
    /// for any parseable input — redundant parens are dropped on the first
    /// pass, so the second pass is a no-op. (Returns the canonical string for
    /// callers that also want to assert it exactly.)
    @discardableResult
    private func assertRoundTrips(_ input: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) -> String {
        let f1 = parsed(input, file: file, line: line)
        let canon = f1.description
        let f2 = parsed(canon, file: file, line: line)
        XCTAssertEqual(f2.description, canon,
                       "serialize not idempotent for \(input)", file: file, line: line)
        let f3 = parsed(f2.description, file: file, line: line)
        XCTAssertEqual(f3, f2,
                       "AST not stable across round-trip for \(input)",
                       file: file, line: line)
        return canon
    }

    // MARK: - empty / all

    func testEmptyInputSerializesToEmptyAndRoundTrips() {
        XCTAssertEqual(serialized(""), "")
        XCTAssertEqual(serialized("   "), "")
        XCTAssertEqual(parsed(""), .all)
        assertRoundTrips("")
    }

    func testEmptyValueIsQuotedAndRoundTrips() {
        // An empty comparison value must be quoted (a bareword would mis-lex).
        XCTAssertEqual(serialized("title=\"\""), "title=\"\"")
        assertRoundTrips("title=\"\"")
    }

    // MARK: - not / and precedence (parenthesisation)

    func testNotBindsTighterThanAndNoParens() {
        // `not tag and floating` == `(not tag) and floating` — not binds
        // tighter, so the printed form needs no parens.
        XCTAssertEqual(serialized("not tag and floating"),
                       "not tag and floating")
        XCTAssertEqual(parsed("not tag and floating"),
                       .and([.not(.atom(.init(field: "tag", kind: .presence))),
                             .atom(.init(field: "floating", kind: .presence))]))
        assertRoundTrips("not tag and floating")
    }

    func testNotOverAndGetsParens() {
        // `not (tag and floating)` — the and is looser than not, so it wraps.
        XCTAssertEqual(serialized("not (tag and floating)"),
                       "not (tag and floating)")
        assertRoundTrips("not (tag and floating)")
    }

    // MARK: - or under and/not (precedence-lowering child wraps)

    func testOrUnderAndGetsParens() {
        XCTAssertEqual(serialized("(tag~=web or floating) and master"),
                       "(tag~=web or floating) and master")
        assertRoundTrips("(tag~=web or floating) and master")
    }

    func testAndUnderOrNeedsNoParens() {
        // and binds tighter than or → no parens around the and branch.
        XCTAssertEqual(serialized("tag~=web or floating and master"),
                       "tag~=web or floating and master")
        assertRoundTrips("tag~=web or floating and master")
    }

    func testNotOverOrGetsParens() {
        XCTAssertEqual(serialized("not (tag~=web or floating)"),
                       "not (tag~=web or floating)")
        assertRoundTrips("not (tag~=web or floating)")
    }

    // MARK: - operators + quoting round-trip

    func testOperatorsRoundTrip() {
        for input in ["tag~=web", "app^=Saf", "title$=foo", "title*=bar",
                      "app|=com", "app=Safari"] {
            XCTAssertEqual(assertRoundTrips(input), input,
                           "operator form changed: \(input)")
        }
    }

    func testCaseSensitiveFlagRoundTrips() {
        XCTAssertEqual(serialized("app=Safari s"), "app=Safari s")
        assertRoundTrips("app=Safari s")
    }

    func testValuesNeedingQuotesRoundTrip() {
        // whitespace + paren force quoting; neither carries a `"`, so both
        // survive a full round-trip.
        XCTAssertEqual(serialized("title=\"hello world\""), "title=\"hello world\"")
        XCTAssertEqual(serialized("title*=\"a(b\""), "title*=\"a(b\"")
        assertRoundTrips("title=\"hello world\"")
        assertRoundTrips("title*=\"a(b\"")
    }

    // MARK: - documented NON-round-tripping forms

    func testNotAllRendersBareNotAndCannotBeRecovered() {
        // `.not(.all)` (match-nothing) is only hand-constructible; it renders
        // as a bare `not ` and the grammar has no match-nothing literal to
        // parse it back, so it is NOT recovered (parse may fail or differ).
        let f = FacetFilter.not(.all)
        XCTAssertEqual(f.description, "not ")
        if case .success(let back) = FacetFilter.parse(f.description) {
            XCTAssertNotEqual(back, f, "unexpectedly round-tripped .not(.all)")
        }
    }
}
