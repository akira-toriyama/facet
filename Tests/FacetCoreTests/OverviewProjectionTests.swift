import XCTest
@testable import FacetCore

/// `OverviewProjection` — narrow each workspace's windows to the active lens
/// (the grid/rail filter, PR7). The workspace set is INVARIANT (same count /
/// order / index / name / layout); only `windows` is filtered, so the cell
/// count never changes ("lens narrows, never re-bundles / drops a cell").
/// Degrade (no active lens) returns workspaces verbatim; a malformed /
/// unknown-field match shows everything + a loud-but-non-fatal diagnostic.
/// Pure; CI-only (CLT can't run `swift test`).
final class OverviewProjectionTests: XCTestCase {

    // MARK: - fixtures

    private func win(_ id: Int, app: String = "App", title: String = "",
                     tags: [String] = [], floating: Bool = false) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: title,
               isFocused: false, isFloating: floating, frame: nil, tags: tags)
    }

    private func ws(_ index: Int, name: String, windows: [Window],
                    active: Bool = false) -> Workspace {
        Workspace(index: index, name: name, isActive: active,
                  layoutMode: "bsp", windows: windows)
    }

    private func ids(_ r: OverviewProjection.Result) -> [[Int]] {
        r.workspaces.map { $0.windows.map(\.id.serverID) }
    }

    // MARK: - degrade (no active lens → verbatim, byte-identical)

    func testNilMatchReturnsVerbatim() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1), win(2)]),
            ws(1, name: "Web", windows: [win(3)]),
        ]
        let r = OverviewProjection.filterWorkspaces(wss, byLensMatch: nil)
        XCTAssertTrue(r.diagnostics.isEmpty)
        XCTAssertEqual(ids(r), [[1, 2], [3]])
    }

    func testEmptyMatchReturnsVerbatim() {
        let wss = [ws(0, name: "Dev", windows: [win(1), win(2)])]
        let r = OverviewProjection.filterWorkspaces(wss, byLensMatch: "")
        XCTAssertTrue(r.diagnostics.isEmpty)
        XCTAssertEqual(ids(r), [[1, 2]])
    }

    // MARK: - narrowing (cell count invariant)

    /// A valid match narrows each workspace's windows but keeps EVERY
    /// workspace — including one with zero matches (its cell survives, empty).
    func testNarrowsWindowsKeepsAllWorkspaces() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1, tags: ["web"]), win(2, tags: ["code"])]),
            ws(1, name: "Web", windows: [win(3, tags: ["web"])]),
            ws(2, name: "Empty", windows: [win(4, tags: ["code"])]),
        ]
        let r = OverviewProjection.filterWorkspaces(wss, byLensMatch: "tag~=web")
        XCTAssertTrue(r.diagnostics.isEmpty)
        XCTAssertEqual(r.workspaces.count, 3)            // cell count invariant
        XCTAssertEqual(ids(r), [[1], [3], []])           // ws 2 kept, now empty
    }

    /// The workspace identity fields survive verbatim — only `windows` change.
    func testPreservesWorkspaceIdentity() {
        let wss = [ws(5, name: "Dev", windows: [win(1, app: "Safari"), win(2, app: "Code")],
                      active: true)]
        let r = OverviewProjection.filterWorkspaces(wss, byLensMatch: "app=Safari")
        let out = r.workspaces[0]
        XCTAssertEqual(out.index, 5)
        XCTAssertEqual(out.name, "Dev")
        XCTAssertTrue(out.isActive)
        XCTAssertEqual(out.layoutMode, "bsp")
        XCTAssertEqual(out.windows.map(\.id.serverID), [1])
    }

    /// `workspace=` resolves via the seam overlay (a `Window` alone can't):
    /// only windows whose containing workspace is `Dev` survive.
    func testWorkspaceFieldOverlay() {
        let wss = [
            ws(0, name: "Dev", windows: [win(1), win(2)]),
            ws(1, name: "Web", windows: [win(3)]),
        ]
        let r = OverviewProjection.filterWorkspaces(wss, byLensMatch: "workspace=Dev")
        XCTAssertTrue(r.diagnostics.isEmpty)
        XCTAssertEqual(ids(r), [[1, 2], []])
    }

    func testEmptyWorkspacesNarrowsToEmpty() {
        let r = OverviewProjection.filterWorkspaces([], byLensMatch: "tag~=x")
        XCTAssertTrue(r.workspaces.isEmpty)
        XCTAssertTrue(r.diagnostics.isEmpty)
    }

    // MARK: - loud-but-non-fatal (broken filter shows everything)

    /// A malformed `match` must NOT empty the overview: workspaces pass
    /// through verbatim (everything visible) + a parse-error diagnostic.
    func testMalformedMatchShowsEverythingPlusDiagnostic() {
        let wss = [ws(0, name: "Dev", windows: [win(1, tags: ["a"]), win(2)])]
        let r = OverviewProjection.filterWorkspaces(wss, byLensMatch: "tag~=")
        XCTAssertEqual(ids(r), [[1, 2]])                 // verbatim, never empty
        XCTAssertEqual(r.diagnostics.count, 1)
        XCTAssertTrue(r.diagnostics[0].hasPrefix("lens match: "))
    }

    /// An unknown field in a VALID expression no-matches in the evaluator
    /// (so the cells empty) but still surfaces a typo warning — the windows
    /// list reflects the evaluator, the diagnostic is the loud hint.
    func testUnknownFieldWarnsAndNoMatches() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = OverviewProjection.filterWorkspaces(wss, byLensMatch: "bogusfield=x")
        XCTAssertEqual(r.diagnostics,
                       ["lens match references unknown field(s): bogusfield"])
        XCTAssertEqual(ids(r), [[]])                     // no-match → empty cell
    }

    func testUnknownFieldsSortedAndDeduped() {
        let wss = [ws(0, name: "Dev", windows: [win(1)])]
        let r = OverviewProjection.filterWorkspaces(wss, byLensMatch: "zzz=1 and aaa=2")
        XCTAssertEqual(r.diagnostics,
                       ["lens match references unknown field(s): aaa, zzz"])
    }
}
