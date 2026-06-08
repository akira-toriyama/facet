import XCTest
import ApplicationServices
@testable import FacetAccessibility

/// Pure tests for `AXGeom.isFloating(role:subrole:)` — the role/subrole
/// decision split out of `isFloatingByRole` so the auto-float rule can
/// be verified without a live `AXUIElement`. The six floating constants
/// are the ones the source matches; everything else (incl. nil) tiles.
final class AXFloatingRoleTests: XCTestCase {

    func testSheetAndDrawerRolesFloat() {
        XCTAssertTrue(AXGeom.isFloating(role: kAXSheetRole as String,
                                        subrole: nil))
        XCTAssertTrue(AXGeom.isFloating(role: kAXDrawerRole as String,
                                        subrole: nil))
    }

    func testFloatingSubrolesFloat() {
        for sub in [kAXFloatingWindowSubrole as String,
                    kAXSystemDialogSubrole as String,
                    kAXSystemFloatingWindowSubrole as String,
                    kAXDialogSubrole as String] {
            XCTAssertTrue(AXGeom.isFloating(role: nil, subrole: sub),
                          "subrole \(sub) should float")
        }
    }

    func testStandardWindowDoesNotFloat() {
        // A normal tiled window: role "AXWindow", subrole
        // "AXStandardWindow" — neither is in the floating set.
        XCTAssertFalse(AXGeom.isFloating(role: "AXWindow",
                                         subrole: "AXStandardWindow"))
    }

    func testNilRoleAndSubroleDoesNotFloat() {
        XCTAssertFalse(AXGeom.isFloating(role: nil, subrole: nil))
    }

    func testUnknownStringsDoNotFloat() {
        XCTAssertFalse(AXGeom.isFloating(role: "AXSomethingElse",
                                         subrole: "AXWeirdSubrole"))
    }
}
