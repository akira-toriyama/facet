import XCTest
@testable import FacetCore

final class GroupingTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(Grouping(rawValue: "workspace"), .workspace)
        XCTAssertEqual(Grouping(rawValue: "tag"), .tag)
        XCTAssertNil(Grouping(rawValue: "spaces"))
        XCTAssertEqual(Set(Grouping.allCases), [.workspace, .tag])
    }

    func testStatelessEnginesSupportBothGroupings() {
        for mode in ["master-left", "master-right", "master-top",
                     "master-bottom", "master-center", "grid", "spiral"] {
            XCTAssertEqual(LayoutGrouping.supported(forMode: mode),
                           [.workspace, .tag], "mode=\(mode)")
        }
    }

    func testBspAndStackAreWorkspaceOnly() {
        XCTAssertEqual(LayoutGrouping.supported(forMode: "bsp"), [.workspace])
        XCTAssertEqual(LayoutGrouping.supported(forMode: "stack"), [.workspace])
        XCTAssertFalse(LayoutGrouping.isCompatible(mode: "bsp", with: .tag))
        XCTAssertFalse(LayoutGrouping.isCompatible(mode: "stack", with: .tag))
        XCTAssertTrue(LayoutGrouping.isCompatible(mode: "bsp",
                                                  with: .workspace))
    }

    func testFloatSupportsBoth() {
        XCTAssertEqual(LayoutGrouping.supported(forMode: "float"),
                       [.workspace, .tag])
        XCTAssertTrue(LayoutGrouping.isCompatible(mode: "float", with: .tag))
    }

    func testUnknownModeSupportsNothing() {
        XCTAssertEqual(LayoutGrouping.supported(forMode: "bogus"), [])
        XCTAssertFalse(LayoutGrouping.isCompatible(mode: "bogus",
                                                   with: .workspace))
    }

    func testCaseInsensitive() {
        XCTAssertEqual(LayoutGrouping.supported(forMode: "BSP"), [.workspace])
        XCTAssertEqual(LayoutGrouping.supported(forMode: "Grid"),
                       [.workspace, .tag])
    }
}
