import Testing
@testable import FacetCore

/// `ArgCursor` — the pure argv cursor backing the space-separated CLI
/// grammar (#227). Strict consumption: `next()` returns whatever the
/// next token is, including a `--`-looking one (validators decide).
struct ArgCursorTests {

    @Test func nextConsumesInOrderThenNil() {
        var c = ArgCursor(["--view", "tree", "--toggle"])
        #expect(c.next() == "--view")
        #expect(c.next() == "tree")
        #expect(c.next() == "--toggle")
        #expect(c.next() == nil)
        #expect(c.next() == nil)          // idempotent at end
    }

    @Test func peekDoesNotConsume() {
        var c = ArgCursor(["a", "b"])
        #expect(c.peek() == "a")
        #expect(c.peek() == "a")   // still there
        #expect(c.next() == "a")
        #expect(c.peek() == "b")
    }

    @Test func isAtEnd() {
        var c = ArgCursor(["x"])
        #expect(!(c.isAtEnd))
        _ = c.next()
        #expect(c.isAtEnd)
        #expect(c.peek() == nil)
    }

    @Test func empty() {
        var c = ArgCursor([])
        #expect(c.isAtEnd)
        #expect(c.next() == nil)
        #expect(c.peek() == nil)
    }

    /// Strict consumption: a negative number or a flag-looking token is
    /// returned verbatim — the cursor never reinterprets it.
    @Test func returnsFlagLikeAndNegativeTokensVerbatim() {
        var c = ArgCursor(["--pos-x", "-1440", "--rename", "--add"])
        #expect(c.next() == "--pos-x")
        #expect(c.next() == "-1440")   // consumed as a value
        #expect(c.next() == "--rename")
        #expect(c.next() == "--add")   // consumed as a value, not a flag
    }
}
