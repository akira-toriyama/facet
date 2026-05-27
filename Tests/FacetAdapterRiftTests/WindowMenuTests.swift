import XCTest
@testable import FacetCore
@testable import FacetAdapterRift

/// `RiftAdapter.windowMenu(mode:floating:)` is pure (no rift-cli,
/// no AX) — it's a lookup table from rift's layout-mode string
/// to the actions that apply in that mode. Tests lock the shape
/// so a Phase ε rewrite (rift retire) can compare against a
/// known-good baseline.
///
/// Matrix: 5 rift modes (`master_stack` / `traditional` / `bsp`
/// / `stack` / `scrolling`) × 2 floating states + unknown-mode
/// fallback.
final class WindowMenuTests: XCTestCase {

    private func labels(_ items: [WindowMenuItem]) -> [String] {
        items.map(\.label)
    }

    private func adapter() -> RiftAdapter {
        // Init starts an EventSource (`rift-cli watch` subscription)
        // but we don't subscribe to events and we don't call any
        // rift-touching method, so the menu calls below are pure.
        RiftAdapter()
    }

    // MARK: - master_stack

    func testMasterStackNonFloating() {
        let items = adapter().windowMenu(mode: "master_stack",
                                         floating: false)
        XCTAssertEqual(labels(items),
                       ["Promote to master",
                        "Swap master / stack",
                        "Float",
                        "Toggle fullscreen",
                        "Close window"])
        XCTAssertEqual(items[0].ops, [.promoteToMaster])
        XCTAssertEqual(items[1].ops, [.swapMasterStack])
    }

    func testMasterStackFloatingPrependsUnfloat() {
        // Floating windows aren't in the tree, so layout actions
        // unfloat first.
        let items = adapter().windowMenu(mode: "master_stack",
                                         floating: true)
        XCTAssertEqual(labels(items),
                       ["Promote to master",
                        "Swap master / stack",
                        "Unfloat",
                        "Toggle fullscreen",
                        "Close window"])
        XCTAssertEqual(items[0].ops,
                       [.toggleFloat, .promoteToMaster])
        XCTAssertEqual(items[1].ops,
                       [.toggleFloat, .swapMasterStack])
    }

    // MARK: - traditional / bsp (share menu shape)

    func testTraditionalNonFloating() {
        let items = adapter().windowMenu(mode: "traditional",
                                         floating: false)
        XCTAssertEqual(labels(items),
                       ["Toggle stack",
                        "Toggle orientation",
                        "Float",
                        "Toggle fullscreen",
                        "Close window"])
    }

    func testBspMatchesTraditional() {
        // rift treats bsp and traditional identically in the menu.
        let trad = adapter().windowMenu(mode: "traditional",
                                        floating: false)
        let bsp = adapter().windowMenu(mode: "bsp", floating: false)
        XCTAssertEqual(labels(bsp), labels(trad))
    }

    // MARK: - stack

    func testStackNonFloating() {
        let items = adapter().windowMenu(mode: "stack",
                                         floating: false)
        XCTAssertEqual(labels(items),
                       ["Toggle orientation",
                        "Float",
                        "Toggle fullscreen",
                        "Close window"])
    }

    // MARK: - scrolling

    func testScrollingNonFloating() {
        let items = adapter().windowMenu(mode: "scrolling",
                                         floating: false)
        XCTAssertEqual(labels(items),
                       ["Center column",
                        "Snap strip",
                        "Float",
                        "Toggle fullscreen",
                        "Close window"])
        XCTAssertEqual(items[0].ops, [.centerColumn])
        XCTAssertEqual(items[1].ops, [.snapStrip])
    }

    // MARK: - Unknown mode

    func testUnknownModeFallsBackToUniversalsOnly() {
        // No mode-specific actions, just Float / Fullscreen / Close.
        let items = adapter().windowMenu(mode: "future_mode",
                                         floating: false)
        XCTAssertEqual(labels(items),
                       ["Float", "Toggle fullscreen", "Close window"])
    }

    // MARK: - Universals

    func testCloseAlwaysLastAndCloseFlagged() {
        for mode in ["master_stack", "traditional", "bsp",
                     "stack", "scrolling", "future_mode"] {
            for floating in [false, true] {
                let items = adapter().windowMenu(
                    mode: mode, floating: floating)
                XCTAssertTrue(items.last?.isClose == true,
                              "mode=\(mode) floating=\(floating)")
                XCTAssertEqual(items.last?.label, "Close window",
                               "mode=\(mode) floating=\(floating)")
            }
        }
    }

    func testFloatToggleLabelTracksFloatingFlag() {
        for mode in ["master_stack", "traditional", "bsp",
                     "stack", "scrolling"] {
            let nonFloating = adapter().windowMenu(
                mode: mode, floating: false)
            let floating = adapter().windowMenu(
                mode: mode, floating: true)
            XCTAssertTrue(nonFloating.contains { $0.label == "Float" },
                          "mode=\(mode) non-floating → Float")
            XCTAssertTrue(floating.contains { $0.label == "Unfloat" },
                          "mode=\(mode) floating → Unfloat")
        }
    }
}
