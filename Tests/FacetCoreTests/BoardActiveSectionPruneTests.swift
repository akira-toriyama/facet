import Testing
@testable import FacetCore

/// `FacetConfig.prunedBoardActiveSections(_:fallback:)` — the B1 (t-1rck)
/// hot-reload sweep that drops a per-board remembered `.lens(id)` once the
/// edited config no longer resolves it on its OWN board, so a stale highlight
/// can't relight when the user switches BACK to that board. It mirrors the
/// per-id validity the ACTIVE board already gets in `reloadConfig`, extended to
/// every non-active board. Pure FacetCore; CI-only (CLT can't run `swift test`).
struct BoardActiveSectionPruneTests {

    // MARK: - fixtures

    private func ws(_ label: String) -> DesktopSection {
        DesktopSection(type: .workspace, label: label)
    }
    private func lens(_ label: String, _ match: String = "tag~=x") -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }
    /// A mac desktop (ordinal 1) with two boards, each carrying the given
    /// sections. `id` for a lens at decl-order `k` is `"section:k:<label>"`.
    private func cfg(board0: [DesktopSection], board1: [DesktopSection]) -> FacetConfig {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .lens, label: "A", sections: board0),
            DesktopTab(type: .lens, label: "B", sections: board1),
        ]]
        return c
    }
    private let fallback = ActiveSection.workspace(2)

    // MARK: - core behaviour

    /// A still-resolving lens is kept; one whose id no longer resolves on its
    /// own board is dropped to the fallback (the exact bug: a stale lens stored
    /// for a non-active board).
    @Test func dropsStaleKeepsValid() {
        let c = cfg(board0: [lens("Web")], board1: [lens("Code")])
        let map: [Int: [Int: ActiveSection]] = [1: [
            0: .lens("section:0:Web"),      // resolves on board 0 → kept
            1: .lens("section:9:Gone"),     // decl-order past board 1 → dropped
        ]]
        let out = c.prunedBoardActiveSections(map, fallback: fallback)
        #expect(out.pruned[1]?[0] == .lens("section:0:Web"))
        #expect(out.pruned[1]?[1] == fallback)
        #expect(out.dropped ==
                       [FacetConfig.DroppedBoardLens(ordinal: 1, board: 1,
                                                     id: "section:9:Gone")])
    }

    /// A `.lens(id)` whose decl-order now lands on a WORKSPACE section (a config
    /// reorder) is dropped — `ApplyResolver.section` rejects a non-lens slot.
    @Test func reorderOntoWorkspaceDrops() {
        let c = cfg(board0: [ws("Main"), lens("Web")], board1: [lens("Code")])
        // decl-order 0 used to be the lens but is now the workspace "Main".
        let map: [Int: [Int: ActiveSection]] = [1: [0: .lens("section:0:Web")]]
        let out = c.prunedBoardActiveSections(map, fallback: fallback)
        #expect(out.pruned[1]?[0] == fallback)
        #expect(out.dropped.count == 1)
    }

    /// A renamed lens at the same decl-order (label-suffix mismatch) drops.
    @Test func labelMismatchDrops() {
        let c = cfg(board0: [lens("WebRenamed")], board1: [lens("Code")])
        let map: [Int: [Int: ActiveSection]] = [1: [0: .lens("section:0:Web")]]
        let out = c.prunedBoardActiveSections(map, fallback: fallback)
        #expect(out.pruned[1]?[0] == fallback)
    }

    /// `.workspace` entries are never validated — only lenses can go stale.
    @Test func workspaceEntriesUntouched() {
        let c = cfg(board0: [lens("Web")], board1: [lens("Code")])
        let map: [Int: [Int: ActiveSection]] = [1: [0: .workspace(5), 1: .workspace(7)]]
        let out = c.prunedBoardActiveSections(map, fallback: fallback)
        #expect(out.pruned == map)
        #expect(out.dropped.isEmpty)
    }

    /// An all-valid map is returned unchanged with no drops (no needless churn).
    @Test func allValidUnchanged() {
        let c = cfg(board0: [lens("Web")], board1: [lens("Code")])
        let map: [Int: [Int: ActiveSection]] = [1: [
            0: .lens("section:0:Web"),
            1: .lens("section:0:Code"),
        ]]
        let out = c.prunedBoardActiveSections(map, fallback: fallback)
        #expect(out.pruned == map)
        #expect(out.dropped.isEmpty)
    }

    /// Empty map → empty result.
    @Test func emptyMap() {
        let c = cfg(board0: [lens("Web")], board1: [lens("Code")])
        let out = c.prunedBoardActiveSections([:], fallback: fallback)
        #expect(out.pruned.isEmpty)
        #expect(out.dropped.isEmpty)
    }

    /// Drops are reported in deterministic (ordinal, board)-sorted order so the
    /// log line and these assertions stay stable across dictionary iteration.
    @Test func droppedOrderDeterministic() {
        let c = cfg(board0: [lens("Web")], board1: [lens("Code")])
        // Insert board 1 before board 0; both ids point past their sections.
        let map: [Int: [Int: ActiveSection]] = [1: [
            1: .lens("section:9:Z"),
            0: .lens("section:9:Y"),
        ]]
        let out = c.prunedBoardActiveSections(map, fallback: fallback)
        #expect(out.dropped.map(\.board) == [0, 1])
    }

    /// A board with no `[[desktop.N.tab]]` definition degrades to the flat
    /// section list, so a flat lens id still resolves there (no spurious drop).
    @Test func flatDegradeStillResolves() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [lens("Web")]]   // flat, no boards
        let map: [Int: [Int: ActiveSection]] = [1: [0: .lens("section:0:Web")]]
        let out = c.prunedBoardActiveSections(map, fallback: fallback)
        #expect(out.pruned[1]?[0] == .lens("section:0:Web"))
        #expect(out.dropped.isEmpty)
    }
}
