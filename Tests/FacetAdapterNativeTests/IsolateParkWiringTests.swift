import CoreGraphics
import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// t-c6fm Phase 3 — wiring the isolate focus-mode re-park into the reconcile
/// cycle. Two layers:
///   • CATALOG (`reconcileIsolatePark`) — the pure ledger diff: given the
///     freshly-derived desired park set, detach + ledger the newly-parked
///     windows, restore + re-attach re-joiners / on gate-off, drop windows that
///     left the active WS. No AX — returns the `(toPark, toRestore)` refs the
///     adapter drives through `applyHide`. Distinguished from every other park
///     by the dedicated `isolateParked` set, and excluded from `nonFloatingMembers`
///     (like `hiddenMembers`) so the in-lens survivors reflow to fill.
///   • ADAPTER (`applyIsolatePark`) — the gate (selected board is an `isolate`
///     lens board AND a lens is active) + `IsolatePark.parkSet` derivation +
///     the catalog call. Gate off (no isolate board / no lens / board switched)
///     → unpark everything.
struct IsolateParkWiringTests {

    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private func ids(_ refs: [WindowRef]) -> [Int] { refs.map(\.id.serverID).sorted() }

    // MARK: - catalog: reconcileIsolatePark ledger diff

    /// Desired (out-of-lens) windows are ledgered + excluded from the layout so
    /// the survivors reflow; the in-lens window stays.
    @Test func parkLedgersAndDetachesOutOfLens() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(30)])   // both → active WS 1
        let plan = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        #expect(ids(plan.toPark) == [30])
        #expect(plan.toRestore.isEmpty)
        #expect(c.isolateParked == [wid(30)])
        // The parked window drops out of the tiling set; the survivor remains.
        #expect(c.nonFloatingMembers(of: 1) == [wid(10)])
    }

    /// A window that re-joins the lens (no longer desired) — or a gate-off with
    /// desired empty — is restored + re-admitted to the layout.
    @Test func unparkRestoresRejoiner() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(30)])
        _ = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        let plan = c.reconcileIsolatePark(desired: [], focused: nil, in: rect)
        #expect(ids(plan.toRestore) == [30])
        #expect(plan.toPark.isEmpty)
        #expect(c.isolateParked.isEmpty)
        #expect(c.nonFloatingMembers(of: 1).contains(wid(30)))
    }

    /// Re-deriving the same park set every reconcile is a no-op after the first
    /// park (the window is already isolate-parked).
    @Test func parkIsIdempotent() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(30)])
        _ = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        let again = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        #expect(again.toPark.isEmpty)
        #expect(again.toRestore.isEmpty)
        #expect(c.isolateParked == [wid(30)])
    }

    /// A sticky (everywhere) window is park-exempt even when out-of-lens.
    @Test func stickyOutOfLensNotParked() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(30)])
        c.everywhereWindows.insert(wid(30))
        let plan = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        #expect(plan.toPark.isEmpty)
        #expect(c.isolateParked.isEmpty)
    }

    /// A window that LEFT the active workspace while isolate-parked is dropped
    /// from the ledger WITHOUT a restore — the WS machinery owns it now.
    @Test func windowLeftActiveWSDroppedNotRestored() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(30)])
        _ = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        c.windowMap[wid(30)] = WindowSlot(workspace: 2, pid: 1000)  // moved off active WS
        let plan = c.reconcileIsolatePark(desired: [], focused: nil, in: rect)
        #expect(plan.toRestore.isEmpty)                   // not restored
        #expect(!c.isolateParked.contains(wid(30)))       // but dropped from ledger
    }

    /// Regression (adversarial review): switching the ACTIVE workspace away while
    /// a window is isolate-parked must RE-ATTACH it to its (now inactive) WS
    /// layout — not silently drop it detached — else it is stranded out of tiling
    /// when that WS re-activates (the WS-switch park restores POSITION only,
    /// relying on the window still being a layout member).
    @Test func wsSwitchAwayReattachesParkedToItsWSTree() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(30)])   // 10,30 → active WS 1
        _ = c.setMode(workspace: 1, to: "bsp", in: rect)  // WS1 bsp: tree = {10,30}
        #expect(Set(c.tiledFrames(for: 1, in: rect).keys) == [wid(10), wid(30)])
        _ = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        #expect(Set(c.tiledFrames(for: 1, in: rect).keys) == [wid(10)])   // 30 detached
        _ = c.setActive(2, in: rect)                      // active WS → 2 (WS1 now inactive)
        _ = c.reconcileIsolatePark(desired: [], focused: nil, in: rect)
        #expect(!c.isolateParked.contains(wid(30)))       // dropped from ledger
        // …and re-admitted to WS1's tree, so returning to WS1 tiles it again.
        #expect(Set(c.tiledFrames(for: 1, in: rect).keys) == [wid(10), wid(30)])
    }

    /// Closing a window purges its isolate-park ledger entry (the `forgetWindow`
    /// invariant — new per-window state clears there).
    @Test func forgetWindowClearsIsolateParked() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(30)])
        _ = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        _ = c.reconcile(live: [window(10)])               // 30 gone → forgetWindow
        #expect(!c.isolateParked.contains(wid(30)))
    }

    /// The snapshot stamps `Window.isParked` from `isolateParked` (t-c6fm phase
    /// 4) so the tree can dim + badge a parked window and route it to Lost&Found.
    @Test func snapshotStampsIsParked() {
        var c = seededCatalog(2)
        _ = c.reconcile(live: [window(10), window(30)])
        _ = c.reconcileIsolatePark(desired: [wid(30)], focused: nil, in: rect)
        let snap = c.snapshot(live: [window(10), window(30)],
                              focused: nil, activeRect: rect)
        let active = snap.first { $0.isActive }
        #expect(active?.windows.first { $0.id == wid(30) }?.isParked == true)
        #expect(active?.windows.first { $0.id == wid(10) }?.isParked == false)
    }

    // MARK: - adapter: applyIsolatePark gate + derivation

    private func ws(_ label: String) -> DesktopSection {
        DesktopSection(type: .workspace, label: label)
    }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }
    private let webLensID = "section:0:Web"

    /// Adapter on ordinal 1 with a workspace board (index 0) and a `type=lens`
    /// board (index 1). t-c6fm: a `type=lens` board ALWAYS parks (no per-board
    /// opt-in) — activating a lens declutters. Live windows: 10 = Web (in-lens),
    /// 30 = Other (out-of-lens).
    private func lensBoardAdapter() -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopTabConfigs = [1: [
            DesktopTab(type: .workspace, label: "Spaces", sections: [ws("Main")]),
            DesktopTab(type: .lens, label: "Focus",
                       sections: [lens("Web", "app=Web")]),
        ]]
        cfg.defaultLayout = "master-left"
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        a.catalog.reconcile(live: [window(10, appName: "Web"),
                                   window(30, appName: "Other")])
        return a
    }

    private func live() -> [Window] {
        [window(10, appName: "Web"), window(30, appName: "Other")]
    }

    /// Activating a lens on a `type=lens` board parks the out-of-lens window
    /// (park is inherent to lens boards — no opt-in).
    @Test func lensBoardActiveLensParksOutOfLens() {
        let a = lensBoardAdapter()
        cliQueue.sync {
            a.setSelectedBoard(1, forMacDesktopOrdinal: 1)
            a.setSectionLens(webLensID, autoFocus: false)
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked == [wid(30)])       // Other parked
        #expect(!a.catalog.isolateParked.contains(wid(10))) // Web stays
    }

    /// Clearing the active lens unparks everything the lens board parked.
    @Test func clearingLensUnparks() {
        let a = lensBoardAdapter()
        cliQueue.sync {
            a.setSelectedBoard(1, forMacDesktopOrdinal: 1)
            a.setSectionLens(webLensID, autoFocus: false)
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
            #expect(a.catalog.isolateParked == [wid(30)])
            a.catalog.activeSectionLens = nil               // lens cleared
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked.isEmpty)
    }

    /// Switching to the workspace board (display-only) drops the park gate →
    /// the parked windows come back (the board switch itself moves no OS window;
    /// leaving the lens board reverses its declutter).
    @Test func switchingAwayFromLensBoardUnparks() {
        let a = lensBoardAdapter()
        cliQueue.sync {
            a.setSelectedBoard(1, forMacDesktopOrdinal: 1)
            a.setSectionLens(webLensID, autoFocus: false)
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
            #expect(a.catalog.isolateParked == [wid(30)])
            a.setSelectedBoard(0, forMacDesktopOrdinal: 1)  // → workspace board
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked.isEmpty)
    }

    /// Board-invariant (t-c6fm): SELECTING a lens board is display-only — with no
    /// lens active the gate stays off, so nothing parks and every window keeps its
    /// workspace assignment. Park needs BOTH a lens board AND an active lens; a
    /// board switch alone never moves a window.
    @Test func boardSwitchAloneParksNothing() {
        let a = lensBoardAdapter()
        cliQueue.sync {
            a.setSelectedBoard(1, forMacDesktopOrdinal: 1)   // lens board, NO lens
            a.applyIsolatePark(live: live(), focused: nil, rect: rect)
        }
        #expect(a.catalog.isolateParked.isEmpty)
        #expect(a.catalog.windowMap[wid(10)]?.workspace == 1)
        #expect(a.catalog.windowMap[wid(30)]?.workspace == 1)
    }
}
