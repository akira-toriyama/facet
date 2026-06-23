import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Regression tests for `NativeAdapter.targetFrames(for:in:)` — verifies that
/// the EX-0.2 fix makes the animated paths (animateSwitch / animateRetile /
/// directionalNeighbor) lens-aware by routing through the same cross-workspace
/// union as `applyLayout`.
///
/// RED-ON-REGRESSION:
/// Before the fix, `targetFrames(for:in:)` dispatched only on
/// `catalog.mode(of:n1Based)` (bsp/stack/engine) and was LENS-BLIND.  With an
/// active section lens and n1Based=1 (the active WS), it would return frames
/// for WS1's per-WS layout — which contains ONLY the WS1 windows.  The WS2
/// window (wid 20, moved to the inactive workspace before the lens was applied)
/// would therefore be ABSENT from the result.  The first assertion in
/// `testSectionLensUnionIncludesInactiveWSWindow` checks for the WS2 frame
/// and goes red immediately against the pre-fix, lens-blind `targetFrames`.
///
/// The second assertion checks that `targetFrames` returns the SAME frame map
/// as `catalog.sectionLensUnionFrames(layout:in:)` so the animated path can
/// never diverge from the instant path while a lens is active.
final class TargetFramesLensTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)

    // MARK: - Helpers

    /// Adapter whose config declares one `type="lens"` section labelled "Web"
    /// with `layout = "master-left"` (a stateless engine, safe for union tiling).
    private func adapterWithWebLens() -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [
            1: [DesktopSection(type: .lens, label: "Web",
                               match: "app=Web", layout: "master-left")]
        ]
        return NativeAdapter(config: cfg)
    }

    /// Seed the adapter with 2 workspaces, adopt three windows (wid 10 "Web"
    /// in WS1, wid 20 "Web" in WS2, wid 30 "A" in WS1), apply the "Web"
    /// section lens so `lensParkedMembers` and `sectionLensUnionMembers()` are
    /// in their settled state.  Returns the three WindowIDs.
    private func seedAndApplyLens(_ a: NativeAdapter)
        -> (ws1Web: WindowID, ws2Web: WindowID, nonMatch: WindowID)
    {
        // Force the ordinal so lensLayout(forLabel:) resolves against config.
        a.activeMacDesktopOrdinal = 1

        a.catalog.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "")),
            (index: 2, config: WorkspaceConfig(name: "")),
        ])

        let w10 = window(10, appName: "Web")   // WS1, matches lens
        let w20 = window(20, appName: "Web")   // WS2, matches lens
        let w30 = window(30, appName: "A")     // WS1, non-matching

        // Adopt all three (all land in WS1 via reconcile).
        a.catalog.reconcile(live: [w10, w20, w30])

        // Move wid(20) to WS2 (the inactive workspace).
        a.catalog.moveWindow(wid(20), to: 2, in: rect)

        // Tile BOTH workspaces so their windows are lens-union-eligible: a
        // FLOAT-mode home window is intentionally excluded from the union (the
        // lens shows it in place, never resizes it), so a cross-workspace-union
        // test must use a tiled home to exercise union membership.
        _ = a.catalog.setMode(workspace: 1, to: "master-left", in: rect)
        _ = a.catalog.setMode(workspace: 2, to: "master-left", in: rect)

        // Activate the lens label.
        a.catalog.activeSectionLens = "Web"

        // Apply the lens so lensParkedMembers reflects the match verdict:
        // wid(30) (non-matching) is parked; wid(10) + wid(20) remain visible.
        _ = a.catalog.applySectionLens(
            visibleIDs: [wid(10), wid(20)],
            in: rect)

        return (wid(10), wid(20), wid(30))
    }

    // MARK: - Section-lens routing in targetFrames

    /// `targetFrames(for:in:)` routes to the cross-workspace union when a
    /// section lens is active, and the result contains a frame for the WS2
    /// (inactive) member.
    ///
    /// RED-ON-REGRESSION: without the EX-0.2 fix, `targetFrames(for: 1, in:
    /// rect)` dispatches on WS1's per-WS mode ("float" / empty for a fresh
    /// catalog), which returns an empty map or WS1-only frames — the WS2 window
    /// (wid 20) is absent.  The second XCTAssertNotNil goes red immediately.
    func testSectionLensUnionIncludesInactiveWSWindow() {
        let a = adapterWithWebLens()
        let (ws1Web, ws2Web, _) = seedAndApplyLens(a)

        // Call targetFrames for the ACTIVE workspace (1).  With the fix,
        // the lens branch intercepts the call and returns the union frames.
        let frames = a.targetFrames(for: 1, in: rect)

        // Both in-lens windows must appear — including the WS2 (inactive) one.
        XCTAssertNotNil(frames[ws1Web],
            "active-WS in-lens window must appear in targetFrames union")
        // ---- THE REGRESSION PIN ----
        // Pre-fix: wid(20) is in WS2 (not active); the mode-dispatch would
        // return WS1-only frames (or empty) — this assertion is ABSENT → RED.
        // Post-fix: the lens branch returns sectionLensUnionFrames → PRESENT.
        XCTAssertNotNil(frames[ws2Web],
            "inactive-WS in-lens window MUST appear in targetFrames union "
            + "(regression: lens-blind targetFrames excluded inactive WS windows)")
    }

    /// `targetFrames(for:in:)` returns the SAME map as
    /// `catalog.sectionLensUnionFrames(layout:in:)` when a section lens is
    /// active — the animated path and the instant path agree.
    func testTargetFramesMatchesSectionLensUnionFrames() {
        let a = adapterWithWebLens()
        _ = seedAndApplyLens(a)

        let resolved = LensLayout.resolve(
            a.lensLayout(forLabel: "Web"),
            globalDefault: a.config.effectiveDefaultLayout)

        let expected = a.catalog.sectionLensUnionFrames(layout: resolved, in: rect)
        let actual   = a.targetFrames(for: 1, in: rect)

        XCTAssertEqual(actual.count, expected.count,
            "targetFrames and sectionLensUnionFrames must contain the same windows")
        for (id, frame) in expected {
            XCTAssertEqual(actual[id], frame,
                "frame for \(id) must match between targetFrames and sectionLensUnionFrames")
        }
    }
}
