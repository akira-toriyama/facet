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
}
