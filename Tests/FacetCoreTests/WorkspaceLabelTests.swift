import XCTest
@testable import FacetCore

/// `workspaceShortLabel` — the shared WS caption the grid / rail / tree
/// all delegate to. Mirrors the old `GridMathTests.gridLabel` cases now
/// that the logic lives in FacetCore.
final class WorkspaceLabelTests: XCTestCase {

    func testStripsWorkspacePrefixCaseInsensitive() {
        XCTAssertEqual(workspaceShortLabel(name: "WORKSPACE Q", idx: 0), "Q")
        XCTAssertEqual(workspaceShortLabel(name: "workspace alpha", idx: 0),
                       "alpha")
    }

    func testKeepsPlainNamesVerbatim() {
        XCTAssertEqual(workspaceShortLabel(name: "Code", idx: 3), "Code")
        XCTAssertEqual(workspaceShortLabel(name: "my workspace", idx: 0),
                       "my workspace")   // prefix only stripped at the head
    }

    func testEmptyNameFallsBackToOneBasedIndex() {
        XCTAssertEqual(workspaceShortLabel(name: "", idx: 0), "WS1")
        XCTAssertEqual(workspaceShortLabel(name: "", idx: 4), "WS5")
    }

    func testBarePrefixWordKept() {
        // "workspace" with no trailing label isn't long enough to strip,
        // so it's returned verbatim.
        XCTAssertEqual(workspaceShortLabel(name: "workspace", idx: 0),
                       "workspace")
        // "workspace " (trailing space, nothing after) is exactly the
        // prefix length: the `count > prefixLen` guard skips the strip so
        // the caption never goes empty. Kept verbatim by design — this
        // pins the boundary against a future drop of that guard.
        XCTAssertEqual(workspaceShortLabel(name: "workspace ", idx: 0),
                       "workspace ")
    }
}
