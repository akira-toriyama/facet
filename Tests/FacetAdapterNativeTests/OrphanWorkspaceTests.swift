import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

// Nullable `WindowSlot.workspace` foundation. These tests prove the catalog is
// orphan-safe: a window with `workspace == nil` (a 迷子) never crashes any
// catalog op, is excluded from every per-workspace projection, and survives
// workspace mutation untouched — while a normal (workspaced) window's behaviour
// is byte-identical to before. Orphans are injected directly here via the
// `setOrphan` primitive (kept as a foundation — t-qtpx removed the ws→lens DnD
// that used to be its only production caller); these tests pin the foundation,
// not new behaviour.
//
// CLT can't run XCTest; CI is the gate (memory feedback-swift-tests-only-compile-in-ci).
struct OrphanWorkspaceTests {

    /// Inject an orphan (workspace=nil) window directly into the catalog.
    private func makeOrphan(_ c: inout WorkspaceCatalog, _ n: Int, pid: Int = 1000) {
        c.windowMap[wid(n)] = WindowSlot(workspace: nil, pid: pid)
    }

    // MARK: - Snapshot excludes orphans (invisible)

    @Test func orphanExcludedFromSnapshot() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // normal window → WS1
        makeOrphan(&c, 99)                          // orphan
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let snap = c.snapshot(live: [window(10), window(99)],
                              focused: nil, activeRect: rect)
        let allShown = Set(snap.flatMap { $0.windows.map(\.id) })
        #expect(allShown.contains(wid(10)), "normal window stays visible")
        #expect(!allShown.contains(wid(99)),
                       "orphan is excluded from every workspace in the snapshot")
        // No phantom workspace is emitted for the orphan: exactly the 3 seeded.
        #expect(snap.count == 3)
    }

    // MARK: - Layout ops are no-ops / non-crashing on orphans

    @Test func toggleOrientationOrphanIsNoOpNoCrash() {
        var c = seededCatalog(2)
        makeOrphan(&c, 99)
        c.toggleOrientation(of: wid(99))           // must not crash (no tree)
        #expect(c.windowMap[wid(99)]?.workspace == nil, "orphan stays orphan")
    }

    // MARK: - Workspace mutation leaves orphans untouched

    @Test func removeWorkspaceLeavesOrphanUntouched() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        _ = c.moveWindow(wid(10), to: 2)           // → WS2 so removing WS3 is clean
        makeOrphan(&c, 99)
        let removed = c.removeWorkspace(3)
        #expect(removed)
        #expect(c.windowMap[wid(99)]?.workspace == nil,
                     "orphan is not a member of any workspace → untouched by remove")
        #expect(c.windowMap[wid(10)]?.workspace == 2, "normal window unchanged")
    }

    @Test func moveActiveWorkspaceLeavesOrphanUntouched() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        makeOrphan(&c, 99)
        let moved = c.moveActiveWorkspace(to: 3) // exercises remapIndices
        #expect(moved)
        #expect(c.windowMap[wid(99)]?.workspace == nil,
                     "remapIndices skips orphans (position-agnostic)")
    }

    // MARK: - moveWindow un-orphans into a workspace

    @Test func moveWindowUnOrphansIntoActiveWorkspaceRestores() {
        var c = seededCatalog(3)                    // active = WS1
        makeOrphan(&c, 99)
        let outcome = c.moveWindow(wid(99), to: 1)  // orphan → active WS
        #expect(c.windowMap[wid(99)]?.workspace == 1,
                       "orphan adopts the destination workspace")
        switch outcome {
        case .restore: break                        // entered the active WS → un-hide
        default: Issue.record("orphan → active WS should .restore, got \(outcome)")
        }
    }

    @Test func moveWindowOrphanToInactiveWorkspaceStateOnly() {
        var c = seededCatalog(3)                    // active = WS1
        makeOrphan(&c, 99)
        let outcome = c.moveWindow(wid(99), to: 2)  // orphan → inactive WS
        #expect(c.windowMap[wid(99)]?.workspace == 2)
        switch outcome {
        case .stateOnly: break                      // not the active WS → stays parked
        default: Issue.record("orphan → inactive WS should .stateOnly, got \(outcome)")
        }
    }

    // MARK: - Equality / membership filters exclude orphans

    @Test func orphanNotANonFloatingMemberOfAnyWorkspace() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        makeOrphan(&c, 99)
        for ws in 1...3 {
            #expect(!c.nonFloatingMembers(of: ws).contains(wid(99)),
                           "orphan is a member of no workspace (\(ws))")
        }
        #expect(c.nonFloatingMembers(of: 1).contains(wid(10)))
    }

    // MARK: - setOrphan (workspace → 迷子) primitive

    @Test func setOrphanFromActiveWorkspaceParks() {
        var c = seededCatalog(3)                    // active = WS1
        _ = c.reconcile(live: [window(10)])        // WS1
        let outcome = c.setOrphan(wid(10))
        #expect(c.windowMap[wid(10)]?.workspace == nil, "left its workspace (迷子)")
        switch outcome {
        case .park(let ref): #expect(ref.id == wid(10))
        default: Issue.record("active-WS window → orphan should .park, got \(outcome)")
        }
    }

    @Test func setOrphanFromInactiveWorkspaceStateOnly() {
        var c = seededCatalog(3)                    // active = WS1
        _ = c.reconcile(live: [window(10)])        // WS1
        _ = c.moveWindow(wid(10), to: 2)           // → WS2 (inactive)
        let outcome = c.setOrphan(wid(10))
        #expect(c.windowMap[wid(10)]?.workspace == nil)
        switch outcome {
        case .stateOnly: break
        default: Issue.record("inactive-WS window → orphan should .stateOnly, got \(outcome)")
        }
    }

    @Test func setOrphanRejectsAlreadyOrphan() {
        var c = seededCatalog(3)
        makeOrphan(&c, 99)
        switch c.setOrphan(wid(99)) {
        case .rejected: break
        default: Issue.record("orphaning an orphan is a no-op (.rejected)")
        }
    }

    @Test func setOrphanRejectsSticky() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        c.everywhereWindows.insert(wid(10))        // sticky = everywhere
        switch c.setOrphan(wid(10)) {
        case .rejected: break
        default: Issue.record("a sticky window can't be orphaned (.rejected)")
        }
        #expect(c.windowMap[wid(10)]?.workspace == 1, "sticky window keeps its WS")
    }

    @Test func setOrphanRejectsStashed() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        c.stashedWindows.insert(wid(10))           // shelved scratchpad
        switch c.setOrphan(wid(10)) {
        case .rejected: break
        default: Issue.record("a stashed window can't be orphaned (.rejected)")
        }
        #expect(c.windowMap[wid(10)]?.workspace == 1, "stashed window keeps its WS")
    }

    @Test func setOrphanRemovesFromMembershipAndSnapshot() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // WS1
        _ = c.setOrphan(wid(10))
        #expect(!c.nonFloatingMembers(of: 1).contains(wid(10)),
                       "orphan leaves WS1 membership")
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let snap = c.snapshot(live: [window(10)], focused: nil, activeRect: rect)
        let shown = Set(snap.flatMap { $0.windows.map(\.id) })
        #expect(!shown.contains(wid(10)), "orphan is invisible in the snapshot")
    }

    // MARK: - a workspace switch parks on-screen orphans

    @Test func switchWorkspaceParksOnScreenOrphan() {
        var c = seededCatalog(3)                    // active = WS1
        makeOrphan(&c, 99)                          // on-screen orphan (not anchorParked)
        guard let plan = c.setActive(2) else {
            Issue.record("switch to WS2 should produce a plan"); return
        }
        #expect(plan.toPark.contains { $0.id == wid(99) },
                      "a switch parks every orphan (it belongs to no workspace)")
    }
    // (t-0021) The old `testClearSectionLensParksOnScreenOrphan` is retired: a
    // lens is a pure VIEW now — it never showed orphans via a union tile, so
    // clearing one parks nothing. `clearSectionLens` itself is gone (a lens
    // clear is just `activeSectionLens = nil`).

    // MARK: - EX-3 GAP fix: orphanWindows() projects orphans for matched section

    /// `orphanWindows` returns EXACTLY the managed windows in no workspace —
    /// the input the tree/grid/rail matched section need (snapshot drops them).
    /// A lens is a pure VIEW (t-0021): `FilterProjection` lists these orphans
    /// in any matching matched section (display only — they aren't moved).
    @Test func orphanWindowsReturnsOnlyOrphans() {
        var c = seededCatalog(3)
        _ = c.reconcile(live: [window(10)])        // normal → WS1
        makeOrphan(&c, 99)                          // orphan
        let orphans = c.orphanWindows(
            in: [window(10), window(99)], focused: nil, populateTags: false)
        #expect(orphans.map(\.id) == [wid(99)],
                       "only the orphan (workspace==nil), never the workspaced window")
    }

    /// A stashed (shelved) window is excluded — it's invisible everywhere,
    /// orphan or not (shared `trackedWindows` gate with `snapshot`).
    @Test func orphanWindowsExcludesStashed() {
        var c = seededCatalog(3)
        makeOrphan(&c, 99)
        c.stashedWindows.insert(wid(99))
        let orphans = c.orphanWindows(
            in: [window(99)], focused: nil, populateTags: false)
        #expect(orphans.isEmpty,
                      "a stashed orphan is excluded (trackedWindows drops stashed)")
    }

    /// An UNMANAGED window (live but never reconciled → no `windowMap` entry)
    /// is NOT an orphan: `windowMap[id]?.workspace == nil` is true for it too,
    /// so the guard MUST key off the entry's presence (via `trackedWindows`),
    /// not the optional-chain nil. Pins that distinction.
    @Test func orphanWindowsExcludesUnmanaged() {
        let c = seededCatalog(3)
        let orphans = c.orphanWindows(
            in: [window(77)], focused: nil, populateTags: false)
        #expect(orphans.isEmpty,
                      "an unmanaged window (no windowMap entry) is not an orphan")
    }

    /// Tags ride the `populateTags` gate exactly as in `snapshot` (shared
    /// `makeWindow`): on when the section model is live (so a `tag~=X` lens
    /// DISPLAYS the orphan via `FilterProjection`), `[]` otherwise.
    @Test func orphanWindowsTagsGatedBySectionModel() {
        var c = seededCatalog(3)
        makeOrphan(&c, 99)
        _ = c.addTagToWindow(wid(99), name: "web")
        let on = c.orphanWindows(in: [window(99)], focused: nil, populateTags: true)
        #expect(on.first?.tags == ["web"], "tags populated under section model")
        let off = c.orphanWindows(in: [window(99)], focused: nil, populateTags: false)
        #expect(off.first?.tags == [], "tags suppressed off the section model")
    }
}
