import XCTest
@testable import FacetCore

final class LensLayoutTests: XCTestCase {
    func testStatelessRequestPassesThrough() {
        XCTAssertEqual(LensLayout.resolve("spiral", globalDefault: "grid"), "spiral")
        XCTAssertEqual(LensLayout.resolve("master-left", globalDefault: "grid"), "master-left")
    }
    func testStatefulRequestClampsToGlobalDefaultWhenStateless() {
        // bsp is workspace-only (stateful) → not allowed for a lens union.
        XCTAssertEqual(LensLayout.resolve("bsp", globalDefault: "spiral"), "spiral")
    }
    func testStatefulGlobalDefaultClampsToGrid() {
        // Neither request nor global default is a stateless engine → "grid".
        XCTAssertEqual(LensLayout.resolve("stack", globalDefault: "bsp"), "grid")
        XCTAssertEqual(LensLayout.resolve(nil, globalDefault: "float"), "grid")
    }
    func testUnknownRequestClamps() {
        XCTAssertEqual(LensLayout.resolve("nonsense", globalDefault: "grid"), "grid")
    }
    func testNilRequestUsesStatelessGlobalDefault() {
        XCTAssertEqual(LensLayout.resolve(nil, globalDefault: "spiral"), "spiral")
    }

    // MARK: - invariant-pinning + contract tests

    /// The terminal fallback must itself be a stateless engine.  If a future
    /// registry change drops the grid engine, this test fails loudly instead
    /// of leaving silent wrong behaviour.
    func testFallbackIsAlwaysStateless() {
        XCTAssertTrue(LensLayout.isStateless(LensLayout.resolve("nonsense", globalDefault: "bsp")))
    }

    /// resolve is case-insensitive: an upper-case stateless name normalises
    /// to its lower-case canonical form.
    func testCaseInsensitivity() {
        XCTAssertEqual(LensLayout.resolve("SPIRAL", globalDefault: "grid"), "spiral")
    }

    /// A padded request (leading/trailing space) is NOT a valid engine name
    /// and must not match; the fall-through reaches the stateless global
    /// default instead.
    func testPaddedRequestIsNotMatched() {
        XCTAssertEqual(LensLayout.resolve(" grid ", globalDefault: "spiral"), "spiral")
    }
}
