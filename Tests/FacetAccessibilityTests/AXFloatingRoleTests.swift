import Testing
import ApplicationServices
@testable import FacetAccessibility

/// Pure tests for `AXGeom.isFloating(role:subrole:)` — the role/subrole
/// decision split out of `isFloatingByRole` so the auto-float rule can
/// be verified without a live `AXUIElement`. The six floating constants
/// are the ones the source matches; everything else (incl. nil) tiles.
struct AXFloatingRoleTests {

    @Test func sheetAndDrawerRolesFloat() {
        #expect(AXGeom.isFloating(role: kAXSheetRole as String,
                                  subrole: nil))
        #expect(AXGeom.isFloating(role: kAXDrawerRole as String,
                                  subrole: nil))
    }

    @Test func floatingSubrolesFloat() {
        for sub in [kAXFloatingWindowSubrole as String,
                    kAXSystemDialogSubrole as String,
                    kAXSystemFloatingWindowSubrole as String,
                    kAXDialogSubrole as String] {
            #expect(AXGeom.isFloating(role: nil, subrole: sub),
                    "subrole \(sub) should float")
        }
    }

    @Test func standardWindowDoesNotFloat() {
        // A normal tiled window: role "AXWindow", subrole
        // "AXStandardWindow" — neither is in the floating set.
        #expect(!AXGeom.isFloating(role: "AXWindow",
                                   subrole: "AXStandardWindow"))
    }

    @Test func nilRoleAndSubroleDoesNotFloat() {
        #expect(!AXGeom.isFloating(role: nil, subrole: nil))
    }

    @Test func unknownStringsDoNotFloat() {
        #expect(!AXGeom.isFloating(role: "AXSomethingElse",
                                   subrole: "AXWeirdSubrole"))
    }
}
