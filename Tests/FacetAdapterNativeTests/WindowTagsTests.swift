import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// `facet window --tag/--untag/--toggle-tag/--retag` backing (EX-4.3): tags
/// are a free-form per-window `Set<String>` — no vocabulary, no 63-cap, no
/// floor. CI-only (CLT can't run XCTest).
final class WindowTagsTests: XCTestCase {
    private func catalogWithWindow() -> WorkspaceCatalog {
        var c = seededCatalog(1)
        _ = c.reconcile(live: [window(10)])   // adopt id=10 into WS1
        return c
    }
    func testTagsAreAFreeFormStringSet() {
        var c = catalogWithWindow()
        let id = WindowID(serverID: 10)
        XCTAssertTrue(c.addTagToWindow(id, name: "web"))
        XCTAssertTrue(c.addTagToWindow(id, name: "code"))
        XCTAssertEqual(c.windowMap[id]?.tags, ["web", "code"])      // Set, no floor
        XCTAssertTrue(c.removeTagFromWindow(id, name: "web"))
        XCTAssertEqual(c.windowMap[id]?.tags, ["code"])
        XCTAssertTrue(c.toggleTagOnWindow(id, name: "web"))         // re-adds
        XCTAssertEqual(c.windowMap[id]?.tags, ["web", "code"])
    }
    func testUntagAbsentReturnsFalse() {
        var c = catalogWithWindow()
        XCTAssertFalse(c.removeTagFromWindow(WindowID(serverID: 10), name: "nope"))
    }
    func testNewTagNameAutoVivifies() {     // no vocabulary / no cap
        var c = catalogWithWindow()
        XCTAssertTrue(c.addTagToWindow(WindowID(serverID: 10), name: "brand-new"))
        XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["brand-new"])
    }
    func testRetagReplacesOldWithNew() {
        var c = catalogWithWindow()
        let id = WindowID(serverID: 10)
        _ = c.addTagToWindow(id, name: "old")
        XCTAssertEqual(c.retagWindow(id, old: "old", new: "new"), .retagged)
        XCTAssertEqual(c.windowMap[id]?.tags, ["new"])
    }

    /// `facet query --tags` (the surviving read) is the SORTED union of every
    /// window's tags — empty until a window is tagged, no vocabulary registry.
    func testDefinedTagNamesIsSortedUnionOfWindowTags() {
        let a = adapter()
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        _ = a.catalog.reconcile(live: [window(10), window(20)])
        XCTAssertEqual(a.definedTagNames(), [], "no tags until one is applied")
        _ = a.catalog.addTagToWindow(wid(10), name: "web")
        _ = a.catalog.addTagToWindow(wid(20), name: "code")
        _ = a.catalog.addTagToWindow(wid(20), name: "web")   // duplicate across windows
        XCTAssertEqual(a.definedTagNames(), ["code", "web"], "sorted union, deduped")
    }
}
