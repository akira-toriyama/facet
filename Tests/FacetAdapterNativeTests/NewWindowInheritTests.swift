import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// EX-3.3 — new-window apply inheritance: `activeSectionLensApplyTags()` resolves
/// the active section-lens's `apply` addTag names so a window launched while the
/// lens is active joins it (canon ④⑨, "必ず見える"). The full adoption path runs
/// through `refreshCatalog` (AX/CGWindowList — host-verified, not CI); these pin
/// the pure resolver the inheritance reads. `NativeAdapter(config:)` only does
/// read-only SkyLight reads in init; the ordinal is forced to 1 for determinism.
final class NewWindowInheritTests: XCTestCase {

    private func adapter(_ sections: [DesktopSection]) -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [1: sections]
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        return a
    }

    func testApplyTagsReturnsAddTagNamesOfActiveLens() {
        let a = adapter([DesktopSection(type: .lens, label: "Web",
                                        match: "tag~=web", apply: [.addTag("web")])])
        a.catalog.activeSectionLens = "Web"
        XCTAssertEqual(a.activeSectionLensApplyTags(), ["web"])
    }

    func testApplyTagsOnlyAddTagOpsNotFloatingSticky() {
        let a = adapter([DesktopSection(
            type: .lens, label: "Multi", match: "tag~=a",
            apply: [.addTag("a"), .addTag("b"), .setFloating(true), .setSticky(true)])])
        a.catalog.activeSectionLens = "Multi"
        XCTAssertEqual(a.activeSectionLensApplyTags(), ["a", "b"],
                       "only addTag names are inherited (visibility-critical)")
    }

    func testApplyTagsEmptyForPureConditionLens() {
        // A lens that matches on a window property with NO apply — a new window
        // can't be made to match it (declared 緩む gap).
        let a = adapter([DesktopSection(type: .lens, label: "Chrome",
                                        match: "app=Chrome")])
        a.catalog.activeSectionLens = "Chrome"
        XCTAssertEqual(a.activeSectionLensApplyTags(), [])
    }

    func testApplyTagsEmptyWhenNoLensActive() {
        let a = adapter([DesktopSection(type: .lens, label: "Web",
                                        match: "tag~=web", apply: [.addTag("web")])])
        // activeSectionLens is nil → no inheritance.
        XCTAssertEqual(a.activeSectionLensApplyTags(), [])
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
