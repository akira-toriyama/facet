import XCTest
@testable import FacetCore

final class TOMLTests: XCTestCase {

    func testTopLevelKeyValuePairs() {
        let p = parseTOMLSubset("""
            default-view = "tree"
            theme = "cute"
            """)
        XCTAssertEqual(p[""]?["default-view"], .string("tree"))
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

    func testHashInsideQuotedStringIsData() {
        // `#` inside "…" must stay as data, not be treated as a
        // comment start. (Tests data preservation alone — no
        // trailing comment.)
        let p = parseTOMLSubset(#"s = "a#b""#)
        XCTAssertEqual(p[""]?["s"], .string("a#b"))
    }

    func testInlineCommentAfterQuotedStringStripped() {
        // The closing quote terminates the value; anything after
        // (`# tail`) is inline comment and dropped. The data
        // `a#b` inside the quotes is preserved.
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

    // MARK: - String arrays (added for setupFiles)

    func testStringArraySingleElement() {
        let p = parseTOMLSubset(#"xs = ["one"]"#)
        XCTAssertEqual(p[""]?["xs"], .stringArray(["one"]))
    }

    func testStringArrayMultipleElementsAndSpacing() {
        let p = parseTOMLSubset(#"xs = [ "a" ,  "b","c" ]"#)
        XCTAssertEqual(p[""]?["xs"],
                       .stringArray(["a", "b", "c"]))
    }

    func testStringArrayEmpty() {
        let p = parseTOMLSubset(#"xs = []"#)
        XCTAssertEqual(p[""]?["xs"], .stringArray([]))
    }

    func testStringArrayMalformedSkippedKeepsOtherKeys() {
        // A bad element (unquoted `b`) drops the whole line,
        // matching the parser's "lose one line on typo" rule.
        let p = parseTOMLSubset("""
            ok = 1
            bad = ["a", b, "c"]
            also = 2
            """)
        XCTAssertEqual(p[""]?["ok"], .int(1))
        XCTAssertNil(p[""]?["bad"])
        XCTAssertEqual(p[""]?["also"], .int(2))
    }
}
