import Testing
import CoreGraphics
@testable import FacetCore

/// Pure geometry for the rail's board switcher band (t-wrd2 rail slice):
/// `railInset` (carve the band's sliver off the top) + `railBoardBand` (band rect
/// + per-board tab rects). The band is a horizontal tab row pinned to the screen
/// TOP on every dock edge. All rects in the rail view's FLIPPED (y-down) space.
struct RailBoardBandTests {

    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    // MARK: - railInset (always carves off the top)

    @Test func railInsetCarvesFromTop() {
        #expect(railInset(bounds, by: 30) ==
                       CGRect(x: 0, y: 30, width: 1600, height: 970))
    }

    /// The visibility-gate guarantee: 0 inset is the identity ⇒ a < 2-board
    /// (flat) rail lays out byte-identically to today.
    @Test func railInsetZeroIsIdentity() {
        #expect(railInset(bounds, by: 0) == bounds)
    }

    // MARK: - railBoardBand: a horizontal tab row at the screen top

    @Test func bandAtTop() {
        let (band, cells) = railBoardBand(
            in: bounds, boardCount: 2,
            thickness: 30, tabWidths: [80, 80], gap: 4, innerPad: 8)
        #expect(band == CGRect(x: 0, y: 0, width: 1600, height: 30))
        #expect(cells.count == 2)
        #expect(cells[0] == RailBoardCellFrame(
            boardIndex: 0, rect: CGRect(x: 8, y: 0, width: 80, height: 30)))
        #expect(cells[1] == RailBoardCellFrame(
            boardIndex: 1, rect: CGRect(x: 92, y: 0, width: 80, height: 30)))
    }

    /// Overflow delegates to `boardTabLayout` (uniform shrink), same as the tree.
    @Test func overflowUniformShrink() {
        let (_, cells) = railBoardBand(
            in: CGRect(x: 0, y: 0, width: 200, height: 1000),
            boardCount: 3, thickness: 30, tabWidths: [200, 200, 200],
            gap: 4, innerPad: 8)
        // available = 200 - 16 = 184; uniform cellW = (184 - 8) / 3 = 58.666…
        let cellW = (184.0 - 8) / 3
        #expect(cells.count == 3)
        for c in cells { #expect(abs(c.rect.width - cellW) < 0.001) }
    }

    // MARK: - degrade

    @Test func degradeBelowTwoBoards() {
        let (band, cells) = railBoardBand(
            in: bounds, boardCount: 1,
            thickness: 30, tabWidths: [80], gap: 4, innerPad: 8)
        #expect(band == .zero)
        #expect(cells.isEmpty)
    }

    @Test func degradeZeroThickness() {
        let (band, cells) = railBoardBand(
            in: bounds, boardCount: 2,
            thickness: 0, tabWidths: [80, 80], gap: 4, innerPad: 8)
        #expect(band == .zero)
        #expect(cells.isEmpty)
    }
}
