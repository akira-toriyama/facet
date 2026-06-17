import XCTest
@testable import FacetCore

// Exhaustive grammar table for the `facet filter` parser (pivot Phase 0,
// #283 PR#1). The parser is the load-bearing foundation for every later
// phase, so this table is intentionally fat. CI-ONLY: CLT cannot run
// `swift test` (no XCTest module); the local bar is `swift build`.
final class FacetFilterParserTests: XCTestCase {

    // MARK: helpers

    private func atom(_ field: String) -> FacetFilter {
        .atom(.init(field: field, kind: .presence))
    }
    private func cmp(_ field: String, _ op: FacetFilter.Op, _ value: String,
                     cs: Bool = false) -> FacetFilter {
        .atom(.init(field: field,
                    kind: .compare(op: op, value: value, caseSensitive: cs)))
    }
    private func parsed(_ s: String,
                        _ file: StaticString = #filePath,
                        _ line: UInt = #line) -> FacetFilter {
        switch FacetFilter.parse(s) {
        case .success(let f): return f
        case .failure(let e):
            XCTFail("unexpected parse error at \(e.offset): \(e.message) — for \"\(s)\"",
                    file: file, line: line)
            return .all
        }
    }
    private func error(_ s: String,
                       _ file: StaticString = #filePath,
                       _ line: UInt = #line) -> FacetFilter.ParseError {
        switch FacetFilter.parse(s) {
        case .success(let f):
            XCTFail("expected parse error, got \(f) — for \"\(s)\"",
                    file: file, line: line)
            return .init(message: "", offset: 0)
        case .failure(let e): return e
        }
    }
    /// 0-based Character offset of the first occurrence of `ch`.
    private func col(_ s: String, _ ch: Character) -> Int {
        Array(s).firstIndex(of: ch)!
    }

    // MARK: every operator

    func testEveryOperatorParses() {
        XCTAssertEqual(parsed("tag=web"), cmp("tag", .equals, "web"))
        XCTAssertEqual(parsed("tag~=web"), cmp("tag", .contains, "web"))
        XCTAssertEqual(parsed("title^=Inbox"), cmp("title", .prefix, "Inbox"))
        XCTAssertEqual(parsed("title$=PR"), cmp("title", .suffix, "PR"))
        XCTAssertEqual(parsed("title*=PR"), cmp("title", .substring, "PR"))
        XCTAssertEqual(parsed("workspace|=dog"), cmp("workspace", .hierarchical, "dog"))
    }

    func testOpRawValuesMatchWire() {
        XCTAssertEqual(FacetFilter.Op.equals.rawValue, "=")
        XCTAssertEqual(FacetFilter.Op.contains.rawValue, "~=")
        XCTAssertEqual(FacetFilter.Op.prefix.rawValue, "^=")
        XCTAssertEqual(FacetFilter.Op.suffix.rawValue, "$=")
        XCTAssertEqual(FacetFilter.Op.substring.rawValue, "*=")
        XCTAssertEqual(FacetFilter.Op.hierarchical.rawValue, "|=")
    }

    // MARK: presence + not

    func testBarePresence() {
        XCTAssertEqual(parsed("tag"), atom("tag"))
        XCTAssertEqual(parsed("floating"), atom("floating"))
        XCTAssertEqual(parsed("sticky"), atom("sticky"))
        XCTAssertEqual(parsed("master"), atom("master"))
    }

    func testNotPresence() {
        // `not tag` is the untagged bucket (old `_default`).
        XCTAssertEqual(parsed("not tag"), .not(atom("tag")))
        XCTAssertEqual(parsed("not floating"), .not(atom("floating")))
    }

    func testNestedNot() {
        XCTAssertEqual(parsed("not not tag"), .not(.not(atom("tag"))))
    }

    // MARK: precedence not > and > or

    func testPrecedenceAndBindsTighterThanOr() {
        // a or b and c  ==  a or (b and c)
        XCTAssertEqual(
            parsed("a~=1 or b~=2 and c~=3"),
            .or([cmp("a", .contains, "1"),
                 .and([cmp("b", .contains, "2"), cmp("c", .contains, "3")])]))
    }

