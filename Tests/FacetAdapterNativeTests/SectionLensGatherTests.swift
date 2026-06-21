import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Regression tests for `NativeAdapter.sectionLensVisibleIDsAll(live:)` —
/// the cross-workspace section-lens evaluator added in EX-0.1.
///
/// These tests pin the exact bug that was fixed: before EX-0.1 both
/// activation callers used `sectionLensVisibleIDs(workspace:live:)`, which
/// gates on `catalog.windowMap[w.id]?.workspace == n1Based` (ACTIVE WS only).
/// A matching window in an INACTIVE workspace was therefore ABSENT from
/// `visibleIDs` and got parked rather than gathered.
///
/// Each test exercises the adapter's evaluator directly (via `@testable`),
/// not the catalog state machine — which is already covered in
/// `SectionLensCatalogTests`. `NativeAdapter(config:)` does not touch AX or
/// SkyLight on this path; the only OS calls that run are the two SkyLight
/// reads in `init` (`MacDesktops.activeID()` / `ordinal(for:)`), which are
/// read-only and safe in CI. `activeMacDesktopOrdinal` is immediately
/// overwritten to 1 before any catalog access so the config lookup is
/// deterministic regardless of the CI host's mac desktop state.
final class SectionLensGatherTests: XCTestCase {

