import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Per-WS master-orientation state (Tall ↔ Wide) in the catalog. The
/// geometry itself is covered by `WideLayoutTests`; here we check the
/// state plumbing.
final class MasterOrientationTests: XCTestCase {

    func testDefaultOrientationIsVertical() {
        let c = WorkspaceCatalog()
        XCTAssertEqual(c.params(of: 1).orientation, .vertical)
    }

    func testToggleFlipsAndPersists() {
        var c = WorkspaceCatalog()
        XCTAssertTrue(c.toggleMasterOrientation(workspace: 1))
        XCTAssertEqual(c.params(of: 1).orientation, .horizontal)
        XCTAssertTrue(c.toggleMasterOrientation(workspace: 1))
        XCTAssertEqual(c.params(of: 1).orientation, .vertical)
    }

    func testRatioAdjustPreservesOrientation() {
        var c = WorkspaceCatalog()
        _ = c.toggleMasterOrientation(workspace: 1)        // → horizontal
        _ = c.adjustMasterRatio(workspace: 1, delta: 0.1)
        XCTAssertEqual(c.params(of: 1).orientation, .horizontal,
                       "adjusting the ratio must not reset orientation")
        XCTAssertEqual(c.params(of: 1).masterRatio, 0.6, accuracy: 1e-9)
    }

    func testCountAdjustPreservesOrientation() {
        var c = WorkspaceCatalog()
        _ = c.toggleMasterOrientation(workspace: 1)        // → horizontal
        _ = c.adjustMasterCount(workspace: 1, delta: 1)
        XCTAssertEqual(c.params(of: 1).orientation, .horizontal)
        XCTAssertEqual(c.params(of: 1).masterCount, 2)
    }

    func testOrientationIsPerWorkspace() {
        var c = WorkspaceCatalog()
        _ = c.toggleMasterOrientation(workspace: 1)
        XCTAssertEqual(c.params(of: 1).orientation, .horizontal)
        XCTAssertEqual(c.params(of: 2).orientation, .vertical,
                       "flipping WS 1 must not touch WS 2")
    }
}