    func testPrecedenceNotBindsTighterThanAnd() {
        // not a and b  ==  (not a) and b
        XCTAssertEqual(
            parsed("not a~=1 and b~=2"),
            .and([.not(cmp("a", .contains, "1")), cmp("b", .contains, "2")]))
    }

    // MARK: flattening of chains

    func testAndChainFlattens() {
        XCTAssertEqual(
            parsed("a~=1 and b~=2 and c~=3"),
            .and([cmp("a", .contains, "1"),
                  cmp("b", .contains, "2"),
                  cmp("c", .contains, "3")]))
    }

    func testOrChainFlattens() {
        XCTAssertEqual(
            parsed("a~=1 or b~=2 or c~=3"),
            .or([cmp("a", .contains, "1"),
                 cmp("b", .contains, "2"),
                 cmp("c", .contains, "3")]))
    }

    func testLoneAtomIsNotWrapped() {
        // A single atom must NOT become a 1-element .and / .or.
        XCTAssertEqual(parsed("tag~=web"), cmp("tag", .contains, "web"))
    }

    // MARK: parentheses

    func testParensOverridePrecedence() {
        XCTAssertEqual(
            parsed("(a~=1 or b~=2) and c~=3"),
            .and([.or([cmp("a", .contains, "1"), cmp("b", .contains, "2")]),
                  cmp("c", .contains, "3")]))
    }

    func testRedundantParens() {
        XCTAssertEqual(parsed("(tag~=web)"), cmp("tag", .contains, "web"))
        XCTAssertEqual(parsed("((tag))"), atom("tag"))
    }

    // MARK: quoting + literal symbols

    func testQuotedValueWithSpaces() {
        XCTAssertEqual(parsed("app=\"Visual Studio Code\""),
                       cmp("app", .equals, "Visual Studio Code"))
    }

    func testQuotedValueKeepsOperatorCharsLiteral() {
        // Inside quotes `*` `^` `$` are literal, not operators.
        XCTAssertEqual(parsed("title*=\"2 * 3\""),
                       cmp("title", .substring, "2 * 3"))
        XCTAssertEqual(parsed("title=\"^PR$\""), cmp("title", .equals, "^PR$"))
    }

    func testQuotedValueKeepsKeywordsLiteral() {
        XCTAssertEqual(parsed("title=\"a and b\""),
                       cmp("title", .equals, "a and b"))
    }

    func testEmptyQuotedValue() {
        XCTAssertEqual(parsed("title=\"\""), cmp("title", .equals, ""))
    }

    // MARK: case-sensitivity flag

    func testCaseInsensitiveByDefault() {
        XCTAssertEqual(parsed("app=safari"), cmp("app", .equals, "safari", cs: false))
    }

    func testTrailingSFlagIsCaseSensitive() {
        XCTAssertEqual(parsed("app=safari s"), cmp("app", .equals, "safari", cs: true))
    }

    func testCaseFlagThenConnective() {
        XCTAssertEqual(
            parsed("app=safari s and tag"),
            .and([cmp("app", .equals, "safari", cs: true), atom("tag")]))
    }

    func testTrailingSInValueIsNotFlag() {
        // No whitespace → `s` is part of the value.
        XCTAssertEqual(parsed("app=safaris"), cmp("app", .equals, "safaris"))
    }

    // MARK: keywords as values (position disambiguates)

    func testKeywordInValuePosition() {
        XCTAssertEqual(parsed("tag=and"), cmp("tag", .equals, "and"))
        XCTAssertEqual(parsed("mark=or"), cmp("mark", .equals, "or"))
        XCTAssertEqual(parsed("tag=not"), cmp("tag", .equals, "not"))
    }

    // MARK: empty input

    func testEmptyInputIsAll() {
        XCTAssertEqual(parsed(""), .all)
        XCTAssertEqual(parsed("   "), .all)
        XCTAssertEqual(parsed("\t \t"), .all)
    }

