import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// `NativeAdapter.windowMenu(mode:floating:isMaster:windowCount:isSticky:)`
/// is pure (no AX, no catalog state) — a per-mode lookup table for the
/// right-click / keyboard (`m` in --active) context menu, gated by the
/// window's state so master vs non-master (and a lone stack window) get
/// the right items. Every non-sticky window also offers "Sticky"; a
/// sticky window collapses to "Unstick" + "Close".
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

    private func menu(_ mode: String, floating: Bool = false,
                      isMaster: Bool = false,
                      windowCount: Int = 2,
                      isSticky: Bool = false) -> [WindowMenuItem] {
        adapter().windowMenu(mode: mode, floating: floating,
                             isMaster: isMaster, windowCount: windowCount,
                             isSticky: isSticky)
    }

    // MARK: - Float mode

    func testFloatModeNonFloatingMenu() {
        XCTAssertEqual(labels(menu("float")),
                       ["Float", "Sticky", "Close window"])
    }

    func testFloatModeFloatingMenu() {
        XCTAssertEqual(labels(menu("float", floating: true)),
                       ["Unfloat", "Sticky", "Close window"])
    }

    // MARK: - BSP mode

    func testBspModeNonFloatingMenu() {
        let items = menu("bsp")
        XCTAssertEqual(labels(items),
                       ["Toggle orientation", "Float",
                        "Sticky", "Close window"])
        XCTAssertEqual(items[0].ops, [.toggleOrientation])
    }

    func testBspModeFloatingMenu() {
        // Floating window in a bsp WS still has no orientation
        // (it's outside the tree) — menu collapses to Unfloat +
        // Sticky + Close.
        XCTAssertEqual(labels(menu("bsp", floating: true)),
                       ["Unfloat", "Sticky", "Close window"])
    }

    // MARK: - Stack mode

    func testStackModeNonFloatingMenu() {
        let items = menu("stack", windowCount: 2)
        XCTAssertEqual(labels(items),
                       ["Next stack window",
                        "Previous stack window",
                        "Float", "Sticky",
                        "Close window"])
        XCTAssertEqual(items[0].ops, [.cycleStackNext])
        XCTAssertEqual(items[1].ops, [.cycleStackPrev])
    }

    func testStackModeSingleWindowHidesCycle() {
        // Nothing to cycle to with one window — cycle items drop out.
        XCTAssertEqual(labels(menu("stack", windowCount: 1)),
                       ["Float", "Sticky", "Close window"])
    }

    func testStackModeFloatingMenu() {
        // Same logic as bsp floating: a floating window in a
        // stack WS isn't on the stack, so cycle items disappear.
        XCTAssertEqual(labels(menu("stack", floating: true)),
                       ["Unfloat", "Sticky", "Close window"])
    }

    // MARK: - Master-stack modes (master-left / -right / -top / -bottom / -center)

    /// Every master engine shows the same item set — M9-2 dropped the
    /// old "Flip wide / tall" entry (edges are now picked directly via
    /// `--layout=master-EDGE`). Parametric so master-right / -bottom are
    /// covered too.
    private let masterModes = ["master-left", "master-right", "master-top",
                               "master-bottom", "master-center"]

    func testMasterNonMasterShowsPromoteNoFlip() {
        for mode in masterModes {
            XCTAssertEqual(labels(menu(mode, isMaster: false)),
                           ["Promote to master",
                            "Wider master", "Narrower master",
                            "More masters", "Fewer masters",
                            "Float", "Sticky", "Close window"],
                           "mode=\(mode)")
        }
    }

    func testMasterHidesPromote() {
        // The master window already holds the slot — no "Promote".
        for mode in masterModes {
            let items = menu(mode, isMaster: true)
            XCTAssertFalse(labels(items).contains("Promote to master"),
                           "mode=\(mode)")
            XCTAssertEqual(labels(items),
                           ["Wider master", "Narrower master",
                            "More masters", "Fewer masters",
                            "Float", "Sticky", "Close window"],
                           "mode=\(mode)")
        }
    }

    func testNoMasterModeHasFlipItem() {
        // "Flip wide / tall" was removed in M9-2 for every mode.
        for mode in masterModes {
            XCTAssertFalse(labels(menu(mode)).contains("Flip wide / tall"),
                           "mode=\(mode)")
        }
    }

    func testMasterStackFloatingDropsTilingItems() {
        // A floating window in a master-stack WS gets neither promote
        // nor the master knobs — just Unfloat + Sticky + Close.
        for mode in masterModes {
            let items = menu(mode, floating: true, isMaster: false)
            XCTAssertEqual(labels(items), ["Unfloat", "Sticky", "Close window"],
                           "mode=\(mode)")
        }
    }

    // MARK: - Sticky

    func testStickyWindowShowsUnstickOnly() {
        // A sticky window is always floating; float-exit = sticky-exit,
        // so the menu collapses to a single "Unstick" (no "Unfloat",
        // no "Sticky") + Close. Layout items are gated out by floating.
        for mode in ["float", "bsp", "stack", "master-left", "master-center"] {
            let items = menu(mode, floating: true, isSticky: true)
            XCTAssertEqual(labels(items), ["Unstick", "Close window"],
                           "mode=\(mode)")
            XCTAssertEqual(items.first?.ops, [.toggleSticky])
        }
    }

    func testNonStickyOffersStickyToggle() {
        // Every non-sticky window — tiled or floating — can be pinned.
        for mode in ["float", "bsp", "stack", "master-left", "master-center"] {
            for floating in [false, true] {
                let item = menu(mode, floating: floating)
                    .first { $0.label == "Sticky" }
                XCTAssertEqual(item?.ops, [.toggleSticky],
                               "mode=\(mode) floating=\(floating)")
            }
        }
    }

    // MARK: - Universal items

    func testCloseAlwaysLastAndCloseFlagged() {
        for mode in ["float", "bsp", "stack", "master-left", "master-top", "master-center"] {
            for floating in [false, true] {
                let items = menu(mode, floating: floating)
                XCTAssertTrue(items.last?.isClose == true,
                              "mode=\(mode) floating=\(floating)")
                XCTAssertEqual(items.last?.label, "Close window",
                               "mode=\(mode) floating=\(floating)")
            }
        }
    }

    func testFloatToggleLabelTracksFloatingFlag() {
        for mode in ["float", "bsp", "stack", "master-left"] {
            XCTAssertTrue(menu(mode, floating: false)
                .contains { $0.label == "Float" },
                "mode=\(mode) non-floating → Float item")
            XCTAssertTrue(menu(mode, floating: true)
                .contains { $0.label == "Unfloat" },
                "mode=\(mode) floating → Unfloat item")
        }
    }

    func testUnknownModeFallsBackToFloatShape() {
        // A typo or future mode that the backend doesn't know
        // about should still produce a usable menu — at minimum
        // Float/Unfloat + Sticky + Close. Same as float mode.
        XCTAssertEqual(labels(menu("scrolling")),
                       ["Float", "Sticky", "Close window"])
    }
}
