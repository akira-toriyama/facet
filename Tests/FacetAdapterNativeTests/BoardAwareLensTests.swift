import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// W2.5-adapter (t-wrd2): the native adapter's lens-id resolution is BOARD-
/// AWARE. A board-minted lens id `section:<declOrder>:<label>` indexes the
/// SELECTED board's section list (the SAME list `FilterProjection` enumerated
/// to mint it), NOT the flat `[[desktop.N.section]]` list. The Controller
/// pushes the session-selected board through `setSelectedBoard(_:
/// forMacDesktopOrdinal:)`; `lensSection(forID:)` then resolves against
/// `activeBoardSections(...)` for that board. A flat config (no
/// `[[desktop.N.tab]]` boards) stays byte-identical — the board defaults to 0,
/// which degrades to the flat list.
///
/// `setSelectedBoard` / `setSectionLens` carry `dispatchPrecondition(.onQueue(
/// cliQueue))`, so every mutation is wrapped in `cliQueue.sync { … }` (the CI
/// debug build aborts otherwise). `currentActiveSection()` is a plain lock read.
final class BoardAwareLensTests: XCTestCase {

    private func ws(_ label: String) -> DesktopSection {
        DesktopSection(type: .workspace, label: label)
    }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }

    /// Adapter on ordinal 1 whose config carries TWO boards: a workspace board
    /// ("Spaces" → [Main]) and a lens board ("Views" → [Web]). The "Web" lens is
    /// declOrder 0 WITHIN its board, so its stable id is `section:0:Web` — an id
    /// that does NOT resolve against board 0's sections (a workspace at declOrder
    /// 0), which makes the board scope discriminating.
    private func twoBoardAdapter() -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, label: "Spaces", sections: [ws("Main")]),
            DesktopTab(type: .lens, label: "Views", sections: [lens("Web", "app=Web")]),
        ]]
        cfg.defaultLayout = "master-left"
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        a.catalog.reconcile(live: [window(10, appName: "Web"), window(30, appName: "A")])
        return a
    }

    /// declOrder 0 within the lens board — the id `FilterProjection` mints when
    /// the lens board is the active board.
    private let webLensID = "section:0:Web"

    // MARK: - lensSection resolves against the SELECTED board

    func testLensSectionNilOnDefaultBoard() {
        // Board 0 (default, unset) is the WORKSPACE board — declOrder 0 there is
        // a workspace, not a lens — so the lens id does not resolve (fail-safe:
        // a cross-board lens id is never silently mis-resolved).
        let a = twoBoardAdapter()
        cliQueue.sync {
            XCTAssertNil(a.lensSection(forID: webLensID))
        }
    }

    func testLensSectionResolvesOnSelectedLensBoard() {
        let a = twoBoardAdapter()
        cliQueue.sync {
            a.setSelectedBoard(1, forMacDesktopOrdinal: 1)
            XCTAssertEqual(a.lensSection(forID: webLensID)?.label, "Web")
        }
    }

    // MARK: - end-to-end: activating a lens on the selected board

    func testActivateLensOnSelectedBoardReflectsInMirror() {
        let a = twoBoardAdapter()
        cliQueue.sync {
            a.setSelectedBoard(1, forMacDesktopOrdinal: 1)
            a.setSectionLens(webLensID, autoFocus: false)
        }
        XCTAssertEqual(a.currentActiveSection(), .lens(webLensID))
    }

    func testActivateLensRejectedOnWrongBoard() {
        // Without selecting the lens board, the board-0 (workspace) scope can't
        // resolve the lens id → loud reject, the lens stays unset.
        let a = twoBoardAdapter()
        cliQueue.sync { a.setSectionLens(webLensID, autoFocus: false) }
        XCTAssertEqual(a.currentActiveSection(), .workspace(1))
    }

    // MARK: - flat config regression (no boards → board 0 → flat list)

    func testFlatConfigLensStillResolves() {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [1: [
            ws("Dev"),
            lens("Web", "app=Web"),   // declOrder 1 in the flat list
        ]]
        cfg.defaultLayout = "master-left"
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        a.catalog.reconcile(live: [window(10, appName: "Web"), window(30, appName: "A")])

        let flatLensID = "section:1:Web"
        cliQueue.sync { a.setSectionLens(flatLensID, autoFocus: false) }
        XCTAssertEqual(a.currentActiveSection(), .lens(flatLensID))
    }
}
