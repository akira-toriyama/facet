import XCTest
@testable import FacetCore

/// `TagName.sanitized` — the shared CLI + GUI tag-name validator (#191).
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

    func testKeepsInnerNonDelimiterCharacters() {
        XCTAssertEqual(TagName.sanitized("my-tag.2"), "my-tag.2")
        XCTAssertEqual(TagName.sanitized("a_b"), "a_b")   // inner _ is fine
        XCTAssertEqual(TagName.sanitized("日本語"), "日本語")
    }
}
