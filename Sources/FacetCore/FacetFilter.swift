// facet filter — the WHERE-clause mini-language (pivot Phase 0, #283).
//
// `facet filter` is facet's cross-cutting matching primitive: one small
// language that the pivot uses everywhere a window predicate is needed —
// `facet query --filter`, `[[desktop.N.section]]` (type=isolate) match, lens membership,
// and `[[rule]]` adopt-rules. It replaces the four ad-hoc matchers
// (grouping-mode / lens / search / role-float) with a single grammar.
//
// This file is the GRAMMAR + AST + parser ONLY — pure FacetCore logic,
// no call sites yet (the evaluator `matches(_:)` lands in #283 PR#2 on a
// `WindowFields` protocol). Keeping it dead-but-tested means it cannot
// regress the running app; the exhaustive parser grammar table
// (`FacetFilterParserTests`) is the cheapest, highest-coverage safety net
// for the whole pivot.
//
// Grammar (locked design — `/tmp/facet-pivot-brainstorm.md`, fully
// decided; do NOT grow it — "a WHERE clause is enough"):
//
//   expr    := orExpr
//   orExpr  := andExpr ( "or"  andExpr )*
//   andExpr := notExpr ( "and" notExpr )*
//   notExpr := "not" notExpr | primary
//   primary := "(" expr ")" | atom
//   atom    := field                       // bare presence
//            | field op value [ "s" ]       // comparison (+ optional case flag)
//   op      := "=" | "~=" | "^=" | "$=" | "*=" | "|="
//   value   := bareword | '"' … '"'
//
// - Combinators are the lowercase words `and` / `or` / `not` and `()` —
//   one spelling each. NO implicit space-AND, NO comma-OR, NO `-`
//   negation shorthand. Precedence: `not` > `and` > `or`.
// - Operators are the CSS attribute operators: `=` exact, `~=`
//   whitespace-token contains (the natural meaning for the `tag` list),
//   `^=` prefix, `$=` suffix, `*=` substring, `|=` hierarchical prefix.
//   (Operator *semantics* are evaluated in PR#2; this file only parses
//   them into `Op`.)
// - Presence is a BARE field: `tag` (has any tag) / `floating` / etc.
//   `not tag` (untagged — the old `_default` bucket) is just `not`
//   applied to the `tag` presence atom.
// - Values are bare or `"…"`; inside quotes `* ^ $` and spaces are
//   LITERAL (no escapes) — e.g. `title*="2 * 3"`. There is no way to
//   embed a literal `"` (rare for app/title; use `facet query | jig`).
// - Matching is case-INSENSITIVE by default; a trailing bare `s` after a
//   comparison value opts into case-SENSITIVE (CSS `[attr=v s]` flag,
//   bracket-free). Only `s` is recognised (insensitive is the default).
// - Field names are NOT validated here: an unknown field parses fine and
//   becomes a no-match at eval (a typo is loud at eval, never a fatal
//   parse crash). The canonical resolvable set is frozen in PR#2.
// - `parse` is total: it returns `.success` or a `ParseError` carrying a
//   caret offset for loud-but-NON-FATAL reporting (the caller logs the
//   caret and degrades to show-all — it never aborts).

