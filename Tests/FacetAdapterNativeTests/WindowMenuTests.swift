import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// `NativeAdapter.windowMenu(mode:floating:)` is pure (no AX, no
/// catalog state) — it's a small per-mode lookup table for the
/// right-click menu. Tests live here so the menu shape is locked
/// down before any γ.X+ slice tries to extend it.
///
/// Matrix: 3 modes (`float` / `bsp` / `stack`) × 2 floating
/// states = 6 combinations. Every one is exercised below.
final class WindowMenuTests: XCTestCase {

    private func adapter() -> NativeAdapter {
        // FacetConfig() defaults are fine — windowMenu doesn't
        // read config. The init's AX-permission-missing branch
        // pushes an error to a stream we don't subscribe to,
        // and the WindowEventObserver hops to main, so the
        // call is harmless under XCTest.
        NativeAdapter(config: FacetConfig())
    }

    private func labels(_ items: [WindowMenuItem]) -> [String] {
        items.map(\.label)
    }

    // MARK: - Float mode

    func testFloatModeNonFloatingMenu() {
        let items = adapter().windowMenu(mode: "float", floating: false)
        XCTAssertEqual(labels(items), ["Float", "Close window"])
    }

    func testFloatModeFloatingMenu() {
        let items = adapter().windowMenu(mode: "float", floating: true)
        XCTAssertEqual(labels(items), ["Unfloat", "Close window"])
    }

    // MARK: - BSP mode

    func testBspModeNonFloatingMenu() {
        let items = adapter().windowMenu(mode: "bsp", floating: false)
        XCTAssertEqual(labels(items),
                       ["Toggle orientation", "Float", "Close window"])
        XCTAssertEqual(items[0].ops, [.toggleOrientation])
    }

    func testBspModeFloatingMenu() {
        // Floating window in a bsp WS still has no orientation
        // (it's outside the tree) — menu collapses to Unfloat +
        // Close.
        let items = adapter().windowMenu(mode: "bsp", floating: true)
        XCTAssertEqual(labels(items), ["Unfloat", "Close window"])
    }

    // MARK: - Stack mode

    func testStackModeNonFloatingMenu() {
        let items = adapter().windowMenu(mode: "stack", floating: false)
        XCTAssertEqual(labels(items),
                       ["Next stack window",
                        "Previous stack window",
                        "Float",
                        "Close window"])
        XCTAssertEqual(items[0].ops, [.cycleStackNext])
        XCTAssertEqual(items[1].ops, [.cycleStackPrev])
    }

    func testStackModeFloatingMenu() {
        // Same logic as bsp floating: a floating window in a
        // stack WS isn't on the stack, so cycle items disappear.
        let items = adapter().windowMenu(mode: "stack", floating: true)
        XCTAssertEqual(labels(items), ["Unfloat", "Close window"])
    }

    // MARK: - Universal items

    func testCloseAlwaysLastAndCloseFlagged() {
        for mode in ["float", "bsp", "stack"] {
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
        for mode in ["float", "bsp", "stack"] {
            let nonFloating = adapter().windowMenu(
                mode: mode, floating: false)
            let floating = adapter().windowMenu(
                mode: mode, floating: true)
            XCTAssertTrue(nonFloating.contains { $0.label == "Float" },
                          "mode=\(mode) non-floating → Float item")
            XCTAssertTrue(floating.contains { $0.label == "Unfloat" },
                          "mode=\(mode) floating → Unfloat item")
        }
    }

    func testUnknownModeFallsBackToFloatShape() {
        // A typo or future mode that the backend doesn't know
        // about should still produce a usable menu — at minimum
        // Float/Unfloat + Close. Same as float mode.
        let items = adapter().windowMenu(
            mode: "scrolling", floating: false)
        XCTAssertEqual(labels(items), ["Float", "Close window"])
    }
}
