import XCTest
@testable import FacetCore

/// `LensMembership.matches` — the SINGLE per-window lens-`match` predicate
/// shared by the tree display read-path (`FilterProjection`) and the Phase-1
/// real-hide park path (grid/rail then drop the parked windows via the
/// snapshot's `Window.isLensParked` flag). These lock the two behaviours the
/// shared predicate must guarantee: (1) it agrees with `FacetFilter.matches`
/// for ordinary window fields, and (2) it overlays the workspace NAME so
/// `workspace=` resolves (a bare `Window` can't). Pure; CI-only (CLT can't run
/// `swift test`).
final class LensMembershipTests: XCTestCase {

    // MARK: - fixtures

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = [], floating: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: floating, frame: nil, tags: tags)
    }

    /// Parse a filter or fail the test loudly (these are all hand-written
    /// valid expressions — a parse failure here is a test bug).
    private func filter(_ src: String,
                        file: StaticString = #filePath, line: UInt = #line) -> FacetFilter {
        switch FacetFilter.parse(src) {
        case .success(let f): return f
        case .failure(let e):
            XCTFail("unexpected parse failure for \(src): \(e.message)", file: file, line: line)
            return .all
        }
    }

    // MARK: - ordinary fields agree with FacetFilter.matches

    func testAppFieldMatch() {
        let f = filter("app=Safari")
        XCTAssertTrue(LensMembership.matches(win(1, app: "Safari"),
                                             inWorkspaceNamed: "Dev", filter: f))
        XCTAssertFalse(LensMembership.matches(win(2, app: "Mail"),
                                              inWorkspaceNamed: "Dev", filter: f))
    }

    func testTagContainsAndPresence() {
        let contains = filter("tag~=web")
        XCTAssertTrue(LensMembership.matches(win(1, tags: ["web", "work"]),
                                             inWorkspaceNamed: "Dev", filter: contains))
        XCTAssertFalse(LensMembership.matches(win(2, tags: ["code"]),
                                              inWorkspaceNamed: "Dev", filter: contains))

        let untagged = filter("not tag")
        XCTAssertTrue(LensMembership.matches(win(3, tags: []),
                                             inWorkspaceNamed: "Dev", filter: untagged))
        XCTAssertFalse(LensMembership.matches(win(4, tags: ["web"]),
                                              inWorkspaceNamed: "Dev", filter: untagged))
    }

    func testBooleanAndCompoundFields() {
        let f = filter("app~=Chrome and not floating")
        XCTAssertTrue(LensMembership.matches(win(1, app: "Google Chrome", floating: false),
                                             inWorkspaceNamed: "Dev", filter: f))
        XCTAssertFalse(LensMembership.matches(win(2, app: "Google Chrome", floating: true),
                                              inWorkspaceNamed: "Dev", filter: f))
        XCTAssertFalse(LensMembership.matches(win(3, app: "Mail", floating: false),
                                              inWorkspaceNamed: "Dev", filter: f))
    }

    /// For any non-workspace filter, the shared predicate must give the exact
    /// same verdict as evaluating `FacetFilter.matches` on the bare `Window`
    /// — the overlay only adds `workspace`, it never alters other fields.
    func testAgreesWithBareWindowForNonWorkspaceFields() {
        let f = filter("app=Safari or title*=Inbox")
        for w in [win(1, app: "Safari"), win(2, app: "Mail", title: "Inbox — Mail"),
                  win(3, app: "Mail", title: "Drafts")] {
            XCTAssertEqual(
                LensMembership.matches(w, inWorkspaceNamed: "Dev", filter: f),
                f.matches(w),
                "overlay changed a non-workspace verdict for window \(w.id.serverID)")
        }
    }

    // MARK: - workspace-name overlay (the reason the seam exists)

    func testWorkspaceFieldResolvesViaOverlay() {
        let f = filter("workspace=Dev")
        // Same window, two workspace names → opposite verdicts (proves the
        // name is supplied at the seam, not read off the window).
        let w = win(1, app: "Safari")
        XCTAssertTrue(LensMembership.matches(w, inWorkspaceNamed: "Dev", filter: f))
        XCTAssertFalse(LensMembership.matches(w, inWorkspaceNamed: "Web", filter: f))
    }

    func testWorkspaceCombinedWithAppField() {
        let f = filter("workspace=Dev and app=Safari")
        XCTAssertTrue(LensMembership.matches(win(1, app: "Safari"),
                                             inWorkspaceNamed: "Dev", filter: f))
        XCTAssertFalse(LensMembership.matches(win(2, app: "Safari"),
                                              inWorkspaceNamed: "Web", filter: f))
        XCTAssertFalse(LensMembership.matches(win(3, app: "Mail"),
                                              inWorkspaceNamed: "Dev", filter: f))
    }

    func testEmptyWorkspaceNameNoMatchesWorkspaceField() {
        let f = filter("workspace=Dev")
        XCTAssertFalse(LensMembership.matches(win(1), inWorkspaceNamed: "", filter: f))
    }

    /// `desktop=` stays a no-match even through the overlay (sections are
    /// already per-mac-desktop scoped, so the overlay deliberately doesn't
    /// resolve it).
    func testDesktopFieldStaysNoMatch() {
        let f = filter("desktop=1")
        XCTAssertFalse(LensMembership.matches(win(1), inWorkspaceNamed: "Dev", filter: f))
    }

    // MARK: - total / edge

    func testAllFilterMatchesEverything() {
        XCTAssertTrue(LensMembership.matches(win(1), inWorkspaceNamed: "Dev", filter: .all))
    }

    func testUnknownFieldNoMatches() {
        let f = filter("bogusField=x")
        XCTAssertFalse(LensMembership.matches(win(1), inWorkspaceNamed: "Dev", filter: f))
    }
}