    // MARK: - Setup helpers

    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)

    /// Adapter whose config declares one `type="lens"` section labelled
    /// "Web" that matches windows with `app=Web`.
    private func adapterWithWebLens() -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [
            1: [DesktopSection(type: .lens, label: "Web", match: "app=Web")]
        ]
        return NativeAdapter(config: cfg)
    }

    /// Seed the adapter's catalog with two workspaces, adopt three windows
    /// (wid 10 "Web" in WS1, wid 20 "Web" in WS2, wid 30 "A" in WS1),
    /// and activate the "Web" lens.
    ///
    /// Returned live array matches what a caller would pass to
    /// `sectionLensVisibleIDsAll(live:)`.
    @discardableResult
    private func seedCrossWorkspace(_ a: NativeAdapter)
        -> (ws1Web: WindowID, ws2Web: WindowID, nonMatch: WindowID,
            live: [Window])
    {
        // Force the ordinal so `sectionLensFilter()` resolves to the
        // config row above regardless of the CI host mac desktop state.
        a.activeMacDesktopOrdinal = 1

        // Seed two workspaces. `seededCatalog` goes through the free
        // helper; mirroring it on the adapter catalog directly is simpler.
        a.catalog.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "")),
            (index: 2, config: WorkspaceConfig(name: "")),
        ])

        // Three test windows. window() now accepts appName; default "A"
        // gives a non-matching window.
        let w10 = window(10, appName: "Web")   // WS1, matches lens
        let w20 = window(20, appName: "Web")   // WS2, matches lens
        let w30 = window(30, appName: "A")     // WS1, non-matching

        // Adopt all three into WS1 first (the active workspace).
        a.catalog.reconcile(live: [w10, w20, w30])

        // Move wid(20) to WS2 — the inactive workspace.
        a.catalog.moveWindow(wid(20), to: 2, in: rect)

        // Activate the lens.
        a.catalog.activeSectionLens = "Web"

        return (wid(10), wid(20), wid(30), [w10, w20, w30])
    }

    // MARK: - Cross-workspace gather (EX-0.1 regression pin)

    /// `sectionLensVisibleIDsAll(live:)` returns the UNION of matching
    /// windows across ALL workspaces — both the active-WS match (wid 10)
    /// AND the inactive-WS match (wid 20) — and excludes the non-matching
    /// window (wid 30).
    ///
    /// Red-on-regression: if the evaluator were reverted to the old
    /// `workspace == n1Based` gate, only wid(10) (WS1 = activeIndex) would
    /// be included; wid(20) (WS2) would be absent. The first assert below
    /// goes red immediately.
    func testCrossWorkspaceGatherIncludesInactiveWSMatch() {
        let a = adapterWithWebLens()
        let (ws1Web, ws2Web, nonMatch, live) = seedCrossWorkspace(a)

        let visible = a.sectionLensVisibleIDsAll(live: live)

        // A nil return means no lens is active — config wiring is broken.
        XCTAssertNotNil(visible, "sectionLensVisibleIDsAll must return a set when a lens is active")
        guard let visible else { return }

        XCTAssertTrue(visible.contains(ws1Web),
                      "active-WS matching window must be in the cross-WS set")
        // ---- THE REGRESSION PIN ----
        // Under the old active-WS gate (workspace == activeIndex), wid(20)
        // is in WS2 (inactive) and would be EXCLUDED. Under the new
        // all-workspaces evaluator it is INCLUDED. This assertion goes red
        // if anyone reinstates the `workspace == n1Based` clause.
        XCTAssertTrue(visible.contains(ws2Web),
                      "inactive-WS matching window MUST be gathered "
                      + "(regression: old evaluator excluded inactive WS windows)")
        XCTAssertFalse(visible.contains(nonMatch),
                       "non-matching window (app!=Web) must be excluded")
    }

    /// Confirms that the PER-WS evaluator (`sectionLensVisibleIDs(workspace:live:)`)
    /// still EXCLUDES the inactive-WS window — making the per-WS vs all-WS
    /// distinction explicit and red-on-regression for both directions.
    ///
    /// If someone accidentally makes `sectionLensVisibleIDs(workspace:live:)` also
    /// cross-workspace (over-fix), this goes red.  If they revert the all-WS
    /// evaluator to per-WS, the test above catches it.
    func testPerWSEvaluatorExcludesInactiveWSWindow() {
        let a = adapterWithWebLens()
        let (ws1Web, ws2Web, _, live) = seedCrossWorkspace(a)

        let perWS = a.sectionLensVisibleIDs(workspace: 1, live: live)

        XCTAssertNotNil(perWS, "per-WS evaluator must return a set when a lens is active")
        guard let perWS else { return }

        // wid(10) is in WS1 (active) → included by per-WS filter.
        XCTAssertTrue(perWS.contains(ws1Web),
                      "per-WS evaluator must include the active-WS matching window")
        // wid(20) is in WS2 (inactive) → the per-WS gate EXCLUDES it.
        // This is exactly what the old evaluator did (and why EX-0.1 was needed).
        XCTAssertFalse(perWS.contains(ws2Web),
                       "per-WS evaluator must NOT include the inactive-WS window "
                       + "(it is intentionally scoped to workspace 1)")
    }

    // MARK: - No-lens guard

    /// When no lens is active `sectionLensVisibleIDsAll` returns nil —
    /// same nil-sentinel semantics as the per-WS variant.
    func testReturnsNilWhenNoLensIsActive() {
        let a = adapterWithWebLens()
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        a.catalog.reconcile(live: [window(10, appName: "Web")])
        // activeSectionLens deliberately NOT set.

        let result = a.sectionLensVisibleIDsAll(live: [window(10, appName: "Web")])
        XCTAssertNil(result, "nil activeSectionLens must yield nil (no-lens semantics)")
    }

    // MARK: - Live-window map miss

    /// A window present in `catalog.windowMap` but absent from the `live`
    /// array is excluded from the result — the evaluator skips entries with
    /// no corresponding live window.
    func testWindowAbsentFromLiveIsExcluded() {
        let a = adapterWithWebLens()
        let (ws1Web, _, _, _) = seedCrossWorkspace(a)

        // Pass an empty live array — every windowMap entry is a live-miss.
        let visible = a.sectionLensVisibleIDsAll(live: [])

        XCTAssertNotNil(visible)
        XCTAssertFalse(visible?.contains(ws1Web) ?? true,
                       "window absent from live array must be excluded")
    }
}
