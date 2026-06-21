import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Tests for EX-0.3: `setLayoutMode` retargets the active section-lens union.
///
/// # Red-on-regression reasoning
///
/// Before EX-0.3, `setLayoutMode` had no section-lens branch. With a lens
/// active, it fell through to the workspace branch which wrote
/// `catalog.layoutModes[activeIndex]` — this had NO effect on tiling because
/// `applyLayout`/`targetFrames` routed to the cross-workspace union path and
/// used `lensLayout(forLabel:)` directly (ignoring the WS's `layoutModes`
/// entry). The three regressions that would fire without the fix:
///
///   1. **Stateless accepted** — `activeSectionLensLayout` would remain `nil`
///      (only `layoutModes[1]` would change). The first assertion in
///      `testStatelessLayoutAccepted` goes RED immediately.
///   2. **Override flows to tiling** — `resolvedLensLayout` would ignore
///      `activeSectionLensLayout` (nil) and return the config layout ("spiral"),
///      not the requested "grid". The `testOverrideFlowsToTiling` assertion
///      goes RED.
///   3. **Stateful rejected** — without the guard, "bsp" would silently write
///      `layoutModes[1]`. `activeSectionLensLayout` would stay nil (no reject).
///      The `testStatefulRejected_overrideNotSet` assertion goes RED.
///
/// These three assertions are the minimum non-vacuous regression pins.
final class SetLayoutModeLensTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)

    // MARK: - Helpers

    /// Adapter whose config declares one `type="lens"` section labelled "Web"
    /// with `layout = "spiral"` (a stateless engine). The global default layout
    /// is "master-left" so any fallback to config layout is distinguishable
    /// from a fresh override.
    private func adapterWithWebLens() -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [
            1: [DesktopSection(type: .lens, label: "Web",
                               match: "app=Web", layout: "spiral")]
        ]
        // Explicitly different global default so we can distinguish
        // "fell back to config layout" from "used the override".
        cfg.defaultLayout = "master-left"
        return NativeAdapter(config: cfg)
    }

    /// Seed the adapter with 2 workspaces, adopt windows into both, apply
    /// the "Web" section lens, and return the four WindowIDs. After this call:
    ///   - `catalog.activeSectionLens == "Web"`
    ///   - `catalog.activeSectionLensLayout == nil` (fresh lens, no override yet)
    ///   - wid(30) is lens-parked (non-matching "A" app)
    ///   - wid(10), wid(20), wid(40) are the three in-lens windows (cross-WS)
    private func seedAndActivateLens(_ a: NativeAdapter)
        -> (ws1Web: WindowID, ws2Web: WindowID, nonMatch: WindowID)
    {
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "")),
            (index: 2, config: WorkspaceConfig(name: "")),
        ])

        let w10 = window(10, appName: "Web")   // WS1, matches lens
        let w20 = window(20, appName: "Web")   // WS2, matches lens
        let w30 = window(30, appName: "A")     // WS1, non-matching
        let w40 = window(40, appName: "Web")   // WS2, matches lens (3rd for layout divergence)

        a.catalog.reconcile(live: [w10, w20, w30, w40])
        a.catalog.moveWindow(wid(20), to: 2, in: rect)
        a.catalog.moveWindow(wid(40), to: 2, in: rect)
        a.catalog.activeSectionLens = "Web"
        a.catalog.activeSectionLensLayout = nil   // mirror what setSectionLens does

        // Apply the lens so lensParkedMembers is correct.
        _ = a.catalog.applySectionLens(visibleIDs: [wid(10), wid(20), wid(40)], in: rect)

        return (wid(10), wid(20), wid(30))
    }

    // MARK: - Stateless accepted: override is written

    /// With a lens active, `setLayoutMode(…, mode: "grid")` must write
    /// `catalog.activeSectionLensLayout = "grid"` and leave
    /// `layoutModes[activeIndex]` unchanged (the WS is never the target).
    ///
    /// RED-ON-REGRESSION: before EX-0.3 the lens branch didn't exist — the
    /// workspace branch ran instead, writing `layoutModes[1]` while
    /// `activeSectionLensLayout` stayed nil. The first assert fires RED.
    func testStatelessLayoutAccepted() {
        let a = adapterWithWebLens()
        _ = seedAndActivateLens(a)

        let wsBefore = a.catalog.layoutModes[1]

        // setLayoutMode has dispatchPrecondition(.onQueue(cliQueue)); run on it.
        cliQueue.sync { a.setLayoutMode(workspaceIndex: 0, mode: "grid") }

        XCTAssertEqual(a.catalog.activeSectionLensLayout, "grid",
            "setLayoutMode(grid) while lens active must set activeSectionLensLayout")
        XCTAssertEqual(a.catalog.layoutModes[1], wsBefore,
            "WS1's layoutModes entry must be untouched when a lens is active")
    }

    /// Case-insensitive: "Grid" → stored as "grid".
    func testStatelessLayoutStoredLowercased() {
        let a = adapterWithWebLens()
        _ = seedAndActivateLens(a)

        // setLayoutMode has dispatchPrecondition(.onQueue(cliQueue)); run on it.
        cliQueue.sync { a.setLayoutMode(workspaceIndex: 0, mode: "Grid") }
        XCTAssertEqual(a.catalog.activeSectionLensLayout, "grid",
            "activeSectionLensLayout must be stored lowercase")
    }

    // MARK: - Override flows to tiling via resolvedLensLayout

    /// With `activeSectionLensLayout = "grid"`, `resolvedLensLayout(forLabel:)`
    /// must return "grid" (override wins over the config layout "spiral").
    ///
    /// RED-ON-REGRESSION: before EX-0.3, `activeSectionLensLayout` didn't
    /// exist. `resolvedLensLayout` (also new) couldn't exist, so the call site
    /// would be the old inline `LensLayout.resolve(lensLayout(forLabel:label), …)`
    /// which returns "spiral" (the config value). This test goes RED because
    /// "grid" ≠ "spiral".
    func testOverrideFlowsToTiling() {
        let a = adapterWithWebLens()
        _ = seedAndActivateLens(a)

        // Manually set the override (mirrors what setLayoutMode does).
        a.catalog.activeSectionLensLayout = "grid"

        let resolved = a.resolvedLensLayout(forLabel: "Web")
        XCTAssertEqual(resolved, "grid",
            "resolvedLensLayout must return the runtime override when set")

        // And when nil, falls back to the config layout ("spiral").
        a.catalog.activeSectionLensLayout = nil
        let fallback = a.resolvedLensLayout(forLabel: "Web")
        XCTAssertEqual(fallback, "spiral",
            "resolvedLensLayout must fall back to the config layout when override is nil")
    }

    /// `targetFrames` honours the runtime override through `resolvedLensLayout`.
    /// With override = "grid", the returned map must differ from the "spiral"
    /// (config) layout for the 3 in-lens windows (wid 10, 20, 40).
    ///
    /// Hand-verified divergence for n=3, rect=1600×900:
    ///   Grid  (cols=2, rows=2, cellH=450):
    ///     wid(10): {x:0,    y:0,   w:800,  h:450}
    ///     wid(20): {x:800,  y:0,   w:800,  h:450}
    ///     wid(40): {x:0,    y:450, w:1600, h:450}  ← last row widens to fill
    ///   Spiral (i%4: 0=left-half, 1=top-half, last=fill):
    ///     wid(10): {x:0,    y:0,   w:800,  h:900}  ← LEFT HALF, full height
    ///     wid(20): {x:800,  y:0,   w:800,  h:450}
    ///     wid(40): {x:800,  y:450, w:800,  h:450}
    ///   wid(10) height=900 (spiral) ≠ 450 (grid) → maps differ. ✓
    func testTargetFramesHonoursOverride() {
        let a = adapterWithWebLens()
        _ = seedAndActivateLens(a)

        // Baseline: no override → config layout ("spiral").
        let spiralFrames = a.targetFrames(for: 1, in: rect)

        // Apply override → "grid".
        a.catalog.activeSectionLensLayout = "grid"
        let gridFrames = a.targetFrames(for: 1, in: rect)

        // All three in-lens windows must appear in both maps.
        XCTAssertNotNil(spiralFrames[wid(10)], "wid(10) must be in spiral frames")
        XCTAssertNotNil(gridFrames[wid(10)],   "wid(10) must be in grid frames")
        XCTAssertNotNil(spiralFrames[wid(20)], "wid(20) must be in spiral frames")
        XCTAssertNotNil(gridFrames[wid(20)],   "wid(20) must be in grid frames")
        XCTAssertNotNil(spiralFrames[wid(40)], "wid(40) must be in spiral frames")
        XCTAssertNotNil(gridFrames[wid(40)],   "wid(40) must be in grid frames")

        // wid(30) is lens-parked → absent in both.
        XCTAssertNil(spiralFrames[wid(30)], "lens-parked wid(30) must be absent")
        XCTAssertNil(gridFrames[wid(30)],   "lens-parked wid(30) must be absent")

        // The override must actually change the tiling. For n=3 the engines
        // genuinely differ: grid assigns wid(10) h=450 (row 0 of 2); spiral
        // assigns wid(10) h=900 (full-height left half). See header comment.
        XCTAssertNotEqual(gridFrames, spiralFrames,
            "grid and spiral must produce different frame maps for 3 windows")
    }

    // MARK: - Stateful rejected

    /// `setLayoutMode(…, mode: "bsp")` while a lens is active must NOT write
    /// `activeSectionLensLayout` — the lens union can't be represented by a
    /// stateful engine. The override stays nil (the lens continues tiling with
    /// its config layout). Note: float is also rejected (the error names only
    /// bsp/stack but the guard is `!LensLayout.isStateless(mode)`).
    ///
    /// RED-ON-REGRESSION: before EX-0.3, the workspace branch ran and wrote
    /// `layoutModes[1] = "bsp"` while `activeSectionLensLayout` stayed nil.
    /// The third XCTAssertNil below would pass vacuously (still nil), but
    /// `layoutModes[1]` would be "bsp" — caught by the second assertion.
    func testStatefulRejected_overrideNotSet() {
        let a = adapterWithWebLens()
        _ = seedAndActivateLens(a)

        let wsBefore = a.catalog.layoutModes[1]

        // setLayoutMode has dispatchPrecondition(.onQueue(cliQueue)); run on it.
        cliQueue.sync { a.setLayoutMode(workspaceIndex: 0, mode: "bsp") }

        // Sanity check: the runtime override stays nil — but note this assertion
        // is NOT the primary regression pin (a pre-EX build also left it nil).
        // The real pin is `layoutModes` below: the lens branch must intercept
        // before the workspace branch can write `layoutModes[1] = "bsp"`.
        XCTAssertNil(a.catalog.activeSectionLensLayout,
            "activeSectionLensLayout must remain nil after a stateful rejection")

        // The WS's own layoutModes must also be untouched — the lens branch
        // intercepted the call before the workspace branch could run.
        XCTAssertEqual(a.catalog.layoutModes[1], wsBefore,
            "WS1 layoutModes must be untouched after a stateful rejection")
    }

    /// Same for "stack" (the other stateful engine).
    func testStatefulRejected_stack() {
        let a = adapterWithWebLens()
        _ = seedAndActivateLens(a)

        // setLayoutMode has dispatchPrecondition(.onQueue(cliQueue)); run on it.
        cliQueue.sync { a.setLayoutMode(workspaceIndex: 0, mode: "stack") }
        XCTAssertNil(a.catalog.activeSectionLensLayout,
            "activeSectionLensLayout must remain nil after stack rejection")
    }

    // MARK: - Override resets on lens change / clear

    /// `clearSectionLens` must reset `activeSectionLensLayout` to nil.
    func testOverrideResetOnClear() {
        var c = seededCatalog(2)
        c.activeSectionLens = "Web"
        c.activeSectionLensLayout = "grid"

        _ = c.clearSectionLens(in: .zero)

        XCTAssertNil(c.activeSectionLens,
            "activeSectionLens must be nil after clearSectionLens")
        XCTAssertNil(c.activeSectionLensLayout,
            "activeSectionLensLayout must be nil after clearSectionLens")
    }

    /// Re-activating the lens via `setSectionLens` (adapter) must reset the
    /// override so the newly-activated lens starts from its config layout.
    ///
    /// RED-ON-REGRESSION: if the `catalog.activeSectionLensLayout = nil` line
    /// in `setSectionLens` is removed, the prior "grid" override survives the
    /// re-activation and this test goes RED.
    ///
    /// Implementation note: `setSectionLens` requires both
    /// `isMacDesktopManaged(ordinal:1)` AND `isSectionModelActive(ordinal:1)`.
    /// The latter requires a `type = "workspace"` section — `adapterWithWebLens`
    /// has only `type = "lens"`, so we use `adapterWithWebLensAndWorkspace`
    /// which adds a workspace section, making both guards pass.
    func testOverrideResetOnSetSectionLens() {
        let a = adapterWithWebLensAndWorkspace()
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "")),
            (index: 2, config: WorkspaceConfig(name: "")),
        ])

        let w10 = window(10, appName: "Web")
        let w30 = window(30, appName: "A")
        a.catalog.reconcile(live: [w10, w30])

        // Set a prior override (as if a --layout command had run).
        a.catalog.activeSectionLensLayout = "grid"

        // Re-activate the "Web" lens via the real adapter path.
        // setSectionLens has dispatchPrecondition(.onQueue(cliQueue)); run on it.
        cliQueue.sync { a.setSectionLens("Web", autoFocus: false) }

        // The adapter's activate path clears activeSectionLensLayout → nil.
        XCTAssertNil(a.catalog.activeSectionLensLayout,
            "activeSectionLensLayout must be nil after re-activating the lens via setSectionLens")
    }

    /// Adapter whose config has BOTH a `type="workspace"` section AND a
    /// `type="lens"` section labelled "Web". The workspace section makes
    /// `isSectionModelActive(ordinal:1)` return true (required by
    /// `setSectionLens`'s guard), while the lens section is what we're testing.
    private func adapterWithWebLensAndWorkspace() -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [
            1: [
                DesktopSection(type: .workspace, label: "Dev", match: ""),
                DesktopSection(type: .lens, label: "Web",
                               match: "app=Web", layout: "spiral"),
            ]
        ]
        cfg.defaultLayout = "master-left"
        return NativeAdapter(config: cfg)
    }

    // MARK: - No-lens path unchanged

    /// Without an active lens, `setLayoutMode` must write to the workspace's
    /// `layoutModes` as before — the lens branch must NOT intercept.
    func testNoLensFallsThrough() {
        let a = adapterWithWebLens()
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        let w = window(10)
        a.catalog.reconcile(live: [w])
        // No lens active — activeSectionLens is nil.

        // setLayoutMode has dispatchPrecondition(.onQueue(cliQueue)); run on it.
        cliQueue.sync { a.setLayoutMode(workspaceIndex: 0, mode: "master-left") }

        XCTAssertNil(a.catalog.activeSectionLensLayout,
            "activeSectionLensLayout must stay nil when no lens is active")
        XCTAssertEqual(a.catalog.layoutModes[1], "master-left",
            "without an active lens, setLayoutMode must write to layoutModes")
    }
}
