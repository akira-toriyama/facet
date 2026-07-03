import Testing
import CoreGraphics
@testable import FacetCore

/// `readingOrder` — the shared overview reading-order sort (top→bottom,
/// left→right with row clustering) that the grid + rail now both call.
struct MiniWindowHitTests {

    private func hit(_ serverID: Int, _ rect: CGRect) -> MiniWindowHit {
        MiniWindowHit(pid: 1, id: WindowID(serverID: serverID),
                      isFocused: false, rect: rect, mark: nil)
    }

    @Test func emptyAndSinglePassThrough() {
        #expect(readingOrder([]).isEmpty)
        let one = [hit(1, CGRect(x: 0, y: 0, width: 10, height: 10))]
        #expect(readingOrder(one).map { $0.id.serverID } == [1])
    }

    @Test func ordersWithinARowLeftToRight() {
        // Same row (equal y), shuffled by x → sorted left → right.
        let wins = [
            hit(1, CGRect(x: 200, y: 0, width: 50, height: 50)),
            hit(2, CGRect(x: 0,   y: 0, width: 50, height: 50)),
            hit(3, CGRect(x: 100, y: 0, width: 50, height: 50)),
        ]
        #expect(readingOrder(wins).map { $0.id.serverID } == [2, 3, 1])
    }

    @Test func ordersRowsTopToBottom() {
        // Flipped coords: smaller y = top. Two rows, returned top row
        // first (left→right) then the bottom row.
        let wins = [
            hit(1, CGRect(x: 0,  y: 100, width: 50, height: 50)),  // bottom
            hit(2, CGRect(x: 0,  y: 0,   width: 50, height: 50)),  // top-left
            hit(3, CGRect(x: 60, y: 0,   width: 50, height: 50)),  // top-right
        ]
        #expect(readingOrder(wins).map { $0.id.serverID } == [2, 3, 1])
    }

    @Test func subPixelYDifferenceStaysSameRow() {
        // A y gap well under half the tallest window's height keeps two
        // side-by-side windows on the same row (ordered by x), so a
        // rounding wobble can't split them.
        let wins = [
            hit(1, CGRect(x: 100, y: 0.4, width: 50, height: 50)),
            hit(2, CGRect(x: 0,   y: 0,   width: 50, height: 50)),
        ]
        #expect(readingOrder(wins).map { $0.id.serverID } == [2, 1])
    }
}

/// `scaledWindowRect` — the shared window-frame → cell-rect scaler the
/// grid + rail mini-thumbnails both call (hoisted from the grid's
/// `gridScaledWindowRect`; cases mirror `GridMathTests`).
struct ScaledWindowRectTests {

    @Test func mapsFullScreenToFullCell() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cell   = CGRect(x: 100, y: 200, width: 384, height: 216)
        let mapped = scaledWindowRect(
            windowFrame: screen, screenFrame: screen, cellRect: cell)
        #expect(mapped == cell)
    }

    @Test func preservesRelativePosition() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cell   = CGRect(x: 0, y: 0, width: 192, height: 108)
        // Window at right-half of screen → right-half of cell.
        let win = CGRect(x: 960, y: 0, width: 960, height: 1080)
        let mapped = scaledWindowRect(
            windowFrame: win, screenFrame: screen, cellRect: cell)
        #expect(abs(mapped.minX - 96) < 0.01)
        #expect(abs(mapped.width - 96) < 0.01)
    }

    @Test func translatesNonZeroScreenOrigin() {
        // A secondary display's screen frame doesn't start at the
        // global origin — the window's offset is relative to the
        // screen's minX/minY, not absolute.
        let screen = CGRect(x: 1920, y: 100, width: 1920, height: 1080)
        let cell   = CGRect(x: 10, y: 20, width: 192, height: 108)
        let win    = CGRect(x: 2880, y: 640, width: 960, height: 540)
        let mapped = scaledWindowRect(
            windowFrame: win, screenFrame: screen, cellRect: cell)
        #expect(abs(mapped.minX - (10 + 96)) < 0.01)
        #expect(abs(mapped.minY - (20 + 54)) < 0.01)
        #expect(abs(mapped.width - 96) < 0.01)
        #expect(abs(mapped.height - 54) < 0.01)
    }

    @Test func returnsZeroForDegenerateScreen() {
        let mapped = scaledWindowRect(
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenFrame: .zero,
            cellRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(mapped == .zero)
    }
}
