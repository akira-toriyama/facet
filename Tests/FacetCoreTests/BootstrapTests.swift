import XCTest
@testable import FacetCore

final class BootstrapTests: XCTestCase {
    func testVersionMarker() {
        // Sanity: the bootstrap version string is wired through.
        // Replaced once real semver is computed from git-cliff /
        // the release workflow.
        XCTAssertEqual(Facet.version, "0.0.0-bootstrap")
    }
}
