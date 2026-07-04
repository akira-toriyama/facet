import Testing
import ApplicationServices
@testable import FacetAccessibility

/// Pure tests for `AXGeom.isFloating(role:subrole:)` — the role/subrole
/// decision split out of `isFloatingByRole` so the auto-float rule can
/// be verified without a live `AXUIElement`. The six floating constants
/// are the ones the source matches; everything else (incl. nil) tiles.
struct AXFloatingRoleTests {

    @Test("floats iff role/subrole matches a floating constant", arguments: [
        // The floating constants the source matches: two roles…
        (role: kAXSheetRole as String, subrole: nil, expected: true),
        (role: kAXDrawerRole as String, subrole: nil, expected: true),
        // …and four subroles.
        (role: nil, subrole: kAXFloatingWindowSubrole as String, expected: true),
        (role: nil, subrole: kAXSystemDialogSubrole as String, expected: true),
        (role: nil, subrole: kAXSystemFloatingWindowSubrole as String, expected: true),
        (role: nil, subrole: kAXDialogSubrole as String, expected: true),
        // A normal tiled window: role "AXWindow", subrole
        // "AXStandardWindow" — neither is in the floating set.
        (role: "AXWindow", subrole: "AXStandardWindow", expected: false),
        (role: nil, subrole: nil, expected: false),
        (role: "AXSomethingElse", subrole: "AXWeirdSubrole", expected: false),
    ] as [(role: String?, subrole: String?, expected: Bool)])
    func isFloating(role: String?, subrole: String?, expected: Bool) {
        #expect(AXGeom.isFloating(role: role, subrole: subrole) == expected)
    }
}
