import XCTest
@testable import FacetCore

/// `CLIName` — the shared name-policy core for mark / scratchpad /
/// workspace names (#227). Tags layer extra rules on top (see TagName).
final class CLINameTests: XCTestCase {

    func testIsCleanAcceptsOrdinaryNames() {
        XCTAssertTrue(CLIName.isClean("a"))
        XCTAssertTrue(CLIName.isClean("editor"))
        XCTAssertTrue(CLIName.isClean("my-shelf"))    // inner dash OK
        XCTAssertTrue(CLIName.isClean("_x"))          // leading _ is NOT a CLIName concern
        XCTAssertTrue(CLIName.isClean("1.5"))
        XCTAssertTrue(CLIName.isClean("#a"))          // # not stripped here
    }

    func testIsCleanRejectsShapeViolations() {
        XCTAssertFalse(CLIName.isClean(""))
        XCTAssertFalse(CLIName.isClean("-foo"))       // leading dash → flag-like
        XCTAssertFalse(CLIName.isClean("a b"))        // internal space
        XCTAssertFalse(CLIName.isClean("a\tb"))
        XCTAssertFalse(CLIName.isClean("a:b"))        // DNC delimiter
        XCTAssertFalse(CLIName.isClean("a,b"))
        XCTAssertFalse(CLIName.isClean("a=b"))
    }

    func testSanitizedTrimsThenValidates() {
        XCTAssertEqual(CLIName.sanitized("  editor "), "editor")
        XCTAssertEqual(CLIName.sanitized("a"), "a")
        XCTAssertNil(CLIName.sanitized("   "))
        XCTAssertNil(CLIName.sanitized("-foo"))
        XCTAssertNil(CLIName.sanitized("a:b"))
    }
}
