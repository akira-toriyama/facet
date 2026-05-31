import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// `NativeAdapter.windowMenu(mode:floating:isMaster:windowCount:)` is
/// pure (no AX, no catalog state) — a per-mode lookup table for the
/// right-click menu, gated by the window's state so master vs
/// non-master (and a lone stack window) get the right items.
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
                      windowCount: Int = 2) -> [WindowMenuItem] {
        adapter().windowMenu(mode: mode, floating: floating,
                             isMaster: isMaster, windowCount: windowCount)
    }

    // MARK: - Float mode

    func testFloatModeNonFloatingMenu() {
        XCTAssertEqual(labels(menu("float")), ["Float", "Close window"])
    }

    func testFloatModeFloatingMenu() {
        XCTAssertEqual(labels(menu("float", floating: true)),
                       ["Unfloat", "Close window"])
    }

    // MARK: - BSP mode

    func testBspModeNonFloatingMenu() {
        let items = menu("bsp")
        XCTAssertEqual(labels(items),
                       ["Toggle orientation", "Float", "Close window"])
        XCTAssertEqual(items[0].ops, [.toggleOrientation])
    }

    func testBspModeFloatingMenu() {
        // Floating window in a bsp WS still has no orientation
        // (it's outside the tree) — menu collapses to Unfloat +
        // Close.
        XCTAssertEqual(labels(menu("bsp", floating: true)),
                       ["Unfloat", "Close window"])
    }

    // MARK: - Stack mode

    func testStackModeNonFloatingMenu() {
        let items = menu("stack", windowCount: 2)
        XCTAssertEqual(labels(items),
                       ["Next stack window",
                        "Previous stack window",
                        "Float",
                        "Close window"])
        XCTAssertEqual(items[0].ops, [.cycleStackNext])
        XCTAssertEqual(items[1].ops, [.cycleStackPrev])
    }

    func testStackModeSingleWindowHidesCycle() {
        // Nothing to cycle to with one window — cycle items drop out.
        XCTAssertEqual(labels(menu("stack", windowCount: 1)),
                       ["Float", "Close window"])
    }

    func testStackModeFloatingMenu() {
        // Same logic as bsp floating: a floating window in a
        // stack WS isn't on the stack, so cycle items disappear.
        XCTAssertEqual(labels(menu("stack", floating: true)),
                       ["Unfloat", "Close window"])
    }

    // MARK: - Master-stack modes (tall / wide / centered)

    func testTallNonMasterShowsPromote() {
        let items = menu("tall", isMaster: false)
        XCTAssertEqual(labels(items),
                       ["Promote to master",
                        "Wider master", "Narrower master",
                        "More masters", "Fewer masters",
                        "Flip wide / tall",
                        "Float", "Close window"])
    }

    func testTallMasterHidesPromote() {
        // The master window already holds the slot — no "Promote".
        let items = menu("tall", isMaster: true)
        XCTAssertFalse(labels(items).contains("Promote to master"))
        XCTAssertEqual(labels(items),
                       ["Wider master", "Narrower master",
                        "More masters", "Fewer masters",
                        "Flip wide / tall",
                        "Float", "Close window"])
    }

    func testWideMirrorsTall() {
        // wide is tall's horizontal twin — same master items + flip.
        let items = menu("wide", isMaster: false)
        XCTAssertEqual(labels(items),
                       ["Promote to master",
                        "Wider master", "Narrower master",
                        "More masters", "Fewer masters",
                        "Flip wide / tall",
                        "Float", "Close window"])
    }

    func testCenteredNonMasterShowsPromote() {
        let items = menu("centered", isMaster: false)
        XCTAssertEqual(labels(items),
                       ["Promote to master",
                        "Wider master", "Narrower master",
                        "More masters", "Fewer masters",
                        "Float", "Close window"])
    }

    func testCenteredMasterHidesPromote() {
        let items = menu("centered", isMaster: true)
        XCTAssertFalse(labels(items).contains("Promote to master"))
    }

    func testCenteredHasNoFlipItem() {
        // "Flip wide / tall" is only for the tall/wide pair.
        XCTAssertFalse(labels(menu("centered")).contains("Flip wide / tall"))
    }

    func testMasterStackFloatingDropsTilingItems() {
        // A floating window in a master-stack WS gets neither promote
        // nor the master knobs.
        let items = menu("tall", floating: true, isMaster: false)
        XCTAssertEqual(labels(items), ["Unfloat", "Close window"])
    }

    // MARK: - Universal items

    func testCloseAlwaysLastAndCloseFlagged() {
        for mode in ["float", "bsp", "stack", "tall", "wide", "centered"] {
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
        for mode in ["float", "bsp", "stack", "tall"] {
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
        // Float/Unfloat + Close. Same as float mode.
        XCTAssertEqual(labels(menu("scrolling")), ["Float", "Close window"])
    }
}
