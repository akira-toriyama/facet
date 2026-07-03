import Testing
@testable import FacetCore

/// `FacetConfig.activeBoardSections(forMacDesktopOrdinal:board:)` — the board
/// SELECTOR (t-wrd2 / W2.2). The board layer is a transparent picker over the
/// SAME section model `FilterProjection` already consumes: given a session-
/// selected board index it returns that board's child sections, and with NO
/// `[[desktop.N.tab]]` boards it DEGRADES to the flat `[[desktop.N.section]]`
/// list — byte-identical to the pre-board path (the W2.2 invariant). Pure
/// FacetCore; CI-only (CLT can't run `swift test`).
struct DesktopBoardSelectTests {

    // MARK: - fixtures

    private func ws(_ label: String) -> DesktopSection {
        DesktopSection(type: .workspace, label: label)
    }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }
    private func liveWS(_ index: Int, _ name: String) -> Workspace {
        Workspace(index: index, name: name, isActive: index == 0,
                  layoutMode: "float", windows: [])
    }

    // MARK: - degrade: no boards → flat sections (byte-identical to today)

    /// With no `[[desktop.N.tab]]` boards, the selector returns the flat
    /// `[[desktop.N.section]]` list verbatim — the board index is irrelevant.
    @Test func zeroTabsDegradesToFlatSections() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [ws("Code"), lens("Web", "tag~=web")]]
        #expect(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 0) ==
                       [ws("Code"), lens("Web", "tag~=web")])
        // A non-zero board with no boards present still degrades to flat.
        #expect(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 7) ==
                       [ws("Code"), lens("Web", "tag~=web")])
    }

    /// Neither boards nor flat sections for the ordinal → empty.
    @Test func noBoardsAndNoFlatReturnsEmpty() {
        let c = FacetConfig()
        #expect(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 0) == [])
    }

    /// A nil ordinal (SkyLight unavailable / single-desktop) → empty, like the
    /// flat-section reads that key off the ordinal.
    @Test func nilOrdinalReturnsEmpty() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [ws("Code")]]
        #expect(c.activeBoardSections(forMacDesktopOrdinal: nil, board: 0) == [])
    }

    // MARK: - board selection

    private func twoBoardConfig() -> FacetConfig {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, label: "Spaces",
                       sections: [ws("Main"), ws("Side")]),
            DesktopTab(type: .lens, label: "Views",
                       sections: [lens("Web", "tag~=web")]),
        ]]
        return c
    }

    private func threeBoardConfig() -> FacetConfig {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, label: "Alpha",
                       sections: [ws("A1"), ws("A2")]),
            DesktopTab(type: .workspace, label: "Beta",
                       sections: [ws("B1")]),
            DesktopTab(type: .lens, label: "Gamma",
                       sections: [lens("G", "tag~=g")]),
        ]]
        return c
    }

    /// Board 0 (the default) → the first board's child sections.
    @Test func boardZeroIsFirstBoardSections() {
        #expect(
            twoBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: 0) ==
            [ws("Main"), ws("Side")])
    }

    /// Board 1 → the second board's child sections.
    @Test func boardOneIsSecondBoardSections() {
        #expect(
            twoBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: 1) ==
            [lens("Web", "tag~=web")])
    }

    /// An out-of-range high board index clamps to the LAST board (a stale
    /// selection after a hot-reload that dropped boards never crashes / blanks).
    @Test func boardIndexClampedHighToLastBoard() {
        #expect(
            twoBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: 99) ==
            [lens("Web", "tag~=web")])
    }

    /// A negative board index clamps to board 0.
    @Test func negativeBoardIndexClampedToZero() {
        #expect(
            twoBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: -5) ==
            [ws("Main"), ws("Side")])
    }

    /// When BOTH boards and a flat list exist for an ordinal (a contrived
    /// mixed config), the boards win — the board layer is authoritative once
    /// present.
    @Test func boardsTakePrecedenceOverFlatWhenBothPresent() {
        var c = twoBoardConfig()
        c.macDesktopSectionConfigs = [1: [ws("FlatOnly")]]
        #expect(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 0) ==
                       [ws("Main"), ws("Side")])
    }

    // MARK: - byte-一致: a board's projection == the equivalent flat config

    /// W2.2 invariant — a SINGLE workspace board projects byte-identically to a
    /// flat `[[desktop.N.section]]` config carrying the same sections. The board
    /// wrapper is transparent: selecting it changes nothing downstream.
    @Test func singleBoardProjectsLikeEquivalentFlat() {
        let sections = [ws("Main"), ws("Side")]
        var boardCfg = FacetConfig()
        boardCfg.macDesktopTabConfigs =
            [1: [DesktopTab(type: .workspace, label: "Spaces", sections: sections)]]
        var flatCfg = FacetConfig()
        flatCfg.macDesktopSectionConfigs = [1: sections]

        let resolved = boardCfg.activeBoardSections(forMacDesktopOrdinal: 1, board: 0)
        // Discriminating: the board must actually carry its sections (not blank).
        #expect(resolved == sections)
        #expect(resolved ==
                       flatCfg.activeBoardSections(forMacDesktopOrdinal: 1, board: 0))

        let wss = [liveWS(0, "Main"), liveWS(1, "Side")]
        #expect(
            FilterProjection.project(
                workspaces: wss,
                sections: boardCfg.activeBoardSections(forMacDesktopOrdinal: 1, board: 0)) ==
            FilterProjection.project(workspaces: wss, sections: sections))
    }

    /// W2.2 invariant — selecting a single board OUT OF a two-board config
    /// projects byte-identically to a flat config of just that board's sections.
    @Test func selectedBoardProjectsLikeFlatOfThatBoard() {
        let board1Sections = [lens("Web", "tag~=web")]
        let wss = [liveWS(0, "Main")]
        #expect(
            FilterProjection.project(
                workspaces: wss,
                sections: twoBoardConfig()
                    .activeBoardSections(forMacDesktopOrdinal: 1, board: 1)) ==
            FilterProjection.project(workspaces: wss, sections: board1Sections))
    }

    // MARK: - clamp at a MIDDLE / boundary index (T1, t-8p46)
    //
    // The 2-board fixtures above only exercise board 0 and board 1 — and with
    // two boards, board 1 IS the last, so the clamp's internal `min(board,
    // count - 1)` is only ever hit at its ceiling. A `min(board, count)`
    // off-by-one would slip through every test above (board 1 of 2 still
    // resolves). These pin the interior + the one-past-end boundary with THREE
    // boards, where `count - 1` (= 2) and `count` (= 3) actually differ.

    /// Board 1 of THREE is a genuine MIDDLE index: the clamp returns `board`
    /// unchanged (not the last), so this exercises `0 ..< count-1` — untrodden
    /// by the 2-board fixtures. An off-by-one `min(board, count)` would still
    /// pass here, but `testBoardOnePastEndClampsToLast` catches it.
    @Test func middleBoardOfThreeSelected() {
        #expect(
            threeBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: 1) ==
            [ws("B1")])
    }

    /// `board == count` (one past the end) clamps to the LAST board — NOT off
    /// the end. This is the test that would CRASH (index out of range) under a
    /// `min(board, count)` off-by-one, and it pins that `count` and `count - 1`
    /// resolve to the same last board.
    @Test func boardOnePastEndClampsToLast() {
        let c = threeBoardConfig()                            // count == 3
        #expect(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 3) ==
                       [lens("G", "tag~=g")])                 // one past end → last
        #expect(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 2) ==
                       [lens("G", "tag~=g")])                 // last in-range → last
    }

    /// A selected board whose child-section list is EMPTY returns `[]` via the
    /// BOARD branch — a DIFFERENT path from `testNoBoardsAndNoFlatReturnsEmpty`
    /// (the no-tabs degrade). Here tabs ARE present (a non-empty tab list), so the
    /// board branch is taken and returns the selected board's own (empty)
    /// sections; it never falls through to the flat `?? []`.
    @Test func emptySelectedBoardReturnsEmpty() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, label: "Full", sections: [ws("Main")]),
            DesktopTab(type: .workspace, label: "Empty", sections: []),
        ]]
        #expect(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 1) == [])
        // Board 0 (non-empty) still resolves — proving it's the SELECTION that is
        // empty, not the whole tab list (which would hit the no-tabs path).
        #expect(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 0) ==
                       [ws("Main")])
    }

    // MARK: - workspace board: surplus live workspaces tail (T3, t-8p46)

    /// A workspace board declaring FEWER workspace sections than there are live
    /// workspaces: the surplus live workspace tails the board's workspace-section
    /// run (the dynamic `facet workspace --add` case). `FilterProjection`'s tail
    /// is covered for a FLAT list (`FilterProjectionTests`); this pins the board →
    /// `FilterProjection.project` composition end-to-end — the 3rd live workspace
    /// tails with its wire `sourceWorkspaceIndex == 2`.
    @Test func workspaceBoardWithExtraLiveWorkspacesTails() {
        var c = FacetConfig()
        c.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, label: "Spaces",
                       sections: [ws("S1"), ws("S2")]),
        ]]
        let live = [liveWS(0, "Dev"), liveWS(1, "Web"), liveWS(2, "Extra")]
        let r = FilterProjection.project(
            workspaces: live,
            sections: c.activeBoardSections(forMacDesktopOrdinal: 1, board: 0))
        #expect(r.sections.count == 3, "2 declared + 1 surplus live = 3")
        #expect(r.sections.map(\.sourceWorkspaceIndex) == [0, 1, 2])
        #expect(r.sections[2].id == "ws:2")
        #expect(r.sections[2].label == "Extra")
        #expect(r.sections[2].sectionType == .workspace)
    }
}
