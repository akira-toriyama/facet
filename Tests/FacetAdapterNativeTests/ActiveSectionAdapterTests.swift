import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// EX-1.2 — the adapter's `ActiveSection` authority: the lock-guarded
/// `_activeSection` mirror (read via `currentActiveSection()`, shimmed by
/// `currentSectionLens()`) and the `activateSection(_:)` throughline.
///
/// # Red-on-regression reasoning
///   - `testCurrentActiveSectionDefaultsToWorkspaceOne` pins the mirror's
///     zero-value (the boot / fresh-catalog state) AND the `.lensLabel` shim.
///   - `testActivateLensReflectsInMirror` pins that `activateSection(.lens)`
///     routes to `setSectionLens` and the mirror reflects it.
///   - `testActivateWorkspaceSameIndexClearsActiveLens` pins the same-index
///     edge: `setActive(activeIndex)` is a no-op, so `activateSection(.workspace
///     (activeIndex))` MUST clear the lens explicitly (else it stays stale).
///
/// `activateSection` / `setSectionLens` have `dispatchPrecondition(.onQueue(
/// cliQueue))` — every call is wrapped in `cliQueue.sync { … }` (omitting it
/// aborts the CI debug build). `currentActiveSection()` is a plain lock read.
final class ActiveSectionAdapterTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 1600, height: 900)

    /// Adapter whose config has BOTH a `type="workspace"` and a `type="lens"`
    /// "Web" section, so `setSectionLens`'s `isSectionModelActive(ordinal:1)`
    /// guard passes (the workspace section is what flips it true). Mirrors
    /// `SetLayoutModeLensTests.adapterWithWebLensAndWorkspace` (private there).
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

    /// Seed 2 workspaces + adopt a matching + a non-matching window so the
    /// section model is active and `setSectionLens` has real input.
    private func seeded(_ a: NativeAdapter) {
        a.activeMacDesktopOrdinal = 1
        a.catalog.seed(configs: [
            (index: 1, config: WorkspaceConfig(name: "")),
            (index: 2, config: WorkspaceConfig(name: "")),
        ])
        a.catalog.reconcile(live: [window(10, appName: "Web"), window(30, appName: "A")])
    }

    func testCurrentActiveSectionDefaultsToWorkspaceOne() {
        let a = adapter()                                  // bare, no lens
        XCTAssertEqual(a.currentActiveSection(), .workspace(1))
        XCTAssertNil(a.currentSectionLens())               // shim agrees
    }

    // A0: lens identity is the stable id `section:<declOrder>:<label>`. The
    // "Web" lens is the 2nd section (declOrder 1) in the config above. The
    // display label ("Web") still round-trips out of the id via `lensLabel`,
    // so `currentSectionLens()` (the label shim) is unchanged.
    private let webLensID = "section:1:Web"

    func testActivateLensReflectsInMirror() {
        let a = adapterWithWebLensAndWorkspace()
        seeded(a)
        cliQueue.sync { a.activateSection(.lens(webLensID), autoFocus: false) }
        XCTAssertEqual(a.currentActiveSection(), .lens(webLensID))
        XCTAssertEqual(a.currentSectionLens(), "Web")      // shim parses label out of id
    }

    func testActivateWorkspaceSameIndexClearsActiveLens() {
        // setActive(activeIndex) is a no-op, so activateSection(.workspace(
        // activeIndex)) must clear the lens explicitly — not leave it stale.
        let a = adapterWithWebLensAndWorkspace()
        seeded(a)
        cliQueue.sync { a.activateSection(.lens(webLensID), autoFocus: false) }
        XCTAssertEqual(a.currentActiveSection(), .lens(webLensID))

        cliQueue.sync { a.activateSection(.workspace(1), autoFocus: false) } // 1 == activeIndex
        XCTAssertEqual(a.currentActiveSection(), .workspace(1))
        XCTAssertNil(a.currentSectionLens())               // lens cleared, not stale
    }
}
