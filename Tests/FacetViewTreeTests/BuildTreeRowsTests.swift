import XCTest
import FacetCore
@testable import FacetViewTree

final class BuildTreeRowsTests: XCTestCase {
    func testCompositeIDDistinguishesSameWindowInTwoGroups() {
        let wid = WindowID(serverID: 42)
        let a = TreeItemID.window(group: 0, wid)
        let b = TreeItemID.window(group: 1, wid)
        XCTAssertNotEqual(a, b)                       // same window, two sections
        XCTAssertEqual(a, .window(group: 0, wid))     // stable
        XCTAssertNotEqual(TreeItemID.header("ws:0"), .header("ws:1"))
    }
}
