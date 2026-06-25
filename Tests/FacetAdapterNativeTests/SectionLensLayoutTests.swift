import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Unit tests for `NativeAdapter.lensLayout()` — the config-lookup helper added
/// in EX-0.2. A0: it reads the ACTIVE lens's stable id from
/// `catalog.activeSectionLens` (no label arg) and resolves it via
/// `lensSection(forID:)`. Mirrors the test pattern from `SectionLensGatherTests`:
/// build a `NativeAdapter(config:)` with a known `DesktopSection`, override
/// `activeMacDesktopOrdinal` to 1, and set the active lens id directly so the
/// config lookup is deterministic regardless of the CI host mac desktop state.
///
/// `applyLayout`'s union ROUTING itself drives AX (`applyFrames`) and is
/// host-verify territory — not tested here. The catalog
/// `sectionLensUnionFrames` math is already covered by
/// `SectionLensCatalogTests`.
final class SectionLensLayoutTests: XCTestCase {

    // MARK: - Helpers

    /// Adapter whose config declares one `type="lens"` section labelled
    /// "Web" with `layout = "spiral"` and one without a layout.
    private func adapterWithLensSections() -> NativeAdapter {
        var cfg = FacetConfig()
        cfg.macDesktopSectionConfigs = [
            1: [
                DesktopSection(type: .lens, label: "Web",
                               match: "app=Web", layout: "spiral"),
                DesktopSection(type: .lens, label: "NoLayout",
                               match: "app=Other"),   // layout: nil
            ]
        ]
        return NativeAdapter(config: cfg)
    }

    // MARK: - lensLayout()

    /// A lens section with `layout = "spiral"` → returns `"spiral"`.
    /// "Web" is declOrder 0 in the config above → id `section:0:Web`.
    func testReturnsConfiguredLayout() {
        let a = adapterWithLensSections()
        a.activeMacDesktopOrdinal = 1
        a.catalog.activeSectionLens = "section:0:Web"

        XCTAssertEqual(a.lensLayout(), "spiral",
                       "should return the active lens section's layout string")
    }

    /// A lens section whose `layout` field is absent → returns nil so
    /// `LensLayout.resolve(nil, …)` can clamp to the global default.
    /// "NoLayout" is declOrder 1 → id `section:1:NoLayout`.
    func testReturnsNilWhenNoLayoutField() {
        let a = adapterWithLensSections()
        a.activeMacDesktopOrdinal = 1
        a.catalog.activeSectionLens = "section:1:NoLayout"

        XCTAssertNil(a.lensLayout(),
                     "absent layout field must yield nil")
    }

    /// An active lens id that no longer resolves (out-of-range declOrder /
    /// label-suffix mismatch) → returns nil.
    func testReturnsNilForUnresolvableID() {
        let a = adapterWithLensSections()
        a.activeMacDesktopOrdinal = 1
        a.catalog.activeSectionLens = "section:9:Ghost"   // declOrder out of range

        XCTAssertNil(a.lensLayout(),
                     "an unresolvable id must yield nil")
    }

    /// No active lens (`catalog.activeSectionLens == nil`) → returns nil.
    func testReturnsNilWhenNoActiveLens() {
        let a = adapterWithLensSections()
        a.activeMacDesktopOrdinal = 1

        XCTAssertNil(a.lensLayout(),
                     "no active lens must yield nil")
    }

    /// `LensLayout.resolve(nil, globalDefault:)` falls back to `gridLayout`
    /// when the global default is a stateful engine (bsp). Verifies the
    /// end-to-end clamping chain when `lensLayout` returns nil.
    func testResolveNilFallsBackToGrid() {
        // spiral is stateless → returned unchanged
        XCTAssertEqual(
            LensLayout.resolve("spiral", globalDefault: "master-left"),
            "spiral",
            "a stateless requested layout must pass through")

        // nil → globalDefault if stateless
        XCTAssertEqual(
            LensLayout.resolve(nil, globalDefault: "master-left"),
            "master-left",
            "nil requested with stateless globalDefault must fall back to globalDefault")

        // nil + stateful globalDefault → grid
        XCTAssertEqual(
            LensLayout.resolve(nil, globalDefault: "bsp"),
            GridLayout().name,
            "nil requested + stateful globalDefault must clamp to grid")
    }
}
