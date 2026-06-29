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
        // A0: the catalog stores the stable id; the single lens is declOrder 0.
        a.catalog.activeSectionLens = "section:0:Web"
        XCTAssertEqual(a.activeSectionLensApplyForward(), [.addTag("web")])
    }

    func testApplyForwardInheritsAllTags() {
        // t-qtpx: a lens `apply` is tags-only, so a window auto-joining the lens
        // inherits every tag the lens applies (the same facet state as a DnD
        // into it), in array order.
        let a = adapter([DesktopSection(
            type: .lens, label: "Multi", match: "tag~=a",
            apply: [.addTag("a"), .addTag("b")])])
        a.catalog.activeSectionLens = "section:0:Multi"
        XCTAssertEqual(
            a.activeSectionLensApplyForward(),
            [.addTag("a"), .addTag("b")],
            "all of the lens's tags are inherited, in order")
    }

    func testApplyForwardStripsSetWorkspace() {
        // setWorkspace is stripped — a new window keeps `workspace = activeIndex`
        // (D-A: never an orphan-on-birth). Mirrors the DnD forward filter
        // (`ApplyResolver` strips setWorkspace identically). t-qtpx forbids
        // `workspace` in a real lens `apply`, so this exercises the DEFENSIVE
        // strip on a directly-constructed section.
        let a = adapter([DesktopSection(
            type: .lens, label: "Routed", match: "tag~=r",
            apply: [.setWorkspace("Other"), .addTag("r")])])
        a.catalog.activeSectionLens = "section:0:Routed"
        XCTAssertEqual(
            a.activeSectionLensApplyForward(),
            [.addTag("r")],
            "setWorkspace is dropped; the remaining tag op passes through")
    }

    func testApplyForwardEmptyForPureConditionLens() {
        // A lens that matches on a window property with NO apply — a new window
        // can't be made to match it (declared gap).
        let a = adapter([DesktopSection(type: .lens, label: "Chrome",
                                        match: "app=Chrome")])
        a.catalog.activeSectionLens = "section:0:Chrome"
        XCTAssertEqual(a.activeSectionLensApplyForward(), [])
    }

    func testApplyForwardEmptyWhenNoLensActive() {
        let a = adapter([DesktopSection(type: .lens, label: "Web",
                                        match: "tag~=web", apply: [.addTag("web")])])
        // activeSectionLens is nil → no inheritance.
        XCTAssertEqual(a.activeSectionLensApplyForward(), [])
    }

    // (t-0021) The `tag~=X` lens DISPLAY by an assigned tag is pinned at the
    // projection layer now (`FilterProjectionTests.testLensMatchSelectsWindows
    // AcrossWorkspaces` + the snapshot's tag overlay) — a lens is a pure VIEW,
    // so there is no adapter-side gather/park to test here. This file pins only
    // the surviving inheritance resolver (`activeSectionLensApplyForward`).
}
