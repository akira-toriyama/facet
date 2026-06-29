import XCTest
@testable import FacetCore

/// `FacetConfig.activeBoardSections(forMacDesktopOrdinal:board:)` — the board
/// SELECTOR (t-wrd2 / W2.2). The board layer is a transparent picker over the
/// SAME section model `FilterProjection` already consumes: given a session-
/// selected board index it returns that board's child sections, and with NO
/// `[[desktop.N.tab]]` boards it DEGRADES to the flat `[[desktop.N.section]]`
/// list — byte-identical to the pre-board path (the W2.2 invariant). Pure
/// FacetCore; CI-only (CLT can't run `swift test`).
final class DesktopBoardSelectTests: XCTestCase {

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
    func testZeroTabsDegradesToFlatSections() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [ws("Code"), lens("Web", "tag~=web")]]
        XCTAssertEqual(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 0),
                       [ws("Code"), lens("Web", "tag~=web")])
        // A non-zero board with no boards present still degrades to flat.
        XCTAssertEqual(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 7),
                       [ws("Code"), lens("Web", "tag~=web")])
    }

    /// Neither boards nor flat sections for the ordinal → empty.
    func testNoBoardsAndNoFlatReturnsEmpty() {
        let c = FacetConfig()
        XCTAssertEqual(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 0), [])
    }

    /// A nil ordinal (SkyLight unavailable / single-desktop) → empty, like the
    /// flat-section reads that key off the ordinal.
    func testNilOrdinalReturnsEmpty() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [ws("Code")]]
        XCTAssertEqual(c.activeBoardSections(forMacDesktopOrdinal: nil, board: 0), [])
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

    /// Board 0 (the default) → the first board's child sections.
    func testBoardZeroIsFirstBoardSections() {
        XCTAssertEqual(
            twoBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: 0),
            [ws("Main"), ws("Side")])
    }

    /// Board 1 → the second board's child sections.
    func testBoardOneIsSecondBoardSections() {
        XCTAssertEqual(
            twoBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: 1),
            [lens("Web", "tag~=web")])
    }

    /// An out-of-range high board index clamps to the LAST board (a stale
    /// selection after a hot-reload that dropped boards never crashes / blanks).
    func testBoardIndexClampedHighToLastBoard() {
        XCTAssertEqual(
            twoBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: 99),
            [lens("Web", "tag~=web")])
    }

    /// A negative board index clamps to board 0.
    func testNegativeBoardIndexClampedToZero() {
        XCTAssertEqual(
            twoBoardConfig().activeBoardSections(forMacDesktopOrdinal: 1, board: -5),
            [ws("Main"), ws("Side")])
    }

    /// When BOTH boards and a flat list exist for an ordinal (a contrived
    /// mixed config), the boards win — the board layer is authoritative once
    /// present.
    func testBoardsTakePrecedenceOverFlatWhenBothPresent() {
        var c = twoBoardConfig()
        c.macDesktopSectionConfigs = [1: [ws("FlatOnly")]]
        XCTAssertEqual(c.activeBoardSections(forMacDesktopOrdinal: 1, board: 0),
                       [ws("Main"), ws("Side")])
    }

    // MARK: - byte-一致: a board's projection == the equivalent flat config

    /// W2.2 invariant — a SINGLE workspace board projects byte-identically to a
    /// flat `[[desktop.N.section]]` config carrying the same sections. The board
    /// wrapper is transparent: selecting it changes nothing downstream.
    func testSingleBoardProjectsLikeEquivalentFlat() {
        let sections = [ws("Main"), ws("Side")]
        var boardCfg = FacetConfig()
        boardCfg.macDesktopTabConfigs =
            [1: [DesktopTab(type: .workspace, label: "Spaces", sections: sections)]]
        var flatCfg = FacetConfig()
        flatCfg.macDesktopSectionConfigs = [1: sections]

        let resolved = boardCfg.activeBoardSections(forMacDesktopOrdinal: 1, board: 0)
        // Discriminating: the board must actually carry its sections (not blank).
        XCTAssertEqual(resolved, sections)
        XCTAssertEqual(resolved,
                       flatCfg.activeBoardSections(forMacDesktopOrdinal: 1, board: 0))

        let wss = [liveWS(0, "Main"), liveWS(1, "Side")]
        XCTAssertEqual(
            FilterProjection.project(
                workspaces: wss,
                sections: boardCfg.activeBoardSections(forMacDesktopOrdinal: 1, board: 0)),
            FilterProjection.project(workspaces: wss, sections: sections))
    }

    /// W2.2 invariant — selecting a single board OUT OF a two-board config
    /// projects byte-identically to a flat config of just that board's sections.
    func testSelectedBoardProjectsLikeFlatOfThatBoard() {
        let board1Sections = [lens("Web", "tag~=web")]
        let wss = [liveWS(0, "Main")]
        XCTAssertEqual(
            FilterProjection.project(
                workspaces: wss,
                sections: twoBoardConfig()
                    .activeBoardSections(forMacDesktopOrdinal: 1, board: 1)),
            FilterProjection.project(workspaces: wss, sections: board1Sections))
    }
}
