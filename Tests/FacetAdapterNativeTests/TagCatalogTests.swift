import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Tag-mode (`[grouping] by = "tag"`) state-machine tests for the
/// catalog — pure, no AX / AppKit / OS. Covers the PR2a foundation:
/// tag assignment, lens switch park/restore delta, visibility union,
/// and tag preservation across slot re-creation.
final class TagCatalogTests: XCTestCase {

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
        XCTAssertEqual(c.lensOnly(["web"]), 0b010)
        XCTAssertNil(c.lensOnly(["ghost"]))
        XCTAssertEqual(c.lensToggled(["web"]), 0b011)   // work + web
        // --all = every user tag PLUS the _default floor.
        XCTAssertEqual(c.lensAll, 0b111 | TagModel.defaultBit)
    }

    func testLensToggledOff() {
        let c = tagCatalog(lens: 0b011)   // work | web
        XCTAssertEqual(c.lensToggled(["web"]), 0b001)   // web cleared
    }

    // MARK: - Multi-tag lens resolvers (#228, comma-joined)

    func testLensOnlyMultipleTagsIsStrictUnion() {
        let c = tagCatalog(lens: 0b001)
        // only = exact replacement: the union of the named user bits.
        XCTAssertEqual(c.lensOnly(["web", "media"]), 0b110)
        // Strict: one undefined name rejects the WHOLE set (no silent
        // drop of just the bad name).
        XCTAssertNil(c.lensOnly(["web", "ghost"]))
    }

    func testLensAddedUnionsAndStripsFloor() {
        let c = tagCatalog(lens: 0b001)   // work
        XCTAssertEqual(c.lensAdded(["web", "media"]), 0b111)  // work|web|media
        XCTAssertNil(c.lensAdded(["web", "ghost"]))           // strict
    }

    func testLensAddedFromFloorOnlyLensYieldsExactlyTheAddedTags() {
        // From the floor-only (untagged-baseline) lens, --add code = {code}
        // — the floor is the empty sentinel, not a real member, so it's
        // stripped (issue #228: `--add code` from empty = exactly {code}).
        let c = tagCatalog(lens: TagModel.defaultBit)
        XCTAssertEqual(c.lensAdded(["web"]), 0b010)
    }

    func testLensRemovedStripsTagsAndFloor() {
        let c = tagCatalog(lens: 0b011)   // work | web
        XCTAssertEqual(c.lensRemoved(["web"]), 0b001)   // work
        // Removing the last user tag yields a 0 user mask (setLens then
        // floor-guards it back to the untagged baseline).
        let c2 = tagCatalog(lens: 0b010)   // web only
        XCTAssertEqual(c2.lensRemoved(["web"]), 0)
        XCTAssertNil(c.lensRemoved(["ghost"]))          // strict
    }

    func testLensToggledMultipleTags() {
        let c = tagCatalog(lens: 0b001)   // work
        // XOR each: work stays? no — work not in set; web/media flip on.
        XCTAssertEqual(c.lensToggled(["web", "media"]), 0b111)  // work|web|media
        let c2 = tagCatalog(lens: 0b011)   // work | web
        XCTAssertEqual(c2.lensToggled(["web", "media"]), 0b101) // web off, media on
        XCTAssertNil(c.lensToggled(["web", "ghost"]))           // strict
    }

    // MARK: - setLens floor guard (#228 rider — shipped latent bug)

    func testSetLensEmptyMaskFallsBackToFloor() {
        // The shipped bug: setLens(0) parked every window (nothing
        // intersects a 0 mask). The guard falls back to the floor so the
        // untagged baseline shows instead of a blank desktop.
        var c = tagCatalog(lens: 0b001)   // lens = work
        taggedAll(&c, [(10, 0b001),       // work → shown under work lens
                       (20, 0b010)])      // web  → hidden under work lens
        let plan = c.setLens(0)
        XCTAssertNotNil(plan)
        XCTAssertEqual(c.lens, TagModel.defaultBit)        // floor, not 0
        XCTAssertEqual(plan!.newLens, TagModel.defaultBit) // plan carries normalized mask
        // Load-bearing: the park/restore delta is computed against the
        // NORMALIZED floor mask, not raw 0. Every window carries the
        // floor, so under it w10 stays shown (no park) and w20 (was
        // hidden) re-enters. The bug computed the delta against 0 →
        // toPark=[w10], toRestore=[] (a blank desktop).
        XCTAssertEqual(Set(plan!.toPark.map(\.id)), [])
        XCTAssertEqual(Set(plan!.toRestore.map(\.id)), [wid(20)])
    }

    func testSetLensEmptyMaskIsNoOpWhenAlreadyFloor() {
        // Already on the floor → setLens(0) normalizes to the floor and
        // the unchanged-guard returns nil (no spurious retile).
        var c = tagCatalog(lens: TagModel.defaultBit)
        XCTAssertNil(c.setLens(0))
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

    // MARK: - Single-window retag (#228, `facet window --retag OLD NEW`)

    func testRetagReplacesOldWithNewAtomically() {
        var c = tagCatalog(lens: 0b001)   // lens = work
        tagged(&c, 10, 0b011)             // work + web
        // retag web -> media: web cleared, media set, work + floor kept,
        // in one write. Still has work → stays in the lens (.unchanged).
        XCTAssertEqual(c.retagWindow(wid(10), old: "web", new: "media"),
                       .retagged(.unchanged))
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b101 | TagModel.defaultBit)   // work + media + floor
    }

    func testRetagStrictAUndefinedOldRejectsWithoutVivifyingNew() {
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b001)             // work
        // Strict-A: undefined OLD rejects. Guard order means NEW is NOT
        // vivified (the pure bit(for:old) read precedes addTagName(new)),
        // so a rejected retag never pollutes the vocabulary.
        XCTAssertEqual(c.retagWindow(wid(10), old: "ghost", new: "fresh"),
                       .oldUndefined)
        XCTAssertNil(c.tagModel.bit(for: "fresh"))   // vocabulary untouched
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b001 | TagModel.defaultBit)   // mask untouched
    }

    func testRetagNewAutoVivifiesAndParksWhenLeavingLens() {
        var c = tagCatalog(lens: 0b001)   // lens = work
        tagged(&c, 10, 0b001)             // work only → shown
        XCTAssertNil(c.tagModel.bit(for: "scratch"))
        let out = c.retagWindow(wid(10), old: "work", new: "scratch")
        XCTAssertEqual(c.tagModel.bit(for: "scratch"), 0b1000)  // vivified, bit 3
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b1000 | TagModel.defaultBit)  // work gone, scratch set
        // Lost its only lens tag (work) → parks.
        XCTAssertEqual(out, .retagged(.park))
    }

    func testRetagDegradesToAddWhenWindowLacksOld() {
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b001)             // work only (lacks web)
        // Window lacks web but web is defined → the & ~webBit is a no-op,
        // so this degrades to a bare add of media (work + floor kept). It
        // keeps work (the lens tag) → still visible (.unchanged).
        XCTAssertEqual(c.retagWindow(wid(10), old: "web", new: "media"),
                       .retagged(.unchanged))
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b101 | TagModel.defaultBit)   // work + media + floor
    }

    func testRetagSameNameIsNoOpWhenPresent() {
        var c = tagCatalog(lens: 0b001)
        tagged(&c, 10, 0b001)             // work
        // OLD == NEW, window already has it → genuine no-op success.
        XCTAssertEqual(c.retagWindow(wid(10), old: "work", new: "work"),
                       .retagged(.unchanged))
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b001 | TagModel.defaultBit)
    }

    func testRetagRestoresWindowEnteringLens() {
        var c = tagCatalog(lens: 0b010)   // lens = web
        tagged(&c, 10, 0b001)             // work only → hidden under web lens
        // retag work -> web: window gains web → enters the lens → restore.
        XCTAssertEqual(c.retagWindow(wid(10), old: "work", new: "web"),
                       .retagged(.restore))
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b010 | TagModel.defaultBit)
    }

    func testRetagUntrackedWindowReturnsNoWindow() {
        var c = tagCatalog(lens: 0b001)
        XCTAssertEqual(c.retagWindow(wid(99), old: "work", new: "web"),
                       .noWindow)
    }

    func testRetagVocabFullRejectsNewVivifyAndLeavesMaskUntouched() {
        // A full vocabulary (63 user tags) can't vivify a 64th NEW name.
        var c = WorkspaceCatalog()
        c.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        let names = (0..<63).map { "t\($0)" }
        c.seedTags(grouping: .tag, model: TagModel(names), lens: 0b1)
        tagged(&c, 10, 0b1)               // has t0
        XCTAssertEqual(c.retagWindow(wid(10), old: "t0", new: "t63"),
                       .vocabFull)
        XCTAssertNil(c.tagModel.bit(for: "t63"))     // not created
        XCTAssertEqual(c.windowMap[wid(10)]?.tags,
                       0b1 | TagModel.defaultBit)     // mask untouched
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

    // MARK: - tagSnapshot (flat render, #191 PR-6)

    func testTagSnapshotIsOneFlatActiveWorkspace() {
        var c = tagCatalog(lens: 0b001)
        taggedAll(&c, [(10, 0b001), (20, 0b010), (30, 0b101)])
        let snap = c.tagSnapshot(live: [window(10), window(20), window(30)],
                                 focused: wid(10), activeRect: .zero)
        // Exactly ONE synthetic, always-active workspace (index 0) holding
        // every tracked window once, in stable serverID order.
        XCTAssertEqual(snap.count, 1)
        XCTAssertEqual(snap[0].index, 0)
        XCTAssertTrue(snap[0].isActive)
        XCTAssertEqual(snap[0].windows.map(\.id), [wid(10), wid(20), wid(30)])
        XCTAssertEqual(snap[0].windows.first { $0.id == wid(10) }?.isFocused,
                       true)
    }

    func testTagSnapshotRowCarriesEveryTagNameNotTheFloor() {
        var c = tagCatalog(lens: 0b001)
        taggedAll(&c, [(10, 0b101)])   // work + media (+ floor bit 63)
        let snap = c.tagSnapshot(live: [window(10)],
                                 focused: nil, activeRect: .zero)
        // All user tags as chips, declaration order; the _default floor is
        // never surfaced (it isn't in `tagModel.names`).
        XCTAssertEqual(snap[0].windows.first?.tags, ["work", "media"])
    }

    func testTagSnapshotEmptyWhenNoTrackedWindows() {
        // Live windows that were never reconciled into the map are
        // untracked → flat snapshot is empty → the panel hides.
        let c = tagCatalog(lens: 0b001)
        XCTAssertTrue(c.tagSnapshot(live: [window(10)],
                                    focused: nil, activeRect: .zero).isEmpty)
    }

    func testTagSnapshotIncludesParkedOutOfLensWindows() {
        var c = tagCatalog(lens: 0b001)   // lens = work
        taggedAll(&c, [(10, 0b001),       // work → in the lens
                       (20, 0b010)])      // web  → out of the lens (parked)
        let snap = c.tagSnapshot(live: [window(10), window(20)],
                                 focused: nil, activeRect: .zero)
        // The flat list is the full tag world — parked (out-of-lens)
        // windows still appear, independent of the lens.
        XCTAssertEqual(snap[0].windows.map(\.id), [wid(10), wid(20)])
    }
}
