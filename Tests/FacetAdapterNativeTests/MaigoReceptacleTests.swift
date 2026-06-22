import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// EX-3.4 — the 迷子 (orphan) receptacle: a `type="lens"` section with
/// `match='not workspace'` gathers exactly the windows with NO workspace
/// assignment (workspace == nil), and NOT windows that merely live in an
/// unnamed workspace (name "" is still assigned). Pins that workspace
/// presence is keyed off the assignment (nil), not the display name.
final class MaigoReceptacleTests: XCTestCase {

    private func adapterWithMaigo() -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [
            1: [DesktopSection(type: .lens, label: "迷子", match: "not workspace")]
        ]
        let a = NativeAdapter(config: cfg)
        a.activeMacDesktopOrdinal = 1
        return a
    }

    func testReceptacleGathersOrphansNotNamedWorkspaceWindows() {
        let a = adapterWithMaigo()
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: "Dev"))])
        let w10 = window(10)   // → WS "Dev"
        let w20 = window(20)   // → orphaned below
        a.catalog.reconcile(live: [w10, w20])
        a.catalog.windowMap[wid(20)] = WindowSlot(workspace: nil, pid: 1000)
        a.catalog.activeSectionLens = "迷子"
        let visible = a.sectionLensVisibleIDsAll(live: [w10, w20]) ?? []
        XCTAssertEqual(visible, [wid(20)],
                       "only the orphan matches `not workspace`; the Dev window does not")
    }

    func testReceptacleDoesNotGatherUnnamedWorkspaceWindows() {
        // Robustness: a window in an UNNAMED workspace (name "") is still
        // ASSIGNED, so `not workspace` must NOT gather it — presence is the
        // assignment (Int?), not the name. Without the String? overlay this
        // would wrongly match (name "" → looked absent).
        let a = adapterWithMaigo()
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        let w10 = window(10)   // unnamed WS1 (assigned, name "")
        let w20 = window(20)   // orphaned below
        a.catalog.reconcile(live: [w10, w20])
        a.catalog.windowMap[wid(20)] = WindowSlot(workspace: nil, pid: 1000)
        a.catalog.activeSectionLens = "迷子"
        let visible = a.sectionLensVisibleIDsAll(live: [w10, w20]) ?? []
        XCTAssertEqual(visible, [wid(20)],
                       "an unnamed-but-assigned window is NOT an orphan")
    }

    func testReceptacleGathersTaggedOrphanToo() {
        // `not workspace` catches EVERY ws-less window — incl. one that still
        // carries a lens tag (ws=nil + tag=web). The receptacle is the
        // catch-all "not filed in a workspace" view.
        let a = adapterWithMaigo()
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: "Dev"))])
        let w10 = window(10)
        a.catalog.reconcile(live: [w10])
        a.catalog.windowMap[wid(10)] = WindowSlot(workspace: nil, pid: 1000)
        _ = a.catalog.addTagToWindow(wid(10), name: "web")   // ws-less but tagged
        a.catalog.activeSectionLens = "迷子"
        let visible = a.sectionLensVisibleIDsAll(live: [w10]) ?? []
        XCTAssertEqual(visible, [wid(10)], "a tagged orphan still has no workspace")
    }
}
