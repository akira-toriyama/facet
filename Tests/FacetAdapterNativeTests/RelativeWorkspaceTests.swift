import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for relative workspace targeting (Theme C-2):
/// `previousActiveIndex` tracking + `relativeTarget` resolution.
final class RelativeWorkspaceTests: XCTestCase {

    private let configured = [1, 2, 3]

    // MARK: - previousActiveIndex

    func testPreviousActiveStartsNil() {
        XCTAssertNil(WorkspaceCatalog().previousActiveIndex)
    }

    func testSetActiveRecordsPrevious() {
        var c = WorkspaceCatalog()
        _ = c.setActive(2, configuredIndexes: configured)
        XCTAssertEqual(c.previousActiveIndex, 1)
        _ = c.setActive(3, configuredIndexes: configured)
        XCTAssertEqual(c.previousActiveIndex, 2)
    }

    func testNoopSwitchKeepsPrevious() {
        var c = WorkspaceCatalog()
        _ = c.setActive(2, configuredIndexes: configured)   // prev = 1
        _ = c.setActive(2, configuredIndexes: configured)   // no-op
        XCTAssertEqual(c.previousActiveIndex, 1,
                       "a no-op switch must not overwrite recent")
    }

    // MARK: - relativeTarget: next / prev (wrap)

    func testNextWraps() {
        var c = WorkspaceCatalog()                          // active 1
        XCTAssertEqual(c.relativeTarget(.next, configured: configured), 2)
        _ = c.setActive(3, configuredIndexes: configured)
        XCTAssertEqual(c.relativeTarget(.next, configured: configured), 1)
    }

    func testPrevWraps() {
        var c = WorkspaceCatalog()                          // active 1
        XCTAssertEqual(c.relativeTarget(.prev, configured: configured), 3)
        _ = c.setActive(2, configuredIndexes: configured)
        XCTAssertEqual(c.relativeTarget(.prev, configured: configured), 1)
    }

    func testNextPrevNoopWithSingleWorkspace() {
        let c = WorkspaceCatalog()
        XCTAssertNil(c.relativeTarget(.next, configured: [1]))
        XCTAssertNil(c.relativeTarget(.prev, configured: [1]))
    }

    func testNextPrevHandleSparseConfigured() {
        // Non-contiguous slots (1, 3, 5) still cycle in list order.
        var c = WorkspaceCatalog()
        _ = c.setActive(3, configuredIndexes: [1, 3, 5])
        XCTAssertEqual(c.relativeTarget(.next, configured: [1, 3, 5]), 5)
        XCTAssertEqual(c.relativeTarget(.prev, configured: [1, 3, 5]), 1)
    }

    // MARK: - relativeTarget: recent

    func testRecentNilBeforeAnySwitch() {
        XCTAssertNil(WorkspaceCatalog()
            .relativeTarget(.recent, configured: configured))
    }

    func testRecentReturnsPreviousActive() {
        var c = WorkspaceCatalog()
        _ = c.setActive(3, configuredIndexes: configured)   // prev = 1
        XCTAssertEqual(c.relativeTarget(.recent, configured: configured), 1)
    }

    func testRecentNilWhenPreviousNoLongerConfigured() {
        var c = WorkspaceCatalog()
        _ = c.setActive(2, configuredIndexes: [1, 2, 3])    // prev = 1
        XCTAssertNil(c.relativeTarget(.recent, configured: [2, 3]),
                     "recent must be dropped if it left the config")
    }
}
