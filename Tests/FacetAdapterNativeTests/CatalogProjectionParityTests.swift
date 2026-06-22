import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Pivot-readiness oracle (Prep-1, see
/// `handoff-2026-06-17-deep-audit-refactor-phase`). The upcoming
/// "facet filter" pivot reverses the render pipeline to
/// `window-centric model → filter → groups → view`, making the catalog's
/// per-window projection THE single source every view re-projects from.
/// Today that projection exists two ways — `facetState` (the
/// `facet query` export) and `snapshot` (the display path) — and an
/// untested derivation would become a *universal* rendering bug under the
/// pivot. These tests pin:
///   • cov-01 — `facetState` AGREES with `snapshot` on the shared
///     per-window attributes (so the export path and the display path
///     can't silently drift), plus the out-of-range workspace-name guard.
///   • cov-04 — the snapshot GATE: `snapshot` yields one `Workspace` per
///     seeded entry.
final class CatalogProjectionParityTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 1000, height: 800)

    // MARK: - cov-01: facetState ⇄ snapshot parity

    func testFacetStateAgreesWithWorkspaceSnapshotPerWindow() {
        let a = NativeAdapter(config: FacetConfig())
        a.catalog.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "Dev")),
            (index: 2, config: WorkspaceConfig(name: "")),
        ])
        let live = [window(10), window(20)]
        _ = a.catalog.reconcile(live: live)

        let snap = a.catalog.snapshot(live: live, focused: nil, activeRect: rect)
        let wins = snap.flatMap { $0.windows }
        XCTAssertEqual(wins.count, 2, "both windows present once")

        for w in wins {
            guard let fs = a.facetState(forWindow: w.id, in: a.catalog) else {
                XCTFail("facetState nil for \(w.id.serverID)"); continue
            }
            XCTAssertEqual(fs.floating, w.isFloating, "floating parity \(w.id.serverID)")
            XCTAssertEqual(fs.sticky, w.isSticky, "sticky parity \(w.id.serverID)")
            XCTAssertEqual(fs.master, w.isMaster, "master parity \(w.id.serverID)")
            XCTAssertEqual(fs.mark, w.mark, "mark parity \(w.id.serverID)")
            XCTAssertEqual(fs.scratchpad, w.scratchpad, "scratchpad parity \(w.id.serverID)")
            XCTAssertEqual(fs.workspaceIndex, 1, "both reconciled to active WS1")
        }
    }

    func testFacetStateOutOfRangeWorkspaceNameIsEmpty() {
        // The workspace-name lookup guards against an index outside the
        // live `workspaceNames` set (idx >= 1 && idx <= count else "").
        let a = NativeAdapter(config: FacetConfig())
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: "Dev"))])
        a.catalog.windowMap[wid(99)] = WindowSlot(workspace: 99, pid: 1)

        let fs = a.facetState(forWindow: wid(99), in: a.catalog)
        XCTAssertEqual(fs?.workspaceIndex, 99)
        XCTAssertEqual(fs?.workspace, "", "out-of-range index → empty name guard")
    }

    func testFacetStateNilForUnknownWindow() {
        let a = NativeAdapter(config: FacetConfig())
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        XCTAssertNil(a.facetState(forWindow: wid(404), in: a.catalog),
                     "a window not in windowMap has no facet state")
    }

    // MARK: - cov-04: the snapshot gate

    func testGroupingGateWorkspaceModeYieldsOneWorkspacePerEntry() {
        var c = WorkspaceCatalog()
        c.seed(configs: (1...3).map {
            (index: $0, config: WorkspaceConfig(name: ""))
        })
        let live = [window(10), window(20)]
        _ = c.reconcile(live: live)

        let snap = c.snapshot(live: live, focused: nil, activeRect: rect)
        XCTAssertEqual(snap.count, 3, "one Workspace per seeded entry")
        XCTAssertEqual(snap.flatMap { $0.windows }.count, 2,
                       "each window appears once")
        XCTAssertEqual(snap.first { $0.isActive }?.windows.count, 2,
                       "both reconciled into the active WS")
    }
}
