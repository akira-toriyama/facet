import XCTest
@testable import FacetCore

final class TOMLTests: XCTestCase {

    func testTopLevelKeyValuePairs() {
        let p = parseTOMLSubset("""
            default_view = "tree"
            theme = "cute"
            """)
        XCTAssertEqual(p[""]?["default_view"], .string("tree"))
        XCTAssertEqual(p[""]?["theme"], .string("cute"))
    }

    func testSectionScopesKeys() {
        let p = parseTOMLSubset("""
            cols = 1

            [grid]
            cols = 4
            """)
        XCTAssertEqual(p[""]?["cols"], .int(1))
        XCTAssertEqual(p["grid"]?["cols"], .int(4))
    }

    func testIntStringBoolValueParsing() {
        let p = parseTOMLSubset("""
            n = 42
            s = "hello"
            b1 = true
            b2 = false
            """)
        XCTAssertEqual(p[""]?["n"], .int(42))
        XCTAssertEqual(p[""]?["s"], .string("hello"))
        XCTAssertEqual(p[""]?["b1"], .bool(true))
        XCTAssertEqual(p[""]?["b2"], .bool(false))
    }

    func testLineCommentsAreIgnored() {
        let p = parseTOMLSubset("""
            # this whole line is comment
            n = 1
            """)
        XCTAssertNil(p[""]?[""])
        XCTAssertEqual(p[""]?["n"], .int(1))
    }

    func testInlineCommentStrippedOnUnquotedValues() {
        let p = parseTOMLSubset("n = 4 # cols\n")
        XCTAssertEqual(p[""]?["n"], .int(4))
    }

    func testInlineHashInsideQuotedStringIsKept() {
        // `#` inside "…" should stay as data, not be treated as a
        // comment start.
        let p = parseTOMLSubset(#"s = "a#b" # tail"#)
        XCTAssertEqual(p[""]?["s"], .string("a#b"))
    }

    func testUnknownValueShapeIsSkipped() {
        // `1.5` isn't supported (no float case) → skipped, leaves
        // surrounding keys intact.
        let p = parseTOMLSubset("""
            ok = 1
            bad = 1.5
            also_ok = 2
            """)
        XCTAssertEqual(p[""]?["ok"], .int(1))
        XCTAssertNil(p[""]?["bad"])
        XCTAssertEqual(p[""]?["also_ok"], .int(2))
    }

    func testEmptyAndWhitespaceLinesAreIgnored() {
        let p = parseTOMLSubset("""


            n = 1

            """)
        XCTAssertEqual(p[""]?["n"], .int(1))
    }
}
