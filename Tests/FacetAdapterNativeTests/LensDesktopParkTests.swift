import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// t-0sbm Phase 2b — the ADAPTER runtime for a typed `[desktop.N] type=lens`
/// mac desktop (board abolition). Unlike a lens BOARD (which needs an explicit
/// `facet lens` activation), a lens DESKTOP is ALWAYS-ON: whenever it is the
/// active mac desktop, `applyIsolatePark` parks the out-of-`match` windows and
/// tiles the matched set with the lens's declared `layout`. Flat by
/// construction (a lens desktop seeds exactly ONE workspace, so the active-WS
/// park scope == the whole desktop). Reuses `IsolatePark.parkSet` /
/// `reconcileIsolatePark` / `LensMembership` verbatim — the only new runtime is
/// the always-on gate + the `layout` seam.
struct LensDesktopParkTests {

    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private func live() -> [Window] {
        [window(10, appName: "Web"), window(30, appName: "Other")]
    }

    /// Adapter on ordinal 1 whose desktop is a `type=lens` table (`match`,
    /// `layout`). Live: 10 = Web (in-lens), 30 = Other (out-of-lens). ONE
    /// workspace → N=1 flat scope.
    private func lensDesktopAdapter(match: String = "app=Web",
                                    layout: String? = "bsp") -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopMetaConfigs = [1: DesktopMeta(
            type: .lens, label: "Web", match: match, layout: layout)]
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        a.catalog.reconcile(live: live())
        return a
    }

    /// A lens desktop is ALWAYS-ON — no `facet lens` activation needed: the mere
    /// presence of `[desktop.N] type=lens` parks the out-of-lens window.
    @Test func desktopLensAlwaysOnParksOutOfLens() {
        let a = lensDesktopAdapter()
        cliQueue.sync { a.applyIsolatePark(live: live(), focused: nil, rect: rect) }
        #expect(a.catalog.isolateParked == [wid(30)])        // Other parked
        #expect(!a.catalog.isolateParked.contains(wid(10)))  // Web stays
    }

    /// The matched set tiles with the lens's declared `layout`.
    @Test func desktopLensTilesMatchedWithDeclaredLayout() {
        let a = lensDesktopAdapter(layout: "bsp")
        cliQueue.sync { a.applyIsolatePark(live: live(), focused: nil, rect: rect) }
        #expect(a.catalog.mode(of: 1) == "bsp")
    }

    /// `layout = "float"` (the freeze-safe case): the matched window stays
    /// floating (untouched), the non-match still anchor-parks. No union-tile.
    @Test func floatLayoutLeavesMatchedFloatingAndParksRest() {
        let a = lensDesktopAdapter(layout: "float")
        cliQueue.sync { a.applyIsolatePark(live: live(), focused: nil, rect: rect) }
        #expect(a.catalog.mode(of: 1) == "float")
        #expect(a.catalog.isolateParked == [wid(30)])        // non-match parks
        #expect(!a.catalog.isolateParked.contains(wid(10)))  // matched float stays
    }

    /// Re-running the reconcile is a no-op — the park is stable and the `layout`
    /// seam does not re-fire (`mode` unchanged → `setMode` skipped, so a user's
    /// bsp ratios survive).
    @Test func parkAndLayoutAreIdempotent() {
        let a = lensDesktopAdapter()
        cliQueue.sync {
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked == [wid(30)])
        #expect(a.catalog.mode(of: 1) == "bsp")
    }

    /// The `match` drives the park set — a different match flips which window is
    /// out-of-lens (matching Other → Web is now parked).
    @Test func matchDrivesTheParkSet() {
        let a = lensDesktopAdapter(match: "app=Other")
        cliQueue.sync { a.applyIsolatePark(live: live(), focused: nil, rect: rect) }
        #expect(a.catalog.isolateParked == [wid(10)])        // Web now out-of-lens
    }

    /// t-0sbm change-match: a RUNTIME `--match` override (the CLI / tree
    /// Edit-match seam) drives the park set OVER the config match, so the
    /// physical park/tile tracks what the user just typed — matching the tree
    /// projection override. Config says Web is in-lens; override flips it to
    /// Other, so Web (10) now parks.
    @Test func runtimeMatchOverrideDrivesParkSet() {
        let a = lensDesktopAdapter(match: "app=Web")
        cliQueue.sync {
            a.setLensDesktopMatch("app=Other", ordinal: 1)
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked == [wid(10)])   // Web now out-of-lens
        #expect(!a.catalog.isolateParked.contains(wid(30)))
    }

    /// Reverting (nil / empty) drops the override AND unparks the window the
    /// override had parked. Establishes the override-parked state FIRST (Web/10
    /// parked under `app=Other`), then reverts + reconciles so the config→revert
    /// UNPARK transition is actually exercised — not just the config baseline.
    @Test func emptyOverrideRevertsToConfigMatch() {
        let a = lensDesktopAdapter(match: "app=Web")
        cliQueue.sync {
            a.setLensDesktopMatch("app=Other", ordinal: 1)   // override → Other
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked == [wid(10)])   // override active: Web (in config) now parked
        cliQueue.sync {
            a.setLensDesktopMatch(nil, ordinal: 1)           // revert to config
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked == [wid(30)])   // config (Web in-lens) → Other parks, Web UNparked
    }

    /// The override is keyed by ordinal — an override for a DIFFERENT desktop
    /// never leaks into the active ordinal's park derivation. The active-ordinal
    /// override IS read (Web parks under `app=Other`) while an ordinal-2 DECOY
    /// (`app=Web`, which would flip the result if it leaked) is ignored — so the
    /// assertion distinguishes "per-ordinal isolation works" from "read path dead".
    @Test func overrideIsPerOrdinal() {
        let a = lensDesktopAdapter(match: "app=Web")
        cliQueue.sync {
            a.setLensDesktopMatch("app=Other", ordinal: 1)   // active ordinal — must win
            a.setLensDesktopMatch("app=Web", ordinal: 2)     // decoy on wrong ordinal — must be ignored
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked == [wid(10)])   // ord-1 override (Other) → Web parks; ord-2 decoy ignored
    }

    /// A `type=workspace` desktop is NOT a lens — it parks nothing.
    @Test func workspaceDesktopParksNothing() {
        var cfg = FacetConfig()
        cfg.macDesktopMetaConfigs = [1: DesktopMeta(type: .workspace, label: "Main")]
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        a.catalog.reconcile(live: live())
        cliQueue.sync { a.applyIsolatePark(live: live(), focused: nil, rect: rect) }
        #expect(a.catalog.isolateParked.isEmpty)
    }
}
