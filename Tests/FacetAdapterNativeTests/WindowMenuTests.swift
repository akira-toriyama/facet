import Testing
@testable import FacetCore
@testable import FacetAdapterNative

/// `NativeAdapter.windowMenu(mode:floating:isMaster:windowCount:isSticky:)`
/// is pure (no AX, no catalog state) — a per-mode lookup table for the
/// right-click / keyboard (`m` in keyboard nav) context menu, gated by the
/// window's state so master vs non-master (and a lone stack window) get
/// the right items. Every non-sticky window also offers "Sticky"; a
/// sticky window collapses to "Unstick" + "Close".
struct WindowMenuTests {

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

    @Test func floatModeNonFloatingMenu() {
        #expect(labels(menu("float")) ==
                       ["Float", "Sticky", "Close window"])
    }

    @Test func floatModeFloatingMenu() {
        #expect(labels(menu("float", floating: true)) ==
                       ["Unfloat", "Sticky", "Close window"])
    }

    // MARK: - BSP mode

    @Test func bspModeNonFloatingMenu() {
        let items = menu("bsp")
        #expect(labels(items) ==
                       ["Toggle orientation", "Float",
                        "Sticky", "Close window"])
        #expect(items[0].ops == [.toggleOrientation])
    }

    @Test func bspModeFloatingMenu() {
        // Floating window in a bsp WS still has no orientation
        // (it's outside the tree) — menu collapses to Unfloat +
        // Sticky + Close.
        #expect(labels(menu("bsp", floating: true)) ==
                       ["Unfloat", "Sticky", "Close window"])
    }

    // MARK: - Stack mode

    @Test func stackModeNonFloatingMenu() {
        let items = menu("stack", windowCount: 2)
        #expect(labels(items) ==
                       ["Next stack window",
                        "Previous stack window",
                        "Float", "Sticky",
                        "Close window"])
        #expect(items[0].ops == [.cycleStackNext])
        #expect(items[1].ops == [.cycleStackPrev])
    }

    @Test func stackModeSingleWindowHidesCycle() {
        // Nothing to cycle to with one window — cycle items drop out.
        #expect(labels(menu("stack", windowCount: 1)) ==
                       ["Float", "Sticky", "Close window"])
    }

    @Test func stackModeFloatingMenu() {
        // Same logic as bsp floating: a floating window in a
        // stack WS isn't on the stack, so cycle items disappear.
        #expect(labels(menu("stack", floating: true)) ==
                       ["Unfloat", "Sticky", "Close window"])
    }

    // MARK: - Master-stack modes (master-left / -right / -top / -bottom / -center)

    /// Every master engine shows the same item set — M9-2 dropped the
    /// old "Flip wide / tall" entry (edges are now picked directly via
    /// `--layout=master-EDGE`). Parametric so master-right / -bottom are
    /// covered too.
    private let masterModes = ["master-left", "master-right", "master-top",
                               "master-bottom", "master-center"]

    @Test func masterNonMasterShowsPromoteNoFlip() {
        for mode in masterModes {
            #expect(labels(menu(mode, isMaster: false)) ==
                           ["Promote to master",
                            "Wider master", "Narrower master",
                            "More masters", "Fewer masters",
                            "Float", "Sticky", "Close window"],
                           "mode=\(mode)")
        }
    }

    @Test func masterHidesPromote() {
        // The master window already holds the slot — no "Promote".
        for mode in masterModes {
            let items = menu(mode, isMaster: true)
            #expect(!labels(items).contains("Promote to master"),
                           "mode=\(mode)")
            #expect(labels(items) ==
                           ["Wider master", "Narrower master",
                            "More masters", "Fewer masters",
                            "Float", "Sticky", "Close window"],
                           "mode=\(mode)")
        }
    }

    @Test func noMasterModeHasFlipItem() {
        // "Flip wide / tall" was removed in M9-2 for every mode.
        for mode in masterModes {
            #expect(!labels(menu(mode)).contains("Flip wide / tall"),
                           "mode=\(mode)")
        }
    }

    @Test func masterStackFloatingDropsTilingItems() {
        // A floating window in a master-stack WS gets neither promote
        // nor the master knobs — just Unfloat + Sticky + Close.
        for mode in masterModes {
            let items = menu(mode, floating: true, isMaster: false)
            #expect(labels(items) == ["Unfloat", "Sticky", "Close window"],
                           "mode=\(mode)")
        }
    }

    // MARK: - Sticky

    @Test func stickyWindowShowsUnstickOnly() {
        // A sticky window is always floating; float-exit = sticky-exit,
        // so the menu collapses to a single "Unstick" (no "Unfloat",
        // no "Sticky") + Close. Layout items are gated out by floating.
        for mode in ["float", "bsp", "stack", "master-left", "master-center"] {
            let items = menu(mode, floating: true, isSticky: true)
            #expect(labels(items) == ["Unstick", "Close window"],
                           "mode=\(mode)")
            #expect(items.first?.ops == [.toggleSticky])
        }
    }

    @Test func nonStickyOffersStickyToggle() {
        // Every non-sticky window — tiled or floating — can be pinned.
        for mode in ["float", "bsp", "stack", "master-left", "master-center"] {
            for floating in [false, true] {
                let item = menu(mode, floating: floating)
                    .first { $0.label == "Sticky" }
                #expect(item?.ops == [.toggleSticky],
                               "mode=\(mode) floating=\(floating)")
            }
        }
    }

    // MARK: - Universal items

    @Test func closeAlwaysLastAndCloseFlagged() {
        for mode in ["float", "bsp", "stack", "master-left", "master-top", "master-center"] {
            for floating in [false, true] {
                let items = menu(mode, floating: floating)
                #expect(items.last?.isClose == true,
                              "mode=\(mode) floating=\(floating)")
                #expect(items.last?.label == "Close window",
                               "mode=\(mode) floating=\(floating)")
            }
        }
    }

    @Test func floatToggleLabelTracksFloatingFlag() {
        for mode in ["float", "bsp", "stack", "master-left"] {
            #expect(menu(mode, floating: false)
                .contains { $0.label == "Float" },
                "mode=\(mode) non-floating → Float item")
            #expect(menu(mode, floating: true)
                .contains { $0.label == "Unfloat" },
                "mode=\(mode) floating → Unfloat item")
        }
    }

    @Test func unknownModeFallsBackToFloatShape() {
        // A typo or future mode that the backend doesn't know
        // about should still produce a usable menu — at minimum
        // Float/Unfloat + Sticky + Close. Same as float mode.
        #expect(labels(menu("scrolling")) ==
                       ["Float", "Sticky", "Close window"])
    }
}