/// A parsed `facet filter` expression — the predicate AST.
///
/// `and` / `or` carry a flattened list (`a and b and c` →
/// `.and([a, b, c])`), a lone atom is `.atom` (not a 1-element `.and`),
/// and an empty / whitespace-only input parses to `.all` (matches every
/// window — the natural "no filter" / degrade value).
public indirect enum FacetFilter: Sendable, Equatable {
    case atom(Atom)
    case and([FacetFilter])
    case or([FacetFilter])
    case not(FacetFilter)
    /// Matches everything — the parse of an empty expression.
    case all

    /// A CSS attribute operator. Raw value is the wire spelling.
    public enum Op: String, Sendable, Equatable, CaseIterable {
        case equals = "="        // exact whole-value match
        case contains = "~="     // whitespace-token contains (tag list)
        case prefix = "^="       // value is a prefix
        case suffix = "$="       // value is a suffix
        case substring = "*="    // value appears anywhere
        case hierarchical = "|=" // exact, or prefix immediately followed by "-"
    }

    /// A single leaf predicate: either a bare presence test on a field,
    /// or a `field op value` comparison.
    public struct Atom: Sendable, Equatable {
        public let field: String
        public let kind: Kind

        public enum Kind: Sendable, Equatable {
            /// Bare field — `tag` / `floating` / … (field is present / truthy).
            case presence
            /// `field op value` with the case-sensitivity flag resolved
            /// (`false` = insensitive, the default).
            case compare(op: Op, value: String, caseSensitive: Bool)
        }

        public init(field: String, kind: Kind) {
            self.field = field
            self.kind = kind
        }
    }

    /// A non-fatal parse failure. `offset` is a 0-based **Character**
    /// index into the input (the column to render a `^` under, not a
    /// UTF-8 byte offset — so carets align under multibyte values);
    /// `offset == input.count` points just past the end (EOF errors).
    public struct ParseError: Error, Sendable, Equatable {
        public let message: String
        public let offset: Int

        public init(message: String, offset: Int) {
            self.message = message
            self.offset = offset
        }

        /// A two-line caret rendering for loud reporting:
        ///
        ///     tag~web
        ///        ^ expected '=' after '~'
        ///
        /// Tabs in the input are normalised to a single space so the
        /// caret column stays aligned in a fixed-width terminal.
        public func caret(in input: String) -> String {
            let line = String(input.map { $0 == "\t" ? " " : $0 })
            let pad = String(repeating: " ", count: max(0, offset))
            return "\(line)\n\(pad)^ \(message)"
        }
    }

    /// Parse `input` into a `FacetFilter`. Total: never throws, never
    /// crashes — returns `.failure(ParseError)` for malformed input so
    /// the caller can log the caret and degrade to show-all.
    public static func parse(_ input: String) -> Result<FacetFilter, ParseError> {
        do {
            let tokens = try Lexer.tokenize(input)
            if tokens.isEmpty { return .success(.all) }
            var parser = Parser(tokens: tokens, end: input.count)
            let expr = try parser.parseOr()
            if let extra = parser.peek() {
                throw ParseError(message: Self.unexpected(extra),
                                 offset: extra.offset)
            }
            return .success(expr)
        } catch let e as ParseError {
            return .failure(e)
        } catch {
            // Lexer/Parser only ever throw ParseError; this is unreachable.
            return .failure(ParseError(message: "\(error)", offset: 0))
        }
    }

    /// The lowercase boolean keywords. Reserved: they can never be field
    /// names (and no facet field is so named). In *value* position
    /// (`tag=and`) or quoted they are ordinary literals.
    static let keywords: Set<String> = ["and", "or", "not"]

    /// A helpful message for an out-of-place token, with a typo hint when
    /// it looks like a miscased keyword (`OR` → "did you mean 'or'?").
    static func unexpected(_ t: Token) -> String {
        if case .word(let w, _) = t {
            let lower = w.lowercased()
            if keywords.contains(lower) && w != lower {
                return "unexpected '\(w)' — did you mean '\(lower)'? (boolean keywords are lowercase)"
            }
            if keywords.contains(w) {
                return "unexpected keyword '\(w)'"
            }
            return "unexpected '\(w)'"
        }
        return "unexpected token"
    }
}

// MARK: - Rendering (the inverse of `parse`, #284 PR#4)

extension FacetFilter: CustomStringConvertible {
    /// The canonical `facet filter` source for this AST — the inverse of
    /// `parse`. Round-trips for every filter built from clean field/value
    /// tokens: `parse(f.description)` yields a structurally-flattened `f`
    /// (a value containing a `"` cannot round-trip — the grammar has no
    /// quote escape, the same limitation the lexer documents; nor can the
    /// match-nothing `.not(.all)`, which renders as a bare `not`). `.all`
    /// renders as the empty string (which parses back to `.all`), and a
    /// precedence-lowering child is parenthesised (`not` / `and` wrapping
    /// an `or`, etc.) so the printed form re-parses to the same tree.
    public var description: String { render(parentPrecedence: 0) }

    // Precedence ranks for parenthesisation: or = 1 (loosest) < and = 2 <
    // not = 3. `parentPrecedence` is the rank of the enclosing operator; a
    // node wraps itself in `()` when the parent binds tighter than it does.
    private func render(parentPrecedence: Int) -> String {
        switch self {
        case .all:
            return ""
        case .atom(let a):
            return a.description
        case .not(let f):
            // `not` binds tighter than `and`/`or`, so it never needs its
            // own wrap; its operand does when it is looser (an `and`/`or`).
            return "not " + f.render(parentPrecedence: 3)
        case .and(let parts):
            let s = parts.map { $0.render(parentPrecedence: 2) }
                         .joined(separator: " and ")
            return parentPrecedence > 2 ? "(\(s))" : s
        case .or(let parts):
            let s = parts.map { $0.render(parentPrecedence: 1) }
                         .joined(separator: " or ")
            return parentPrecedence > 1 ? "(\(s))" : s
        }
    }
}

