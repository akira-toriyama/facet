import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// `facet window --tag/--untag/--toggle-tag/--retag` backing (EX-4.3): tags
/// are a free-form per-window `Set<String>` — no vocabulary, no 63-cap, no
/// floor. CI-only (CLT can't run XCTest).
struct WindowTagsTests {
    private func catalogWithWindow() -> WorkspaceCatalog {
        var c = seededCatalog(1)
        _ = c.reconcile(live: [window(10)])   // adopt id=10 into WS1
        return c
    }
    @Test func tagsAreAFreeFormStringSet() {
        var c = catalogWithWindow()
        let id = WindowID(serverID: 10)
        let addedWeb = c.addTagToWindow(id, name: "web")
        #expect(addedWeb)
        let addedCode = c.addTagToWindow(id, name: "code")
        #expect(addedCode)
        #expect(c.windowMap[id]?.tags == ["web", "code"])      // Set, no floor
        let removedWeb = c.removeTagFromWindow(id, name: "web")
        #expect(removedWeb)
        #expect(c.windowMap[id]?.tags == ["code"])
        let toggledWeb = c.toggleTagOnWindow(id, name: "web")
        #expect(toggledWeb)         // re-adds
        #expect(c.windowMap[id]?.tags == ["web", "code"])
    }
    @Test func untagAbsentReturnsFalse() {
        var c = catalogWithWindow()
        let removed = c.removeTagFromWindow(WindowID(serverID: 10), name: "nope")
        #expect(!removed)
    }
    @Test func newTagNameAutoVivifies() {     // no vocabulary / no cap
        var c = catalogWithWindow()
        let added = c.addTagToWindow(WindowID(serverID: 10), name: "brand-new")
        #expect(added)
        #expect(c.windowMap[WindowID(serverID: 10)]?.tags == ["brand-new"])
    }
    @Test func retagReplacesOldWithNew() {
        var c = catalogWithWindow()
        let id = WindowID(serverID: 10)
        _ = c.addTagToWindow(id, name: "old")
        #expect(c.retagWindow(id, old: "old", new: "new") == .retagged)
        #expect(c.windowMap[id]?.tags == ["new"])
    }

    /// `facet query --tags` (the surviving read) is the SORTED union of every
    /// window's tags — empty until a window is tagged, no vocabulary registry.
    @Test func definedTagNamesIsSortedUnionOfWindowTags() {
        let a = adapter()
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        _ = a.catalog.reconcile(live: [window(10), window(20)])
        #expect(a.definedTagNames() == [], "no tags until one is applied")
        _ = a.catalog.addTagToWindow(wid(10), name: "web")
        _ = a.catalog.addTagToWindow(wid(20), name: "code")
        _ = a.catalog.addTagToWindow(wid(20), name: "web")   // duplicate across windows
        #expect(a.definedTagNames() == ["code", "web"], "sorted union, deduped")
    }
}
