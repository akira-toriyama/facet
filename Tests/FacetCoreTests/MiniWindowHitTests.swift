import XCTest
import CoreGraphics
@testable import FacetCore

/// `readingOrder` — the shared overview reading-order sort (top→bottom,
/// left→right with row clustering) that the grid + rail now both call.
final class MiniWindowHitTests: XCTestCase {

    private func hit(_ serverID: Int, _ rect: CGRect) -> MiniWindowHit {
        MiniWindowHit(pid: 1, id: WindowID(serverID: serverID),
                      isFocused: false, rect: rect, mark: nil, tags: [])
    }

    func testEmptyAndSinglePassThrough() {
        XCTAssertTrue(readingOrder([]).isEmpty)
        let one = [hit(1, CGRect(x: 0, y: 0, width: 10, height: 10))]
        XCTAssertEqual(readingOrder(one).map { $0.id.serverID }, [1])
    }

    func testOrdersWithinARowLeftToRight() {
        // Same row (equal y), shuffled by x → sorted left → right.
        let wins = [
            hit(1, CGRect(x: 200, y: 0, width: 50, height: 50)),
            hit(2, CGRect(x: 0,   y: 0, width: 50, height: 50)),
            hit(3, CGRect(x: 100, y: 0, width: 50, height: 50)),
        ]
        XCTAssertEqual(readingOrder(wins).map { $0.id.serverID }, [2, 3, 1])
    }

    func testOrdersRowsTopToBottom() {
        // Flipped coords: smaller y = top. Two rows, returned top row
        // first (left→right) then the bottom row.
        let wins = [
            hit(1, CGRect(x: 0,  y: 100, width: 50, height: 50)),  // bottom
            hit(2, CGRect(x: 0,  y: 0,   width: 50, height: 50)),  // top-left
            hit(3, CGRect(x: 60, y: 0,   width: 50, height: 50)),  // top-right
        ]
        XCTAssertEqual(readingOrder(wins).map { $0.id.serverID }, [2, 3, 1])
    }

    func testSubPixelYDifferenceStaysSameRow() {
        // A y gap well under half the tallest window's height keeps two
        // side-by-side windows on the same row (ordered by x), so a
        // rounding wobble can't split them.
        let wins = [
            hit(1, CGRect(x: 100, y: 0.4, width: 50, height: 50)),
            hit(2, CGRect(x: 0,   y: 0,   width: 50, height: 50)),
        ]
        XCTAssertEqual(readingOrder(wins).map { $0.id.serverID }, [2, 1])
    }
}
