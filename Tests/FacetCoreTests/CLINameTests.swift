import Testing
@testable import FacetCore

/// `CLIName` — the shared name-policy core for mark / scratchpad /
/// workspace names (#227). Tags layer extra rules on top (see TagName).
struct CLINameTests {

    @Test func isCleanAcceptsOrdinaryNames() {
        #expect(CLIName.isClean("a"))
        #expect(CLIName.isClean("editor"))
        #expect(CLIName.isClean("my-shelf"))    // inner dash OK
        #expect(CLIName.isClean("_x"))          // leading _ is NOT a CLIName concern
        #expect(CLIName.isClean("1.5"))
        #expect(CLIName.isClean("#a"))          // # not stripped here
    }

    @Test func isCleanRejectsShapeViolations() {
        #expect(!(CLIName.isClean("")))
        #expect(!(CLIName.isClean("-foo")))       // leading dash → flag-like
        #expect(!(CLIName.isClean("a b")))        // internal space
        #expect(!(CLIName.isClean("a\tb")))
        #expect(!(CLIName.isClean("a:b")))        // DNC delimiter
        #expect(!(CLIName.isClean("a,b")))
        #expect(!(CLIName.isClean("a=b")))
    }

    @Test func sanitizedTrimsThenValidates() {
        #expect(CLIName.sanitized("  editor ") == "editor")
        #expect(CLIName.sanitized("a") == "a")
        #expect(CLIName.sanitized("   ") == nil)
        #expect(CLIName.sanitized("-foo") == nil)
        #expect(CLIName.sanitized("a:b") == nil)
    }
}
