import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for relative workspace targeting (Theme C-2):
/// `previousActiveIndex` tracking + `relativeTarget` resolution over
/// the catalog's live (contiguous) workspace set.
final class RelativeWorkspaceTests: XCTestCase {

    /// Catalog seeded with `n` contiguous, unnamed workspaces.
    private func seeded(_ n: Int) -> WorkspaceCatalog {
        var c = WorkspaceCatalog()
        c.seed(names: (1...n).map { (index: $0, name: "") })
        return c
    }

    // MARK: - previousActiveIndex

    func testPreviousActiveStartsNil() {
        XCTAssertNil(WorkspaceCatalog().previousActiveIndex)
    }

    func testSetActiveRecordsPrevious() {
        var c = seeded(3)
        _ = c.setActive(2)
        XCTAssertEqual(c.previousActiveIndex, 1)
        _ = c.setActive(3)
        XCTAssertEqual(c.previousActiveIndex, 2)
    }

    func testNoopSwitchKeepsPrevious() {
        var c = seeded(3)
        _ = c.setActive(2)   // prev = 1
        _ = c.setActive(2)   // no-op
        XCTAssertEqual(c.previousActiveIndex, 1,
                       "a no-op switch must not overwrite recent")
    }

    // MARK: - relativeTarget: next / prev (wrap)

    func testNextWraps() {
        var c = seeded(3)                                   // active 1
        XCTAssertEqual(c.relativeTarget(.next), 2)
        _ = c.setActive(3)
        XCTAssertEqual(c.relativeTarget(.next), 1)
    }

    func testPrevWraps() {
        var c = seeded(3)                                   // active 1
        XCTAssertEqual(c.relativeTarget(.prev), 3)
        _ = c.setActive(2)
        XCTAssertEqual(c.relativeTarget(.prev), 1)
    }

    func testNextPrevNoopWithSingleWorkspace() {
        let c = seeded(1)
        XCTAssertNil(c.relativeTarget(.next))
        XCTAssertNil(c.relativeTarget(.prev))
    }

    // MARK: - relativeTarget: recent

    func testRecentNilBeforeAnySwitch() {
        XCTAssertNil(seeded(3).relativeTarget(.recent))
    }

    func testRecentReturnsPreviousActive() {
        var c = seeded(3)
        _ = c.setActive(3)   // prev = 1
        XCTAssertEqual(c.relativeTarget(.recent), 1)
    }

    func testRecentSurvivesRemoveRemap() {
        // `recent` follows the previous workspace through a remove's
        // index shift rather than being lost.
        var c = seeded(4)
        _ = c.setActive(4)   // active 4, prev 1
        _ = c.removeWorkspace(2)            // positions 3,4 shift to 2,3
        // active 4 -> 3, prev 1 unchanged (below the removed slot).
        XCTAssertEqual(c.activeIndex, 3)
        XCTAssertEqual(c.relativeTarget(.recent), 1)
    }
}
