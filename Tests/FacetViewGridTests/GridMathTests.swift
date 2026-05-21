import XCTest
import CoreGraphics
@testable import FacetViewGrid

/// Pure layout-math contract tests. These are the bits of the grid
/// view that are easy to break inadvertently while tuning the
/// visual numbers in `Tunables.swift`.
final class GridMathTests: XCTestCase {

    // MARK: - gridRowCount

    func testRowCountFitsOneRowForCountEqualToCols() {
        XCTAssertEqual(gridRowCount(wsCount: 4, cols: 4), 1)
    }

    func testRowCountWrapsToSecondRow() {
        XCTAssertEqual(gridRowCount(wsCount: 5, cols: 4), 2)
        XCTAssertEqual(gridRowCount(wsCount: 8, cols: 4), 2)
        XCTAssertEqual(gridRowCount(wsCount: 9, cols: 4), 3)
    }

    func testRowCountClampsToAtLeastOneEvenWhenEmpty() {
        XCTAssertEqual(gridRowCount(wsCount: 0, cols: 4), 1,
                       "1-row floor avoids /0 in downstream layout")
    }

    func testRowCountTolerantOfNonsenseCols() {
        XCTAssertEqual(gridRowCount(wsCount: 5, cols: 0), 5,
                       "cols clamps to 1, so 5 workspaces → 5 rows")
        XCTAssertEqual(gridRowCount(wsCount: 5, cols: -3), 5)
    }

    // MARK: - gridCellSize

    func testCellSizeMirrorsScreenAspect() {
        // Standard 16:9 screen, plenty of room → aspect drives.
        let s = gridCellSize(usableW: 1600, usableH: 1000,
                             cols: 2, rows: 1, screenAspect: 16.0 / 9.0)
        XCTAssertEqual(s.width / s.height,
                       16.0 / 9.0, accuracy: 0.001)
    }

    func testCellSizeShrinksWhenHeightIsTheLimit() {
        // Tall narrow region → height caps; width recomputed so the
        // aspect doesn't drift even though width could have been
        // larger.
        let s = gridCellSize(usableW: 4000, usableH: 200,
                             cols: 1, rows: 1, screenAspect: 16.0 / 9.0)
        XCTAssertLessThanOrEqual(s.height, 200)
        XCTAssertEqual(s.width / s.height,
                       16.0 / 9.0, accuracy: 0.001)
    }

    func testCellSizeNeverNegative() {
        // Useable area smaller than the inter-cell gap budget — pure
        // math fallback (max(1, …)) keeps values positive.
        let s = gridCellSize(usableW: 1, usableH: 1,
                             cols: 4, rows: 4, screenAspect: 1)
        XCTAssertGreaterThan(s.width, 0)
        XCTAssertGreaterThan(s.height, 0)
    }

    // MARK: - gridScaledWindowRect

    func testScaledWindowRectMapsFullScreenToFullCell() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cell   = CGRect(x: 100, y: 200, width: 384, height: 216)
        let win    = screen
        let mapped = gridScaledWindowRect(
            windowFrame: win, screenFrame: screen, cellRect: cell)
        XCTAssertEqual(mapped, cell)
    }

    func testScaledWindowRectPreservesRelativePosition() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cell   = CGRect(x: 0, y: 0, width: 192, height: 108)
        // Window at right-half of screen → right-half of cell.
        let win = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let mapped = gridScaledWindowRect(
            windowFrame: win, screenFrame: screen, cellRect: cell)
        XCTAssertEqual(mapped.minX, 96, accuracy: 0.01)
        XCTAssertEqual(mapped.width, 96, accuracy: 0.01)
    }

    func testScaledWindowRectReturnsZeroForDegenerateScreen() {
        let mapped = gridScaledWindowRect(
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenFrame: .zero,
            cellRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(mapped, .zero)
    }

    // MARK: - gridLabel

    func testGridLabelStripsWorkspacePrefix() {
        XCTAssertEqual(gridLabel(name: "WORKSPACE Q", idx: 0), "Q")
        XCTAssertEqual(gridLabel(name: "workspace alpha", idx: 0),
                       "alpha")
    }

    func testGridLabelKeepsNonPrefixedNames() {
        XCTAssertEqual(gridLabel(name: "Code", idx: 3), "Code")
    }

    func testGridLabelFallsBackToWsN() {
        XCTAssertEqual(gridLabel(name: "", idx: 0), "WS1")
        XCTAssertEqual(gridLabel(name: "", idx: 4), "WS5")
    }

    func testGridLabelDoesNotStripLoneWord() {
        // "workspace" alone (no following content) → return as-is so
        // the user's literal name still shows.
        XCTAssertEqual(gridLabel(name: "workspace", idx: 0),
                       "workspace")
    }
}
