import Testing
@testable import FacetCore

/// Pure tests for the window-order ops behind swap / insert (枠C).
/// `nil` means "no change" (the caller's change-detection signal).
struct WindowOrderTests {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private func order() -> [WindowID] {
        [wid(1), wid(2), wid(3), wid(4)]
    }

    // MARK: - swap

    @Test("swap exchanges positions; same / absent → nil", arguments: [
        (a: 1, b: 4, expected: [4, 2, 3, 1] as [Int]?),  // exchange
        (a: 2, b: 2, expected: [Int]?.none),             // same window → nil
        (a: 2, b: 9, expected: [Int]?.none),             // absent window → nil
    ])
    func swapped(a: Int, b: Int, expected: [Int]?) {
        #expect(WindowOrder.swapped(order(), wid(a), wid(b))
                == expected?.map(wid))
    }

    // MARK: - insert

    @Test("insert beside target per edge; no-move / same / absent → nil", arguments: [
        // Move wid(1) to just after wid(3).
        (moving: 1, beside: 3, edge: InsertEdge.right, expected: [2, 3, 1, 4] as [Int]?),
        (moving: 4, beside: 2, edge: InsertEdge.left, expected: [1, 4, 2, 3] as [Int]?),   // left places before
        (moving: 4, beside: 2, edge: InsertEdge.top, expected: [1, 4, 2, 3] as [Int]?),    // top acts like before
        (moving: 1, beside: 3, edge: InsertEdge.bottom, expected: [2, 3, 1, 4] as [Int]?), // bottom acts like after
        // wid(2) after wid(1) — already its position.
        (moving: 2, beside: 1, edge: InsertEdge.right, expected: [Int]?.none),
        (moving: 2, beside: 2, edge: InsertEdge.left, expected: [Int]?.none),  // same window → nil
        (moving: 9, beside: 2, edge: InsertEdge.left, expected: [Int]?.none),  // absent window → nil
    ])
    func inserted(moving: Int, beside: Int, edge: InsertEdge, expected: [Int]?) {
        #expect(WindowOrder.inserted(order(), moving: wid(moving),
                                     beside: wid(beside), edge: edge)
                == expected?.map(wid))
    }
}
