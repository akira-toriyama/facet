import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// Pure tests for relative workspace targeting (Theme C-2):
/// `previousActiveIndex` tracking + `relativeTarget` resolution over
/// the catalog's live (contiguous) workspace set.
struct RelativeWorkspaceTests {

    /// Catalog seeded with `n` contiguous, unnamed workspaces.
    private func seeded(_ n: Int) -> WorkspaceCatalog {
        var c = WorkspaceCatalog()
        c.seed(configs: (1...n).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        return c
    }

    // MARK: - previousActiveIndex

    @Test func previousActiveStartsNil() {
        #expect(WorkspaceCatalog().previousActiveIndex == nil)
    }

    @Test func setActiveRecordsPrevious() {
        var c = seeded(3)
        _ = c.setActive(2)
        #expect(c.previousActiveIndex == 1)
        _ = c.setActive(3)
        #expect(c.previousActiveIndex == 2)
    }

    @Test func noopSwitchKeepsPrevious() {
        var c = seeded(3)
        _ = c.setActive(2)   // prev = 1
        _ = c.setActive(2)   // no-op
        #expect(c.previousActiveIndex == 1,
                       "a no-op switch must not overwrite recent")
    }

    // MARK: - relativeTarget: next / prev (wrap)

    @Test func nextWraps() {
        var c = seeded(3)                                   // active 1
        #expect(c.relativeTarget(.next) == 2)
        _ = c.setActive(3)
        #expect(c.relativeTarget(.next) == 1)
    }

    @Test func prevWraps() {
        var c = seeded(3)                                   // active 1
        #expect(c.relativeTarget(.prev) == 3)
        _ = c.setActive(2)
        #expect(c.relativeTarget(.prev) == 1)
    }

    @Test func nextPrevNoopWithSingleWorkspace() {
        let c = seeded(1)
        #expect(c.relativeTarget(.next) == nil)
        #expect(c.relativeTarget(.prev) == nil)
    }

    // MARK: - relativeTarget: recent

    @Test func recentNilBeforeAnySwitch() {
        #expect(seeded(3).relativeTarget(.recent) == nil)
    }

    @Test func recentReturnsPreviousActive() {
        var c = seeded(3)
        _ = c.setActive(3)   // prev = 1
        #expect(c.relativeTarget(.recent) == 1)
    }

    @Test func recentSurvivesRemoveRemap() {
        // `recent` follows the previous workspace through a remove's
        // index shift rather than being lost.
        var c = seeded(4)
        _ = c.setActive(4)   // active 4, prev 1
        _ = c.removeWorkspace(2)            // positions 3,4 shift to 2,3
        // active 4 -> 3, prev 1 unchanged (below the removed slot).
        #expect(c.activeIndex == 3)
        #expect(c.relativeTarget(.recent) == 1)
    }
}
