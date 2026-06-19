import XCTest
@testable import FacetCore

/// `ArgCursor` — the pure argv cursor backing the space-separated CLI
/// grammar (#227). Strict consumption: `next()` returns whatever the
/// next token is, including a `--`-looking one (validators decide).
final class ArgCursorTests: XCTestCase {

    func testNextConsumesInOrderThenNil() {
        var c = ArgCursor(["--view", "tree", "--toggle"])
        XCTAssertEqual(c.next(), "--view")
        XCTAssertEqual(c.next(), "tree")
        XCTAssertEqual(c.next(), "--toggle")
        XCTAssertNil(c.next())
        XCTAssertNil(c.next())          // idempotent at end
    }

    func testPeekDoesNotConsume() {
        var c = ArgCursor(["a", "b"])
        XCTAssertEqual(c.peek(), "a")
        XCTAssertEqual(c.peek(), "a")   // still there
        XCTAssertEqual(c.next(), "a")
        XCTAssertEqual(c.peek(), "b")
    }

    func testIsAtEnd() {
        var c = ArgCursor(["x"])
        XCTAssertFalse(c.isAtEnd)
        _ = c.next()
        XCTAssertTrue(c.isAtEnd)
        XCTAssertNil(c.peek())
    }

    func testEmpty() {
        var c = ArgCursor([])
        XCTAssertTrue(c.isAtEnd)
        XCTAssertNil(c.next())
        XCTAssertNil(c.peek())
    }

    /// Strict consumption: a negative number or a flag-looking token is
    /// returned verbatim — the cursor never reinterprets it.
    func testReturnsFlagLikeAndNegativeTokensVerbatim() {
        var c = ArgCursor(["--pos-x", "-1440", "--rename", "--add"])
        XCTAssertEqual(c.next(), "--pos-x")
        XCTAssertEqual(c.next(), "-1440")   // consumed as a value
        XCTAssertEqual(c.next(), "--rename")
        XCTAssertEqual(c.next(), "--add")   // consumed as a value, not a flag
    }
}
