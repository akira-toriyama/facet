import Testing
@testable import FacetCore

// Exhaustive grammar table for the `facet filter` parser (pivot Phase 0,
// #283 PR#1). The parser is the load-bearing foundation for every later
// phase, so this table is intentionally fat. CI-ONLY: CLT cannot run
// `swift test` (no XCTest module); the local bar is `swift build`.
struct FacetFilterParserTests {

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
            Issue.record("unexpected parse error at \(e.offset): \(e.message) — for \"\(s)\"")
            return .all
        }
    }
    private func error(_ s: String,
                       _ file: StaticString = #filePath,
                       _ line: UInt = #line) -> FacetFilter.ParseError {
        switch FacetFilter.parse(s) {
        case .success(let f):
            Issue.record("expected parse error, got \(f) — for \"\(s)\"")
            return .init(message: "", offset: 0)
        case .failure(let e): return e
        }
    }
    /// 0-based Character offset of the first occurrence of `ch`.
    private func col(_ s: String, _ ch: Character) -> Int {
        Array(s).firstIndex(of: ch)!
    }

    // MARK: every operator

    @Test func everyOperatorParses() {
        #expect(parsed("tag=web") == cmp("tag", .equals, "web"))
        #expect(parsed("tag~=web") == cmp("tag", .contains, "web"))
        #expect(parsed("title^=Inbox") == cmp("title", .prefix, "Inbox"))
        #expect(parsed("title$=PR") == cmp("title", .suffix, "PR"))
        #expect(parsed("title*=PR") == cmp("title", .substring, "PR"))
        #expect(parsed("workspace|=dog") == cmp("workspace", .hierarchical, "dog"))
    }

    @Test func opRawValuesMatchWire() {
        #expect(FacetFilter.Op.equals.rawValue == "=")
        #expect(FacetFilter.Op.contains.rawValue == "~=")
        #expect(FacetFilter.Op.prefix.rawValue == "^=")
        #expect(FacetFilter.Op.suffix.rawValue == "$=")
        #expect(FacetFilter.Op.substring.rawValue == "*=")
        #expect(FacetFilter.Op.hierarchical.rawValue == "|=")
    }

    // MARK: presence + not

    @Test func barePresence() {
        #expect(parsed("tag") == atom("tag"))
        #expect(parsed("floating") == atom("floating"))
        #expect(parsed("sticky") == atom("sticky"))
        #expect(parsed("master") == atom("master"))
    }

    @Test func notPresence() {
        // `not tag` is the untagged bucket (old `_default`).
        #expect(parsed("not tag") == .not(atom("tag")))
        #expect(parsed("not floating") == .not(atom("floating")))
    }

    @Test func nestedNot() {
        #expect(parsed("not not tag") == .not(.not(atom("tag"))))
    }

    // MARK: precedence not > and > or

    @Test func precedenceAndBindsTighterThanOr() {
        // a or b and c  ==  a or (b and c)
        #expect(
            parsed("a~=1 or b~=2 and c~=3") ==
            .or([cmp("a", .contains, "1"),
                 .and([cmp("b", .contains, "2"), cmp("c", .contains, "3")])]))
    }

    @Test func precedenceNotBindsTighterThanAnd() {
        // not a and b  ==  (not a) and b
        #expect(
            parsed("not a~=1 and b~=2") ==
            .and([.not(cmp("a", .contains, "1")), cmp("b", .contains, "2")]))
    }

    // MARK: flattening of chains

    @Test func andChainFlattens() {
        #expect(
            parsed("a~=1 and b~=2 and c~=3") ==
            .and([cmp("a", .contains, "1"),
                  cmp("b", .contains, "2"),
                  cmp("c", .contains, "3")]))
    }

    @Test func orChainFlattens() {
        #expect(
            parsed("a~=1 or b~=2 or c~=3") ==
            .or([cmp("a", .contains, "1"),
                 cmp("b", .contains, "2"),
                 cmp("c", .contains, "3")]))
    }

    @Test func loneAtomIsNotWrapped() {
        // A single atom must NOT become a 1-element .and / .or.
        #expect(parsed("tag~=web") == cmp("tag", .contains, "web"))
    }

    // MARK: parentheses

    @Test func parensOverridePrecedence() {
        #expect(
            parsed("(a~=1 or b~=2) and c~=3") ==
            .and([.or([cmp("a", .contains, "1"), cmp("b", .contains, "2")]),
                  cmp("c", .contains, "3")]))
    }

    @Test func redundantParens() {
        #expect(parsed("(tag~=web)") == cmp("tag", .contains, "web"))
        #expect(parsed("((tag))") == atom("tag"))
    }

    // MARK: quoting + literal symbols

    @Test func quotedValueWithSpaces() {
        #expect(parsed("app=\"Visual Studio Code\"") ==
                       cmp("app", .equals, "Visual Studio Code"))
    }

    @Test func quotedValueKeepsOperatorCharsLiteral() {
        // Inside quotes `*` `^` `$` are literal, not operators.
        #expect(parsed("title*=\"2 * 3\"") ==
                       cmp("title", .substring, "2 * 3"))
        #expect(parsed("title=\"^PR$\"") == cmp("title", .equals, "^PR$"))
    }

    @Test func quotedValueKeepsKeywordsLiteral() {
        #expect(parsed("title=\"a and b\"") ==
                       cmp("title", .equals, "a and b"))
    }

    @Test func emptyQuotedValue() {
        #expect(parsed("title=\"\"") == cmp("title", .equals, ""))
    }

    // MARK: case-sensitivity flag

    @Test func caseInsensitiveByDefault() {
        #expect(parsed("app=safari") == cmp("app", .equals, "safari", cs: false))
    }

    @Test func trailingSFlagIsCaseSensitive() {
        #expect(parsed("app=safari s") == cmp("app", .equals, "safari", cs: true))
    }

    @Test func caseFlagThenConnective() {
        #expect(
            parsed("app=safari s and tag") ==
            .and([cmp("app", .equals, "safari", cs: true), atom("tag")]))
    }

    @Test func trailingSInValueIsNotFlag() {
        // No whitespace → `s` is part of the value.
        #expect(parsed("app=safaris") == cmp("app", .equals, "safaris"))
    }

    // MARK: keywords as values (position disambiguates)

    @Test func keywordInValuePosition() {
        #expect(parsed("tag=and") == cmp("tag", .equals, "and"))
        #expect(parsed("mark=or") == cmp("mark", .equals, "or"))
        #expect(parsed("tag=not") == cmp("tag", .equals, "not"))
    }

    // MARK: empty input

    @Test func emptyInputIsAll() {
        #expect(parsed("") == .all)
        #expect(parsed("   ") == .all)
        #expect(parsed("\t \t") == .all)
    }

    // MARK: realistic locked-design examples

    @Test func designExamples() {
        #expect(
            parsed("tag~=web and not floating") ==
            .and([cmp("tag", .contains, "web"), .not(atom("floating"))]))
        #expect(
            parsed("(tag~=work or tag~=urgent) and not tag~=wip") ==
            .and([.or([cmp("tag", .contains, "work"),
                       cmp("tag", .contains, "urgent")]),
                  .not(cmp("tag", .contains, "wip"))]))
        #expect(
            parsed("app=Safari and title*=PR") ==
            .and([cmp("app", .equals, "Safari"),
                  cmp("title", .substring, "PR")]))
        #expect(parsed("not tag") == .not(atom("tag")))
    }

    // MARK: unknown field parses fine (typo is loud only at eval)

    @Test func unknownFieldParsesOK() {
        #expect(parsed("frobnicate~=x") == cmp("frobnicate", .contains, "x"))
        #expect(parsed("frob") == atom("frob"))
    }

    // MARK: ParseError + caret offsets

    @Test func operatorMissingEquals() {
        let s = "tag~web"
        let e = error(s)
        #expect(e.offset == col(s, "~"))       // 3
        #expect(e.message.contains("expected '='"), "\(e.message)")
    }

    @Test func barPipeOperatorMissingEquals() {
        let s = "tag|web"
        let e = error(s)
        #expect(e.offset == col(s, "|"))
        #expect(e.message.contains("after '|'"), "\(e.message)")
    }

    @Test func missingValueAfterOp() {
        let s = "tag~="
        let e = error(s)
        #expect(e.offset == s.count)           // EOF (5)
        #expect(e.message.contains("expected a value"), "\(e.message)")
    }

    @Test func unterminatedQuote() {
        let s = "app=\"unterminated"
        let e = error(s)
        #expect(e.offset == col(s, "\""))      // 4
        #expect(e.message.contains("unterminated"), "\(e.message)")
    }

    @Test func unclosedParen() {
        let s = "(tag~=a"
        let e = error(s)
        #expect(e.offset == s.count)           // EOF (7)
        #expect(e.message.contains("expected ')'"), "\(e.message)")
    }

    @Test func leadingConnective() {
        let s = "and tag~=a"
        let e = error(s)
        #expect(e.offset == 0)
        #expect(e.message.contains("and"), "\(e.message)")
    }

    @Test func uppercaseKeywordHint() {
        let s = "tag~=a OR tag~=b"
        let e = error(s)
        #expect(e.offset == col(s, "O"))       // 7
        #expect(e.message.contains("did you mean 'or'"), "\(e.message)")
    }

    @Test func danglingNot() {
        let s = "not"
        let e = error(s)
        #expect(e.offset == s.count)           // EOF (3)
        #expect(e.message.contains("expected a field name"), "\(e.message)")
    }

    @Test func leadingOperatorWhereFieldExpected() {
        // A stray leading operator (a common typo) where parseAtom expects a
        // field name: the guard's `.map` branch fires and `unexpected()` hits
        // its non-`.word` fallback ("unexpected token"). Pins both the caret
        // offset (0, under the operator) and the composed message for the
        // present-but-not-a-word branch — the one parseAtom path with no other
        // coverage.
        let s = "=tag"
        let e = error(s)
        #expect(e.offset == 0)
        #expect(e.message.contains("expected a field name"), "\(e.message)")
        #expect(e.message == "expected a field name, found unexpected token",
                "\(e.message)")
    }

    @Test func implicitAndIsRejected() {
        // No implicit space-AND: two adjacent atoms are a syntax error.
        let s = "a~=1 b~=2"
        let e = error(s)
        #expect(e.offset == col(s, "b"))       // 5
        #expect(e.message.contains("unexpected"), "\(e.message)")
    }

    @Test func caretRendering() {
        let s = "tag~web"
        let e = error(s)
        #expect(e.caret(in: s) == "tag~web\n   ^ expected '=' after '~'")
    }

    @Test func caretRenderingNormalisesTabs() {
        // A tab in the input becomes one space so the caret stays aligned.
        let s = "a\tb~c"
        let e = error(s)
        #expect(e.offset == col(s, "~"))
        #expect(e.caret(in: s).hasPrefix("a b~c\n"), "\(e.caret(in: s))")
    }
}
