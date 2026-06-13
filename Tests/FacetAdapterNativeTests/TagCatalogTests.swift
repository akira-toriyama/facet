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

    /// A catalog seeded for tag mode with tags `work`(bit0) `web`(bit1)
    /// `media`(bit2) and the given lens (default = work).
    private func tagCatalog(lens: UInt64 = 0b001) -> WorkspaceCatalog {
        var c = WorkspaceCatalog()
        c.seed(configs: (1...2).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        c.seedTags(grouping: .tag,
                   model: TagModel(["work", "web", "media"]),
                   lens: lens)
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

    func testNewWindowInheritsLensPrimaryOnly() {
        // lens = web|media (0b110); primary = web (lowest set bit). A new
        // window joins the one primary tag, never the whole lens union.
        let c = tagCatalog(lens: 0b110)
        XCTAssertEqual(c.tagsForNewWindow(), 0b010 | TagModel.defaultBit)
    }

    func testNewWindowWithSingleLensGetsThatTag() {
        let c = tagCatalog(lens: 0b100)   // media only
        XCTAssertEqual(c.tagsForNewWindow(), 0b100 | TagModel.defaultBit)
    }

    func testNewWindowUnderFloorLensIsFloorOnly() {
        // Startup lens = the _default floor → a window opened before any
        // lens switch is floor-only (untagged), since the floor is the
        // lens's lowest (only) bit.
        let c = tagCatalog(lens: TagModel.defaultBit)
        XCTAssertEqual(c.tagsForNewWindow(), TagModel.defaultBit)
    }

    func testNewWindowAlwaysCarriesDefaultFloor() {
        // The _default floor (bit 63) is ON for every new window, so a
        // window is never tags == 0 / lost (#191).
        let c = tagCatalog(lens: 0b001)
        let m = c.tagsForNewWindow()
        XCTAssertEqual(m & TagModel.defaultBit, TagModel.defaultBit)
        XCTAssertNotEqual(m, 0)
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
        // --all = every user tag PLUS the _default floor.
        XCTAssertEqual(c.lensAll, 0b111 | TagModel.defaultBit)
    }

    func testLensToggledOff() {
        let c = tagCatalog(lens: 0b011)   // work | web
        XCTAssertEqual(c.lensToggled("web"), 0b001)   // web cleared
    }

    // MARK: - Runtime window tagging (#191 PR-2)

    /// A window seeded into the map with a tag mask (incl. the floor).
    private func tagged(_ c: inout WorkspaceCatalog,
                        _ n: Int, _ mask: UInt64) {
        _ = c.reconcile(live: [window(n)],
                        tags: [wid(n): mask | TagModel.defaultBit])
    }

    /// Seed SEVERAL windows in ONE reconcile (each mask gets the floor).
    /// Must be a single call: reconcile drops any window absent from the
    /// live list, so two `tagged` calls would forget the first window.
    private func taggedAll(_ c: inout WorkspaceCatalog,
                           _ entries: [(Int, UInt64)]) {
        _ = c.reconcile(
            live: entries.map { window($0.0) },
            tags: Dictionary(uniqueKeysWithValues:
                entries.map { (wid($0.0), $0.1 | TagModel.defaultBit) }))
    }

    func testAddTagSetsBitAndKeepsFloor() {
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b001)                       // work
        XCTAssertNotNil(c.addTagToWindow(wid(10), name: "web"))
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b011 | TagModel.defaultBit)  // work + web + floor
    }

    func testAddTagAutoVivifiesUnknownName() {
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b001)
        XCTAssertNil(c.tagModel.bit(for: "scratch"))     // not yet defined
        XCTAssertNotNil(c.addTagToWindow(wid(10), name: "scratch"))
        XCTAssertEqual(c.tagModel.bit(for: "scratch"), 0b1000)  // next free bit
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b1001 | TagModel.defaultBit)    // work + scratch + floor
    }

    func testAddTagNeverParks() {
        // Adding only sets bits → visibility can't shrink.
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b001)
        XCTAssertEqual(c.addTagToWindow(wid(10), name: "web"), .unchanged)
    }

    func testRemoveTagKeepsFloorAndParks() {
        var c = tagCatalog(lens: 0b001)   // lens = work
        tagged(&c, 10, 0b001)             // work only → shown
        // Removing the only lens-intersecting tag parks the window.
        XCTAssertEqual(c.removeTagFromWindow(wid(10), name: "work"), .park)
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, TagModel.defaultBit)  // floor stays
    }

    func testRemoveUnknownOrReservedTagRejected() {
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b001)
        XCTAssertNil(c.removeTagFromWindow(wid(10), name: "ghost"))     // unknown
        XCTAssertNil(c.removeTagFromWindow(wid(10), name: "_default"))  // reserved
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b001 | TagModel.defaultBit)     // untouched
    }

    func testToggleTagFlips() {
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b001)
        _ = c.toggleTagOnWindow(wid(10), name: "web")   // add
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b011 | TagModel.defaultBit)
        _ = c.toggleTagOnWindow(wid(10), name: "web")   // remove
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b001 | TagModel.defaultBit)
    }

    func testToggleAddingLensTagRestores() {
        var c = tagCatalog(lens: 0b010)   // lens = web
        tagged(&c, 10, 0b001)             // work only → hidden under web lens
        // Toggling web on brings it into the lens.
        XCTAssertEqual(c.toggleTagOnWindow(wid(10), name: "web"), .restore)
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b011 | TagModel.defaultBit)
    }

    func testRetagUntrackedWindowReturnsNil() {
        var c = tagCatalog(lens: 0b001)
        XCTAssertNil(c.addTagToWindow(wid(99), name: "web"))
        XCTAssertNil(c.removeTagFromWindow(wid(99), name: "work"))
        XCTAssertNil(c.toggleTagOnWindow(wid(99), name: "web"))
    }

    func testAddTagNameVivifyDedupeAndReserved() {
        var c = tagCatalog(lens: 0b001)
        XCTAssertEqual(c.addTagName("work"), 0b001)   // existing → its bit
        XCTAssertEqual(c.addTagName("new"), 0b1000)   // next free bit (idx 3)
        XCTAssertEqual(c.tagModel.count, 4)
        XCTAssertNil(c.addTagName("_default"))        // reserved → nil
        XCTAssertEqual(c.tagModel.count, 4)           // unchanged
    }

    // MARK: - Runtime tag vocabulary (#191 PR-3, `facet tag`)

    func testRemoveTagNameStripsBitFromEveryWindowKeepsFloor() {
        var c = tagCatalog(lens: 0b001)   // lens = work
        taggedAll(&c, [(10, 0b011),       // work + web
                       (20, 0b010)])      // web only
        XCTAssertNotNil(c.removeTagName("web"))
        XCTAssertNil(c.tagModel.bit(for: "web"))   // gone from the vocabulary
        // web bit stripped from both; floor (+ other bits) preserved.
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b001 | TagModel.defaultBit)
        XCTAssertEqual(c.windowMap[wid(20)]?.tags, TagModel.defaultBit)
    }

    func testRemoveTagNameFreesBitForReuse() {
        var c = tagCatalog(lens: 0b001)
        _ = c.removeTagName("web")                 // free bit 1
        XCTAssertEqual(c.addTagName("ext"), 0b010) // reuses bit 1 (not bit 3)
        XCTAssertEqual(c.tagModel.bit(for: "media"), 0b100)  // media unmoved
    }

    func testRemoveTagParksWindowThatLosesVisibility() {
        var c = tagCatalog(lens: 0b011)   // lens = work | web
        taggedAll(&c, [(10, 0b001),       // work → shown
                       (20, 0b010)])      // web  → shown
        // Remove web: w20 loses its only user tag and the lens drops
        // bit 1 → {work}. w20 (now floor-only) parks; w10 stays.
        let plan = c.removeTagName("web")!
        XCTAssertEqual(c.lens, 0b001)
        XCTAssertEqual(Set(plan.toPark.map(\.id)), [wid(20)])
        XCTAssertEqual(Set(plan.toRestore.map(\.id)), [])
        XCTAssertEqual(c.windowMap[wid(20)]?.tags, TagModel.defaultBit)
        // w10 kept its lensed tag → still visible, untouched.
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b001 | TagModel.defaultBit)
    }

    func testRemoveSoleLensTagFallsBackToFloorShowAll() {
        var c = tagCatalog(lens: 0b010)   // lens = web only
        tagged(&c, 10, 0b010)             // web → shown
        let plan = c.removeTagName("web")!
        // Emptied lens → floor (show-all); the now floor-only window
        // stays visible, so nothing parks.
        XCTAssertEqual(c.lens, TagModel.defaultBit)
        XCTAssertEqual(Set(plan.toPark.map(\.id)), [])
        XCTAssertEqual(Set(plan.toRestore.map(\.id)), [])
    }

    func testRemoveTagNameRejectsUnknownReservedAndWorkspaceMode() {
        var c = tagCatalog(lens: 0b001)
        XCTAssertNil(c.removeTagName("ghost"))      // unknown
        XCTAssertNil(c.removeTagName("_default"))   // reserved
        var ws = WorkspaceCatalog()
        ws.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        XCTAssertNil(ws.removeTagName("work"))      // not tag mode
    }

    func testRenameTagNameKeepsWindowMembership() {
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b010)             // web
        XCTAssertEqual(c.renameTagName("web", to: "social"), .renamed(0b010))
        // Bit unchanged → the window's mask is untouched.
        XCTAssertEqual(c.windowMap[wid(10)]?.tags, 0b010 | TagModel.defaultBit)
        XCTAssertEqual(c.tagModel.bit(for: "social"), 0b010)
        XCTAssertNil(c.tagModel.bit(for: "web"))
    }

    func testRenameTagNameRejects() {
        var c = tagCatalog(lens: 0b001)
        XCTAssertEqual(c.renameTagName("work", to: "web"), .collision)
        XCTAssertEqual(c.renameTagName("ghost", to: "x"), .unknownOld)
    }
}
