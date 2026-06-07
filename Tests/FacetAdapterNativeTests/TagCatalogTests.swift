import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Tag-mode (`[grouping] by = "tag"`) state-machine tests for the
/// catalog — pure, no AX / AppKit / OS. Covers the PR2a foundation:
/// tag assignment, lens switch park/restore delta, visibility union,
/// and tag preservation across slot re-creation.
final class TagCatalogTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }

    private func window(_ n: Int, pid: Int = 1000,
                        floating: Bool = false) -> Window {
        Window(id: wid(n), pid: pid, appName: "A", title: "w\(n)",
               isFocused: false, isFloating: floating, frame: nil)
    }

    private func probe(bundle: String? = nil, title: String = "")
        -> WindowProbe
    {
        WindowProbe(bundleId: bundle, title: title)
    }

    /// A catalog seeded for tag mode with tags `work`(bit0) `web`(bit1)
    /// `media`(bit2), lens = work, and the given assign rules.
    private func tagCatalog(rules: AssignRules = AssignRules([]),
                            lens: UInt64 = 0b001) -> WorkspaceCatalog {
        var c = WorkspaceCatalog()
        c.seed(configs: (1...2).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        c.seedTags(grouping: .tag,
                   model: TagModel(["work", "web", "media"]),
                   rules: rules, lens: lens)
        return c
    }

    // MARK: - seedTags

    func testSeedTagsSetsState() {
        let c = tagCatalog()
        XCTAssertEqual(c.grouping, .tag)
        XCTAssertEqual(c.tagModel.names, ["work", "web", "media"])
        XCTAssertEqual(c.lens, 0b001)
    }

    func testDefaultGroupingIsWorkspace() {
        var c = WorkspaceCatalog()
        c.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        XCTAssertEqual(c.grouping, .workspace)
    }

    // MARK: - tagsForNewWindow

    func testAssignedWindowGetsRuleUnion() {
        let c = tagCatalog(rules: AssignRules([
            AssignRule(matcher: WindowMatcher(app: "Chrome"), tags: ["web"]),
            AssignRule(matcher: WindowMatcher(title: "GitHub"),
                       tags: ["work"]),
        ]))
        let m = c.tagsForNewWindow(probe(bundle: "Chrome", title: "GitHub"))
        XCTAssertEqual(m, 0b011)   // web | work
    }

    func testUnmatchedWindowInheritsLensPrimaryOnly() {
        // lens = web|media (0b110); primary = web (lowest set bit).
        let c = tagCatalog(lens: 0b110)
        XCTAssertEqual(c.tagsForNewWindow(probe(bundle: "X")), 0b010)
    }

    func testUnmatchedWithSingleLensGetsThatTag() {
        let c = tagCatalog(lens: 0b100)   // media only
        XCTAssertEqual(c.tagsForNewWindow(probe(bundle: "X")), 0b100)
    }

    // MARK: - reconcile stores + preserves tags

    func testReconcileStoresPassedTags() {
        var c = tagCatalog()
        _ = c.reconcile(live: [window(10), window(20)],
                        tags: [wid(10): 0b010, wid(20): 0b101])
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b010)
        XCTAssertEqual(c.windowMap[wid(20)]?.tags, 0b101)
    }

    func testTagsPreservedAcrossPidChange() {
        var c = tagCatalog()
        _ = c.reconcile(live: [window(10, pid: 100)], tags: [wid(10): 0b010])
        _ = c.reconcile(live: [window(10, pid: 200)])   // pid changed
        XCTAssertEqual(c.windowMap[wid(10)]?.pid, 200)
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b010)  // survived
    }

    func testTagsPreservedAcrossMove() {
        var c = tagCatalog()
        _ = c.reconcile(live: [window(10)], tags: [wid(10): 0b101])
        c.moveWindow(wid(10), to: 2)   // rebuilds the slot → must carry tags
        XCTAssertEqual(c.windowMap[wid(10)]?.workspace, 2)
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b101)  // survived
    }

    // MARK: - visibleNonFloatingMembers (the tiled union)

    func testVisibleUnionByLens() {
        var c = tagCatalog(lens: 0b001)   // work
        _ = c.reconcile(live: [window(10), window(20), window(30)],
                        tags: [wid(10): 0b001,   // work  → visible
                               wid(20): 0b010,   // web   → hidden
                               wid(30): 0b011])  // work+web → visible
        XCTAssertEqual(c.visibleNonFloatingMembers(), [wid(10), wid(30)])
    }

    func testVisibleUnionAcrossMultipleLensTags() {
        var c = tagCatalog(lens: 0b011)   // work | web
        _ = c.reconcile(live: [window(10), window(20), window(30)],
                        tags: [wid(10): 0b001, wid(20): 0b010,
                               wid(30): 0b100])  // media → hidden
        XCTAssertEqual(c.visibleNonFloatingMembers(), [wid(10), wid(20)])
    }

    func testVisibleExcludesFloating() {
        var c = tagCatalog(lens: 0b001)
        _ = c.reconcile(live: [window(10), window(20, floating: true)],
                        autoFloat: [wid(20)],
                        tags: [wid(10): 0b001, wid(20): 0b001])
        XCTAssertEqual(c.visibleNonFloatingMembers(), [wid(10)])
    }

    // MARK: - setLens park/restore delta

    func testSetLensParksAndRestoresByDelta() {
        var c = tagCatalog(lens: 0b001)   // work
        _ = c.reconcile(live: [window(10), window(20), window(30)],
                        tags: [wid(10): 0b001,   // work only
                               wid(20): 0b010,   // web only
                               wid(30): 0b011])  // work+web
        // Switch lens work → web.
        let plan = c.setLens(0b010)
        XCTAssertNotNil(plan)
        XCTAssertEqual(c.lens, 0b010)
        // w10 (work only) leaves; w20 (web) enters; w30 (both) stays.
        XCTAssertEqual(Set(plan!.toPark.map(\.id)), [wid(10)])
        XCTAssertEqual(Set(plan!.toRestore.map(\.id)), [wid(20)])
    }

    func testSetLensNoOpWhenUnchanged() {
        var c = tagCatalog(lens: 0b001)
        XCTAssertNil(c.setLens(0b001))
    }

    func testSetLensNoOpInWorkspaceMode() {
        var c = WorkspaceCatalog()
        c.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        XCTAssertNil(c.setLens(0b010))
    }

    // MARK: - lens resolvers

    func testLensResolvers() {
        let c = tagCatalog(lens: 0b001)
        XCTAssertEqual(c.lensOnly("web"), 0b010)
        XCTAssertNil(c.lensOnly("ghost"))
        XCTAssertEqual(c.lensToggled("web"), 0b011)   // work + web
        XCTAssertEqual(c.lensAll, 0b111)
    }

    func testLensToggledOff() {
        let c = tagCatalog(lens: 0b011)   // work | web
        XCTAssertEqual(c.lensToggled("web"), 0b001)   // web cleared
    }
}