extension FacetFilter.Atom: CustomStringConvertible {
    public var description: String {
        switch kind {
        case .presence:
            return field
        case .compare(let op, let value, let caseSensitive):
            return "\(field)\(op.rawValue)\(Self.quote(value))\(caseSensitive ? " s" : "")"
        }
    }

    /// Quote a value only when a bareword would mis-lex it: empty, or
    /// carrying whitespace, a paren, a quote, or an operator-lead char
    /// (`= ~ ^ $ * |`). Inside quotes those are literal (the lexer's rule).
    static func quote(_ v: String) -> String {
        let needsQuote = v.isEmpty
            || v.contains(where: { $0.isWhitespace })
            || v.contains(where: { $0 == "(" || $0 == ")" || $0 == "\"" })
            || v.contains(where: { operatorLeads.contains($0) })
        return needsQuote ? "\"\(v)\"" : v
    }
}

// MARK: - Evaluation (#283 PR#2)

/// A window's facet-filter-visible fields, keyed by canonical field name.
/// The evaluator (`FacetFilter.matches`) reads windows only through this
/// protocol, so the two real window types — `Window` (in-process views)
/// and `WindowQueryEntry` (the `facet query` path) — conform directly and
/// no third "facts" type is introduced.
public protocol WindowFields {
    /// The scalar string value of `field`, or `nil` when the field is
    /// absent / not carried by this window. The multi-value `tag` field
    /// is the whitespace-joined tag list (so `~=` is token membership);
    /// boolean flags are `"true"` / `"false"`.
    func filterValue(_ field: String) -> String?
    /// Whether `field` is present / truthy: a boolean flag → its value, a
    /// string field → non-empty, `tag` → non-empty list, unknown → false.
    /// Drives the bare-presence atom (`tag` / `floating` / `not tag`).
    func filterHas(_ field: String) -> Bool
}

public extension FacetFilter {
    /// The canonical, resolvable filter fields — the field-name table that
    /// every `WindowFields` conformer (`Window`, `WindowQueryEntry`,
    /// `ApplyPlanWindowFields`) maps to its own backing storage. The
    /// `rawValue` is the wire spelling used in `facet filter` source.
    ///
    /// This enum is the SINGLE source of those names: add a field here once
    /// and `knownFields` derives from it, so the name catalogue can never
    /// drift out of sync with itself. (The conformers' `switch` statements
    /// still map each name to a *different* property per window type —
    /// `app` → `appName` on `Window` but → `app` on `WindowQueryEntry` — so
    /// they stay hand-written; only the name catalogue is unified here. A
    /// new case is exhaustively visible to a future maintainer adding it to
    /// each `switch`.)
    enum FilterField: String, CaseIterable, Sendable {
        case app, title, bundleId, workspace, tag
        case floating, sticky, master, mark, scratchpad
        case desktop, onscreen, focused
    }

    /// The frozen set of canonical field names the evaluator resolves
    /// (the field-name table that `WindowFields` conformers implement). A
    /// referenced field outside this set is a typo: it resolves to a
    /// no-match, and callers surface a loud-but-NON-FATAL warning by
    /// diffing `fieldsReferenced()` against this set. Derived from
    /// `FilterField` so the catalogue has exactly one definition.
    static let knownFields: Set<String> = Set(FilterField.allCases.map(\.rawValue))

    /// Every field name referenced by an atom in this expression — for
    /// the caller's typo check against `knownFields`.
    func fieldsReferenced() -> Set<String> {
        switch self {
        case .all: return []
        case .atom(let a): return [a.field]
        case .not(let f): return f.fieldsReferenced()
        case .and(let parts), .or(let parts):
            return parts.reduce(into: Set()) { $0.formUnion($1.fieldsReferenced()) }
        }
    }

    /// Evaluate the filter against a window. Pure and total: an unknown
    /// or absent field is a no-match (never a crash). Matching is
    /// case-insensitive unless the atom carried the ` s` flag.
    func matches(_ window: some WindowFields) -> Bool {
        switch self {
        case .all: return true
        case .atom(let a): return a.matches(window)
        case .not(let f): return !f.matches(window)
        case .and(let parts): return parts.allSatisfy { $0.matches(window) }
        case .or(let parts): return parts.contains { $0.matches(window) }
        }
    }
}

