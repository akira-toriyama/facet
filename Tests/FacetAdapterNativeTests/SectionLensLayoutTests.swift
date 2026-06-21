import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// Unit tests for `NativeAdapter.lensLayout(forLabel:)` — the config-lookup
/// helper added in EX-0.2. Mirrors the test pattern from
/// `SectionLensGatherTests`: build a `NativeAdapter(config:)` with a known
/// `DesktopSection` and override `activeMacDesktopOrdinal` to 1 so the
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

    // MARK: - lensLayout(forLabel:)

    /// A lens section with `layout = "spiral"` → returns `"spiral"`.
    func testReturnsConfiguredLayout() {
        let a = adapterWithLensSections()
        a.activeMacDesktopOrdinal = 1

        XCTAssertEqual(a.lensLayout(forLabel: "Web"), "spiral",
                       "should return the section's layout string")
    }

    /// A lens section whose `layout` field is absent → returns nil so
    /// `LensLayout.resolve(nil, …)` can clamp to the global default.
    func testReturnsNilWhenNoLayoutField() {
        let a = adapterWithLensSections()
        a.activeMacDesktopOrdinal = 1

        XCTAssertNil(a.lensLayout(forLabel: "NoLayout"),
                     "absent layout field must yield nil")
    }

    /// An unknown label (no matching section) → returns nil.
    func testReturnsNilForUnknownLabel() {
        let a = adapterWithLensSections()
        a.activeMacDesktopOrdinal = 1

        XCTAssertNil(a.lensLayout(forLabel: "Unknown"),
                     "unknown label must yield nil")
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
