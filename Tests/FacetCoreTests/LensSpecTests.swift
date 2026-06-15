import XCTest
@testable import FacetCore

/// `LensSpec.parse` (#228) — the pure `lens:` DNC wire-form parser
/// (`all` / `VERB:CSV`). Extracted from the Controller's dispatch so the
/// verb routing + comma-split is unit-testable without the server.
final class LensSpecTests: XCTestCase {

    func testParseAll() {
        XCTAssertEqual(LensSpec.parse("all"), .all)
    }

    func testParseSingleTagPerVerb() {
        XCTAssertEqual(LensSpec.parse("only:web"), .only(["web"]))
        XCTAssertEqual(LensSpec.parse("add:web"), .add(["web"]))
        XCTAssertEqual(LensSpec.parse("remove:web"), .remove(["web"]))
        XCTAssertEqual(LensSpec.parse("toggle:web"), .toggle(["web"]))
    }

    func testParseCommaJoinedTags() {
        XCTAssertEqual(LensSpec.parse("only:web,code"), .only(["web", "code"]))
        XCTAssertEqual(LensSpec.parse("add:a,b,c"), .add(["a", "b", "c"]))
        XCTAssertEqual(LensSpec.parse("toggle:x,y"), .toggle(["x", "y"]))
    }

    func testParseRejectsMalformed() {
        XCTAssertNil(LensSpec.parse(""))          // empty
        XCTAssertNil(LensSpec.parse("only"))      // no ':' and not "all"
        XCTAssertNil(LensSpec.parse("only:"))     // empty CSV
        XCTAssertNil(LensSpec.parse("bogus:web")) // unknown verb
        XCTAssertNil(LensSpec.parse("only:,"))    // CSV is all empties
    }

    func testParseIsByteIdenticalForSingleTag() {
        // The single-tag wire form must stay what the pre-#228 client
        // posted (`lens:only:web` → `only:web`), so an old chord keeps
        // working. (`postLens` prepends `lens:`; this is the remainder.)
        XCTAssertEqual(LensSpec.parse("only:web"), .only(["web"]))
        XCTAssertEqual(LensSpec.parse("toggle:web"), .toggle(["web"]))
    }
}