    // MARK: realistic locked-design examples

    func testDesignExamples() {
        XCTAssertEqual(
            parsed("tag~=web and not floating"),
            .and([cmp("tag", .contains, "web"), .not(atom("floating"))]))
        XCTAssertEqual(
            parsed("(tag~=work or tag~=urgent) and not tag~=wip"),
            .and([.or([cmp("tag", .contains, "work"),
                       cmp("tag", .contains, "urgent")]),
                  .not(cmp("tag", .contains, "wip"))]))
        XCTAssertEqual(
            parsed("app=Safari and title*=PR"),
            .and([cmp("app", .equals, "Safari"),
                  cmp("title", .substring, "PR")]))
        XCTAssertEqual(parsed("not tag"), .not(atom("tag")))
    }

    // MARK: unknown field parses fine (typo is loud only at eval)

    func testUnknownFieldParsesOK() {
        XCTAssertEqual(parsed("frobnicate~=x"), cmp("frobnicate", .contains, "x"))
        XCTAssertEqual(parsed("frob"), atom("frob"))
    }

    // MARK: ParseError + caret offsets

    func testOperatorMissingEquals() {
        let s = "tag~web"
        let e = error(s)
        XCTAssertEqual(e.offset, col(s, "~"))       // 3
        XCTAssertTrue(e.message.contains("expected '='"), e.message)
    }

    func testBarPipeOperatorMissingEquals() {
        let s = "tag|web"
        let e = error(s)
        XCTAssertEqual(e.offset, col(s, "|"))
        XCTAssertTrue(e.message.contains("after '|'"), e.message)
    }

    func testMissingValueAfterOp() {
        let s = "tag~="
        let e = error(s)
        XCTAssertEqual(e.offset, s.count)           // EOF (5)
        XCTAssertTrue(e.message.contains("expected a value"), e.message)
    }

    func testUnterminatedQuote() {
        let s = "app=\"unterminated"
        let e = error(s)
        XCTAssertEqual(e.offset, col(s, "\""))      // 4
        XCTAssertTrue(e.message.contains("unterminated"), e.message)
    }

    func testUnclosedParen() {
        let s = "(tag~=a"
        let e = error(s)
        XCTAssertEqual(e.offset, s.count)           // EOF (7)
        XCTAssertTrue(e.message.contains("expected ')'"), e.message)
    }

    func testLeadingConnective() {
        let s = "and tag~=a"
        let e = error(s)
        XCTAssertEqual(e.offset, 0)
        XCTAssertTrue(e.message.contains("and"), e.message)
    }

    func testUppercaseKeywordHint() {
        let s = "tag~=a OR tag~=b"
        let e = error(s)
        XCTAssertEqual(e.offset, col(s, "O"))       // 7
        XCTAssertTrue(e.message.contains("did you mean 'or'"), e.message)
    }

    func testDanglingNot() {
        let s = "not"
        let e = error(s)
        XCTAssertEqual(e.offset, s.count)           // EOF (3)
        XCTAssertTrue(e.message.contains("expected a field name"), e.message)
    }

    func testImplicitAndIsRejected() {
        // No implicit space-AND: two adjacent atoms are a syntax error.
        let s = "a~=1 b~=2"
        let e = error(s)
        XCTAssertEqual(e.offset, col(s, "b"))       // 5
        XCTAssertTrue(e.message.contains("unexpected"), e.message)
    }

    func testCaretRendering() {
        let s = "tag~web"
        let e = error(s)
        XCTAssertEqual(e.caret(in: s), "tag~web\n   ^ expected '=' after '~'")
    }

    func testCaretRenderingNormalisesTabs() {
        // A tab in the input becomes one space so the caret stays aligned.
        let s = "a\tb~c"
        let e = error(s)
        XCTAssertEqual(e.offset, col(s, "~"))
        XCTAssertTrue(e.caret(in: s).hasPrefix("a b~c\n"), e.caret(in: s))
    }
}
