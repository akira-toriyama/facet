import Testing
@testable import FacetAccessibility
import FacetCore

/// `Focus.assertBlocking` — the synchronous focus-confirm loop that gates
/// cross-workspace window-ops (audit controller-04). The ops act on the
/// FOCUSED window, so the loop must keep re-asserting AX focus until the
/// backend's own focused-window state matches the target, then return
/// `true`; or give up after the attempt cap and return `false`.
///
/// The live WM post-switch default-focus race can't be reproduced
/// deterministically, so this pins the *mechanism* the fix relies on: a
/// stub whose `focusedWindow()` only matches after N calls stands in for
/// the WM settling focus a few re-asserts late.
struct FocusAssertBlockingTests {

    /// Minimal `WindowBackend` (most requirements have protocol-extension
    /// defaults) whose `focusedWindow()` returns `target` from the
    /// `confirmOnCall`-th call onward. `Int.max` = never confirms.
    private final class FocusStub: WindowBackend, @unchecked Sendable {
        let name = "stub"
        let layoutModes: [String] = []
        let target: WindowID
        let confirmOnCall: Int
        private(set) var focusCalls = 0

        init(target: WindowID, confirmOnCall: Int) {
            self.target = target
            self.confirmOnCall = confirmOnCall
        }

        func workspaces() -> [Workspace] { [] }
        func focusedWindow() -> WindowID? {
            focusCalls += 1
            return focusCalls >= confirmOnCall ? target : nil
        }
        func switchWorkspace(toIndex index: Int, autoFocus: Bool) {}
        func switchWorkspaceRelative(_ target: RelativeWorkspace,
                                     autoFocus: Bool) {}
        func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {}
        func setLayoutMode(workspaceIndex index: Int, mode: String) {}
        func closeWindow(_ id: WindowID) {}
        func perform(_ action: WindowAction) {}
        func retileActiveWorkspace() {}
        func windowMenu(mode: String, floating: Bool, isMaster: Bool,
                        windowCount: Int, isSticky: Bool) -> [WindowMenuItem] { [] }
        var events: AsyncStream<BackendEvent> { AsyncStream { _ in } }
        var errors: AsyncStream<String> { AsyncStream { _ in } }
    }

    private func win(_ n: Int) -> Window {
        Window(id: WindowID(serverID: n), pid: 1, appName: "A", title: "w",
               isFocused: false, isFloating: false, frame: nil)
    }

    @Test func returnsTrueOnceBackendConfirms() {
        let target = win(42)
        let stub = FocusStub(target: target.id, confirmOnCall: 3)
        // Keeps re-asserting until the backend reports the target focused.
        let ok = Focus.assertBlocking(target, backend: stub, attempts: 10)
        #expect(ok)
        #expect(stub.focusCalls == 3)
    }

    @Test func returnsFalseWhenNeverConfirms() {
        let target = win(7)
        let stub = FocusStub(target: target.id, confirmOnCall: Int.max)
        // Gives up after exactly `attempts` ground-truth checks.
        let ok = Focus.assertBlocking(target, backend: stub, attempts: 3)
        #expect(!ok)
        #expect(stub.focusCalls == 3)
    }

    @Test func confirmsImmediatelyWhenAlreadyOnTarget() {
        let target = win(5)
        let stub = FocusStub(target: target.id, confirmOnCall: 1)
        let ok = Focus.assertBlocking(target, backend: stub, attempts: 50)
        #expect(ok)
        #expect(stub.focusCalls == 1)   // no wasted re-asserts
    }
}
