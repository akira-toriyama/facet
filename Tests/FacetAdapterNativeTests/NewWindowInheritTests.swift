import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// EX-3.3 — new-window apply inheritance: `activeSectionLensApplyForward()`
/// resolves the active section-lens's FORWARD `apply` ops — everything the
/// section's `apply` carries EXCEPT `setWorkspace` (stripped so the new window
/// keeps `workspace = activeIndex`) — so a window launched while the lens is
/// active joins it in the SAME facet state as one dragged in (canon ④⑨,
/// "必ず見える"). The full adoption path runs through `refreshCatalog`
/// (AX/CGWindowList — host-verified, not CI); these pin the pure resolver the
/// inheritance reads. `NativeAdapter(config:)` only does read-only SkyLight
/// reads in init; the ordinal is forced to 1 for determinism.
final class NewWindowInheritTests: XCTestCase {

    private func adapter(_ sections: [DesktopSection]) -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [1: sections]
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        return a
    }

    func testApplyForwardReturnsApplyOpsOfActiveLens() {
        let a = adapter([DesktopSection(type: .lens, label: "Web",
                                        match: "tag~=web", apply: [.addTag("web")])])
        a.catalog.activeSectionLens = "Web"
        XCTAssertEqual(a.activeSectionLensApplyForward(), [.addTag("web")])
    }

    func testApplyForwardIncludesFloatingSticky() {
        // C1: the full forward set is inherited (not just addTag) so a window
        // auto-joining the lens lands in the same facet state as a DnD into it.
        let a = adapter([DesktopSection(
            type: .lens, label: "Multi", match: "tag~=a",
            apply: [.addTag("a"), .addTag("b"), .setFloating(true), .setSticky(true)])])
        a.catalog.activeSectionLens = "Multi"
        XCTAssertEqual(
            a.activeSectionLensApplyForward(),
            [.addTag("a"), .addTag("b"), .setFloating(true), .setSticky(true)],
            "the full forward apply set is inherited (tags + floating/sticky/master)")
    }

    func testApplyForwardStripsSetWorkspace() {
        // setWorkspace is the ONE op stripped — a new window keeps
        // `workspace = activeIndex` (D-A: never an orphan-on-birth). Mirrors the
        // DnD forward filter (`ApplyResolver` strips setWorkspace identically).
        let a = adapter([DesktopSection(
            type: .lens, label: "Routed", match: "tag~=r",
            apply: [.setWorkspace("Other"), .addTag("r"), .setFloating(true)])])
        a.catalog.activeSectionLens = "Routed"
        XCTAssertEqual(
            a.activeSectionLensApplyForward(),
            [.addTag("r"), .setFloating(true)],
            "setWorkspace is dropped; the remaining forward ops pass through in order")
    }

    func testApplyForwardEmptyForPureConditionLens() {
        // A lens that matches on a window property with NO apply — a new window
        // can't be made to match it (declared gap).
        let a = adapter([DesktopSection(type: .lens, label: "Chrome",
                                        match: "app=Chrome")])
        a.catalog.activeSectionLens = "Chrome"
        XCTAssertEqual(a.activeSectionLensApplyForward(), [])
    }

    func testApplyForwardEmptyWhenNoLensActive() {
        let a = adapter([DesktopSection(type: .lens, label: "Web",
                                        match: "tag~=web", apply: [.addTag("web")])])
        // activeSectionLens is nil → no inheritance.
        XCTAssertEqual(a.activeSectionLensApplyForward(), [])
    }

    /// The enabling fix: `sectionLensVisibleIDsAll` overlays the catalog's tag
    /// names onto the live (tag-less) window so a `tag~=X` lens GATHERS by the
    /// assigned tag — the data path EX-3.3 (inherit) + EX-3.5 (DnD) rely on.
    /// Without the overlay a tagged window would show in the tree but never be
    /// physically gathered/parked.
    func testTagBasedLensGathersByCatalogTag() {
        let a = adapter([DesktopSection(type: .lens, label: "Web",
                                        match: "tag~=web", apply: [.addTag("web")])])
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        let w10 = window(10, appName: "Chrome")
        let w20 = window(20, appName: "Safari")
        a.catalog.reconcile(live: [w10, w20])
        a.catalog.activeSectionLens = "Web"
        // Untagged: nothing matches `tag~=web`.
        XCTAssertEqual(a.sectionLensVisibleIDsAll(live: [w10, w20]) ?? [], [],
                       "no window carries the web tag yet")
        // Assign the tag (as a DnD apply / new-window inherit would).
        _ = a.catalog.addTagToWindow(wid(10), name: "web")
        // The overlay lets the gather see the catalog tag → w10 is included.
        XCTAssertEqual(a.sectionLensVisibleIDsAll(live: [w10, w20]) ?? [], [wid(10)],
                       "the tagged window is gathered by the catalog tag overlay")
    }
}