/// t-0020: the outcome of vetting a `facet section --match` predicate for the
/// live editor (and any CLI live-check). It mirrors `FilterProjection.project`'s
/// own handling exactly, so the editor's feedback matches what the projection
/// will actually do:
///   • `.ok` — parses AND every field is known (an empty predicate parses to
///     `.all`, so it is `.ok` too — the revert gesture).
///   • `.unknownField` — parses, but references field name(s) outside
///     `knownFields`. The predicate is VALID and commits, but matches nothing
///     (same as a config lens `match = "abc"`) — a NON-fatal warning, not an
///     error. Fields are sorted for a stable message.
///   • `.malformed` — a genuine SYNTAX error (the `ParseError`, so the caller
///     renders either its `.message` inline or its `.caret(in:)` for the CLI).
public enum MatchPredicateStatus: Equatable, Sendable {
    case ok
    case unknownField([String])
    case malformed(FacetFilter.ParseError)
}

/// Classify a `facet section --match` predicate — pure, so the GUI validator and
/// tests share the SAME verdict the projection acts on. Malformed SYNTAX is a
/// hard error; an unknown FIELD is soft (valid-but-matches-nothing), matching
/// facet's filter philosophy.
public func classifyMatchPredicate(_ predicate: String) -> MatchPredicateStatus {
    switch FacetFilter.parse(predicate) {
    case .failure(let error):
        return .malformed(error)
    case .success(let filter):
        let unknown = filter.fieldsReferenced()
            .subtracting(FacetFilter.knownFields).sorted()
        return unknown.isEmpty ? .ok : .unknownField(unknown)
    }
}

extension FacetFilter.Atom {
    func matches(_ window: some WindowFields) -> Bool {
        switch kind {
        case .presence:
            return window.filterHas(field)
        case .compare(let op, let value, let caseSensitive):
            guard let fieldValue = window.filterValue(field) else { return false }
            return op.evaluate(fieldValue: fieldValue, value: value,
                               caseSensitive: caseSensitive)
        }
    }
}

extension FacetFilter.Op {
    /// Apply this CSS attribute operator. Empty-value `^=` / `$=` / `*=`
    /// match nothing (per the CSS spec); `~=` is whitespace-token
    /// membership (the natural `tag` semantic).
    func evaluate(fieldValue: String, value: String, caseSensitive: Bool) -> Bool {
        let a = caseSensitive ? fieldValue : fieldValue.lowercased()
        let b = caseSensitive ? value : value.lowercased()
        switch self {
        case .equals:
            return a == b
        case .contains:
            return a.split(whereSeparator: { $0.isWhitespace })
                    .contains { $0 == Substring(b) }
        case .prefix:
            return b.isEmpty ? false : a.hasPrefix(b)
        case .suffix:
            return b.isEmpty ? false : a.hasSuffix(b)
        case .substring:
            return b.isEmpty ? false : a.contains(b)
        case .hierarchical:
            return a == b || a.hasPrefix(b + "-")
        }
    }
}

// MARK: - Lexer

/// One lexical token, carrying its 0-based Character offset for errors.
enum Token: Sendable, Equatable {
    case word(String, offset: Int)     // bareword (field name, value, or keyword)
    case string(String, offset: Int)   // quoted value, quotes stripped
    case op(FacetFilter.Op, offset: Int)
    case lparen(offset: Int)
    case rparen(offset: Int)

    var offset: Int {
        switch self {
        case .word(_, let o), .string(_, let o), .op(_, let o),
             .lparen(let o), .rparen(let o):
            return o
        }
    }
}

/// Characters that start an operator (`=` plus the five `X=` leads). They
/// also terminate a bareword, so a value containing them must be quoted.
private let operatorLeads: Set<Character> = ["=", "~", "^", "$", "*", "|"]

