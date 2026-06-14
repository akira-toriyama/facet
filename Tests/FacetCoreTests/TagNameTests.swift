import XCTest
@testable import FacetCore

/// `TagName.sanitized` / `.normalized` — the shared CLI + GUI tag-name
/// validators (#191, policy tightened in #227: leading `-` + internal
/// whitespace now rejected; `.normalized` collapses spaces to `-`).
final class TagNameTests: XCTestCase {

    func testStripsLeadingHashAndTrims() {
        XCTAssertEqual(TagName.sanitized("web"), "web")
        XCTAssertEqual(TagName.sanitized("  web "), "web")
        XCTAssertEqual(TagName.sanitized("#web"), "web")
        XCTAssertEqual(TagName.sanitized("  # code "), "code")
    }

    func testRejectsEmpty() {
        XCTAssertNil(TagName.sanitized(""))
        XCTAssertNil(TagName.sanitized("   "))
        XCTAssertNil(TagName.sanitized("#"))      // only a hash → empty
        XCTAssertNil(TagName.sanitized("#  "))
    }

    func testRejectsReservedUnderscorePrefix() {
        XCTAssertNil(TagName.sanitized("_default"))
        XCTAssertNil(TagName.sanitized("_x"))
        XCTAssertNil(TagName.sanitized("#_x"))    // hash strip then leading _
    }

    func testRejectsDelimiterChars() {
        XCTAssertNil(TagName.sanitized("a:b"))
        XCTAssertNil(TagName.sanitized("a,b"))
        XCTAssertNil(TagName.sanitized("a=b"))
    }

    /// #227: a leading `-` would be mistaken for a flag under the
    /// space-separated grammar's strict consumption, so it's rejected.
    /// An inner `-` stays legal (see `testKeepsInnerNonDelimiterCharacters`).
    func testRejectsLeadingDash() {
        XCTAssertNil(TagName.sanitized("-foo"))
        XCTAssertNil(TagName.sanitized("  -foo "))
        XCTAssertNil(TagName.sanitized("#-foo"))  // hash strip then leading -
    }

    /// #227: internal whitespace is rejected by the strict validator
    /// (the shell already split CLI tokens, so a space inside one is a
    /// genuine error). The GUI path uses `normalized` instead.
    func testRejectsInternalWhitespace() {
        XCTAssertNil(TagName.sanitized("a b"))
        XCTAssertNil(TagName.sanitized("a\tb"))
        XCTAssertNil(TagName.sanitized("my tag"))
    }

    func testKeepsInnerNonDelimiterCharacters() {
        XCTAssertEqual(TagName.sanitized("my-tag.2"), "my-tag.2")
        XCTAssertEqual(TagName.sanitized("a_b"), "a_b")   // inner _ is fine
        XCTAssertEqual(TagName.sanitized("日本語"), "日本語")
    }

    /// #227: `normalized` is the lenient variant for free-typed input
    /// (GUI box, config `[[tag]] name`) — it collapses internal whitespace
    /// runs to `-` before validating, so "my tag" → "my-tag".
    func testNormalizedCollapsesSpacesToDash() {
        XCTAssertEqual(TagName.normalized("my tag"), "my-tag")
        XCTAssertEqual(TagName.normalized("  multi   word  name "),
                       "multi-word-name")
        XCTAssertEqual(TagName.normalized("#my tag"), "my-tag")
        XCTAssertEqual(TagName.normalized("web"), "web")  // no-op on clean
    }

    /// `normalized` still rejects what no amount of space-collapsing can
    /// fix: a delimiter, a leading `_` / `-`, or an empty result.
    func testNormalizedStillRejectsHardViolations() {
        XCTAssertNil(TagName.normalized("a:b"))
        XCTAssertNil(TagName.normalized("_x"))
        XCTAssertNil(TagName.normalized("-foo"))
        XCTAssertNil(TagName.normalized("   "))
    }
}
