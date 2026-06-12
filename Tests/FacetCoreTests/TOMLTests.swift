import XCTest
@testable import FacetCore

final class TOMLTests: XCTestCase {

    func testTopLevelKeyValuePairs() {
        let p = parseTOMLSubset("""
            default-view = "tree"
            theme = "dracula"
            """)
        XCTAssertEqual(p[""]?["default-view"], .string("tree"))
        XCTAssertEqual(p[""]?["theme"], .string("dracula"))
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

    func testFloatValueParsing() {
        // A bare integer stays `.int` (so existing int readers match);
        // only a fractional / exponent token becomes `.double`.
        let p = parseTOMLSubset("""
            whole = 2
            frac = 1.5
            zero = 0.9
            """)
        XCTAssertEqual(p[""]?["whole"], .int(2),
                       "integer literal stays .int")
        XCTAssertEqual(p[""]?["frac"], .double(1.5))
        XCTAssertEqual(p[""]?["zero"], .double(0.9))
    }

    func testAsDoubleWidensIntAndDouble() {
        XCTAssertEqual(TOMLValue.int(2).asDouble, 2.0)
        XCTAssertEqual(TOMLValue.double(1.5).asDouble, 1.5)
        XCTAssertNil(TOMLValue.string("x").asDouble)
        XCTAssertNil(TOMLValue.bool(true).asDouble)
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
        // An unquoted bareword is no supported shape → skipped, leaving
        // surrounding keys intact. (Floats DO parse now — see
        // `testFloatValueParsing` — so this uses a genuine non-value.)
        let p = parseTOMLSubset("""
            ok = 1
            bad = unquoted
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

    // MARK: - String arrays

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

    // MARK: - Inline tables

    func testInlineTableSingleStringPair() {
        let p = parseTOMLSubset(#"t = { name = "Dev" }"#)
        XCTAssertEqual(p[""]?["t"], .table(["name": .string("Dev")]))
    }

    func testInlineTableMixedScalarTypes() {
        let p = parseTOMLSubset(
            #"t = { name = "Dev", layout = "bsp", count = 3, on = true }"#)
        XCTAssertEqual(p[""]?["t"], .table([
            "name": .string("Dev"),
            "layout": .string("bsp"),
            "count": .int(3),
            "on": .bool(true),
        ]))
    }

    func testInlineTableEmpty() {
        let p = parseTOMLSubset(#"t = {}"#)
        XCTAssertEqual(p[""]?["t"], .table([:]))
    }

    func testInlineTableCommasInsideStringDoNotSplit() {
        // A comma inside a string body must not split the pair list.
        let p = parseTOMLSubset(#"t = { name = "a, b", layout = "bsp" }"#)
        XCTAssertEqual(p[""]?["t"], .table([
            "name": .string("a, b"),
            "layout": .string("bsp"),
        ]))
    }

    func testInlineTableMalformedSkippedKeepsOtherKeys() {
        // A malformed pair (no `=`) drops the whole line, matching
        // the parser's "lose one line on typo" rule.
        let p = parseTOMLSubset("""
            ok = 1
            bad = { name "no equals" }
            also = 2
            """)
        XCTAssertEqual(p[""]?["ok"], .int(1))
        XCTAssertNil(p[""]?["bad"])
        XCTAssertEqual(p[""]?["also"], .int(2))
    }

    // MARK: - Array of tables (added for [[exclude]])

    func testArrayOfTablesCollectsEachOccurrence() {
        let tables = parseTOMLArrayOfTables("""
            [[exclude]]
            app = "com.apple.finder"
            action = "float"

            [[exclude]]
            title = "^$"
            action = "ignore"
            """, table: "exclude")
        XCTAssertEqual(tables.count, 2)
        XCTAssertEqual(tables[0]["app"], .string("com.apple.finder"))
        XCTAssertEqual(tables[0]["action"], .string("float"))
        XCTAssertEqual(tables[1]["title"], .string("^$"))
        XCTAssertEqual(tables[1]["action"], .string("ignore"))
    }

    func testArrayOfTablesIgnoresOtherSectionsAndKeys() {
        let tables = parseTOMLArrayOfTables("""
            theme = "dracula"

            [grid]
            cols = 4

            [[exclude]]
            app = "x"
            max_width = 400

            [layout]
            mode = "master-left"
            """, table: "exclude")
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables[0]["app"], .string("x"))
        XCTAssertEqual(tables[0]["max_width"], .int(400))
        // A following [section] closes the block — its keys don't leak in.
        XCTAssertNil(tables[0]["mode"])
        XCTAssertNil(tables[0]["cols"])
    }

    func testArrayOfTablesEmptyWhenAbsent() {
        let tables = parseTOMLArrayOfTables("""
            [grid]
            cols = 2
            """, table: "exclude")
        XCTAssertTrue(tables.isEmpty)
    }

    func testArrayOfTablesDoesNotMatchSingleBracketSection() {
        // `[exclude]` (single bracket) is a plain section, not an
        // array-of-tables entry → not collected.
        let tables = parseTOMLArrayOfTables("""
            [exclude]
            app = "x"
            """, table: "exclude")
        XCTAssertTrue(tables.isEmpty)
    }
}