private enum Lexer {
    static func tokenize(_ input: String) throws -> [Token] {
        let chars = Array(input)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            switch c {
            case "(":
                tokens.append(.lparen(offset: i)); i += 1
            case ")":
                tokens.append(.rparen(offset: i)); i += 1
            case "\"":
                let start = i
                i += 1
                var value = ""
                var closed = false
                while i < chars.count {
                    if chars[i] == "\"" { closed = true; i += 1; break }
                    value.append(chars[i]); i += 1
                }
                guard closed else {
                    throw FacetFilter.ParseError(
                        message: "unterminated quoted value", offset: start)
                }
                tokens.append(.string(value, offset: start))
            case "=":
                tokens.append(.op(.equals, offset: i)); i += 1
            case "~", "^", "$", "*", "|":
                let start = i
                guard i + 1 < chars.count, chars[i + 1] == "=" else {
                    throw FacetFilter.ParseError(
                        message: "expected '=' after '\(c)'", offset: start)
                }
                let op: FacetFilter.Op
                switch c {
                case "~": op = .contains
                case "^": op = .prefix
                case "$": op = .suffix
                case "*": op = .substring
                default:  op = .hierarchical   // "|"
                }
                tokens.append(.op(op, offset: start)); i += 2
            default:
                // Bareword: run until whitespace, a paren, a quote, or an
                // operator lead.
                let start = i
                var word = ""
                while i < chars.count {
                    let ch = chars[i]
                    if ch.isWhitespace || ch == "(" || ch == ")"
                        || ch == "\"" || operatorLeads.contains(ch) { break }
                    word.append(ch); i += 1
                }
                tokens.append(.word(word, offset: start))
            }
        }
        return tokens
    }
}

// MARK: - Parser (recursive descent; precedence not > and > or)

private struct Parser {
    let tokens: [Token]
    /// Offset just past the last input character — used for EOF errors.
    let end: Int
    var pos = 0

    func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

    /// The offset to point a caret at when the current token is missing
    /// (EOF) — just past the end of the input.
    func eofOffset() -> Int { end }

    mutating func advance() { pos += 1 }

    /// Is the current token the lowercase keyword `kw`?
    func isKeyword(_ kw: String) -> Bool {
        if case .word(let w, _) = peek(), w == kw { return true }
        return false
    }

    mutating func parseOr() throws -> FacetFilter {
        var parts = [try parseAnd()]
        while isKeyword("or") {
            advance()
            parts.append(try parseAnd())
        }
        return parts.count == 1 ? parts[0] : .or(parts)
    }

    mutating func parseAnd() throws -> FacetFilter {
        var parts = [try parseNot()]
        while isKeyword("and") {
            advance()
            parts.append(try parseNot())
        }
        return parts.count == 1 ? parts[0] : .and(parts)
    }

    mutating func parseNot() throws -> FacetFilter {
        if isKeyword("not") {
            advance()
            return .not(try parseNot())
        }
        return try parsePrimary()
    }

    mutating func parsePrimary() throws -> FacetFilter {
        if case .lparen = peek() {
            advance()
            let inner = try parseOr()
            guard case .rparen = peek() else {
                throw FacetFilter.ParseError(
                    message: "expected ')'",
                    offset: peek()?.offset ?? eofOffset())
            }
            advance()
            return inner
        }
        return .atom(try parseAtom())
    }

    mutating func parseAtom() throws -> FacetFilter.Atom {
        guard case .word(let field, let off) = peek() else {
            throw FacetFilter.ParseError(
                message: peek().map { "expected a field name, found \(FacetFilter.unexpected($0))" }
                    ?? "expected a field name",
                offset: peek()?.offset ?? eofOffset())
        }
        // `not` is intercepted by parseNot; a leftover `and`/`or` here is
        // a connective with no left-hand expression.
        if FacetFilter.keywords.contains(field.lowercased()) {
            throw FacetFilter.ParseError(
                message: FacetFilter.unexpected(.word(field, offset: off)),
                offset: off)
        }
        advance()

        guard case .op(let op, _) = peek() else {
            // Bare field → presence test.
            return FacetFilter.Atom(field: field, kind: .presence)
        }
        advance()

        // Value: a bareword or a quoted string.
        let value: String
        switch peek() {
        case .word(let w, _): value = w; advance()
        case .string(let s, _): value = s; advance()
        default:
            throw FacetFilter.ParseError(
                message: "expected a value after '\(op.rawValue)'",
                offset: peek()?.offset ?? eofOffset())
        }

        // Optional trailing case-sensitivity flag `s` (bracket-free CSS
        // flag). Implicit-AND is illegal, so a bare `s` after a value can
        // only be the flag; any other bare word here is a parse error
        // (handled by the trailing-token check back in `parse`).
        var caseSensitive = false
        if case .word("s", _) = peek() {
            advance()
            caseSensitive = true
        }
        return FacetFilter.Atom(
            field: field,
            kind: .compare(op: op, value: value, caseSensitive: caseSensitive))
    }
}
