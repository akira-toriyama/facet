import XCTest
import CoreGraphics
@testable import FacetCore

final class OverviewModelsTests: XCTestCase {
    private func cell(_ type: SectionType, id: String) -> OverviewCell {
        OverviewCell(wsIndex: -1, rect: .zero, headerRect: .zero,
                     isActive: false, label: "L", mode: "", windows: [],
                     sectionType: type, sectionID: id)
    }

    func testDefaultsAreWorkspaceKind() {
        // The legacy 8-arg call site (no sectionType/sectionID) must still
        // compile + default to the workspace kind.
        let c = OverviewCell(wsIndex: 0, rect: .zero, headerRect: .zero,
                             isActive: true, label: "W", mode: "bsp", windows: [])
        XCTAssertEqual(c.sectionType, .workspace)
        XCTAssertEqual(c.sectionID, "")
        XCTAssertFalse(c.isLens)
    }

    func testLensKindFlag() {
        let l = cell(.lens, id: "section:1:Web")
        XCTAssertTrue(l.isLens)
        XCTAssertEqual(l.sectionID, "section:1:Web")
        XCTAssertEqual(l.sectionType, .lens)
    }

    func testWorkspaceKindIsNotLens() {
        XCTAssertFalse(cell(.workspace, id: "ws:0").isLens)
    }
}
