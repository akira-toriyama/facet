import XCTest
@testable import FacetCore

/// N1 (board review follow-up): a HYBRID config — both `[[desktop.N.section]]`
/// and `[[desktop.N.tab]]` at the SAME ordinal — must not let the flat list
/// leak to flat-list resolvers (notably the native adapter's `lensSection`),
/// which would silently mis-resolve a board-minted `section:<declOrder>:<label>`
/// id to a different flat lens (the EX-0.5 double-SSOT hole). The boards-win
/// rule is made TOTAL: tab configs SHADOW the flat sections at the same ordinal
/// in `effectiveMacDesktopSectionConfigs`, so every flat reader (including the
/// adapter) sees nothing there → it loud-rejects instead of mis-resolving.
/// Pure; CI-only.
final class HybridConfigShadowTests: XCTestCase {

    private func ws(_ label: String) -> DesktopSection {
        DesktopSection(type: .workspace, label: label)
    }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }

    /// An ordinal with boards drops its flat sections from the effective view;
    /// an ordinal without boards keeps them.
    func testTabConfigShadowsFlatSectionsAtSameOrdinal() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [lens("Flat", "app=X")], 2: [ws("Keep")]]
        c.macDesktopTabConfigs = [1: [DesktopTab(type: .workspace,
                                                 sections: [ws("Board")])]]
        XCTAssertNil(c.effectiveMacDesktopSectionConfigs[1],
                     "boards shadow flat sections at the same ordinal (N1)")
        XCTAssertEqual(c.effectiveMacDesktopSectionConfigs[2]?.map(\.label),
                       ["Keep"],
                       "an ordinal without boards keeps its flat sections")
    }

    /// No boards anywhere → the flat dict is returned verbatim (byte-identical
    /// to the pre-N1 accessor).
    func testNoTabsLeavesFlatSectionsUntouched() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [ws("A")], 2: [ws("B")]]
        XCTAssertEqual(c.effectiveMacDesktopSectionConfigs[1]?.map(\.label), ["A"])
        XCTAssertEqual(c.effectiveMacDesktopSectionConfigs[2]?.map(\.label), ["B"])
    }
}
