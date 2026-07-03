import Testing
@testable import FacetCore

/// In-memory `WindowBackend` used to exercise the protocol surface in
/// pure-logic tests. Adapters get their own contract tests under
/// their module — this is just enough to prove the protocol compiles
/// and that views/controller code can be written against it.
///
/// `@unchecked Sendable` is OK here because every test method touches
/// this instance from a single thread (XCTest's test runner) — no
/// real cross-actor sharing. The production conformer (`NativeAdapter`)
/// earns its Sendable conformance via internal serialization.
private final class StubBackend: WindowBackend, @unchecked Sendable {
    let name = "stub"
    let layoutModes = ["bsp", "stack"]
    var state: [Workspace] = []
    var focused: WindowID?
    private(set) var switched: [Int] = []
    private(set) var switchedRelative: [RelativeWorkspace] = []
    private(set) var moved: [(WindowID, Int)] = []
    private(set) var layoutChanges: [(Int, String)] = []
    private(set) var closed: [WindowID] = []
    private(set) var performed: [WindowAction] = []

    func workspaces() -> [Workspace] { state }
    func focusedWindow() -> WindowID? { focused }

    func switchWorkspace(toIndex index: Int, autoFocus: Bool) {
        switched.append(index)
    }
    func switchWorkspaceRelative(_ target: RelativeWorkspace,
                                 autoFocus: Bool) {
        switchedRelative.append(target)
    }
    func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        moved.append((id, index))
    }
    func setLayoutMode(workspaceIndex index: Int, mode: String) {
        layoutChanges.append((index, mode))
    }
    func closeWindow(_ id: WindowID) { closed.append(id) }
    func perform(_ action: WindowAction) { performed.append(action) }
    func retileActiveWorkspace() { retileCalls += 1 }
    var retileCalls = 0

    func windowMenu(mode: String, floating: Bool,
                    isMaster: Bool, windowCount: Int,
                    isSticky: Bool) -> [WindowMenuItem] {
        var items: [WindowMenuItem] = []
        if mode == "bsp" {
            items.append(.init("Toggle stack", [.toggleStack]))
        }
        items.append(.init(floating ? "Unfloat" : "Float", [.toggleFloat]))
        items.append(.init("Close window", [], close: true))
        return items
    }
    // Stream that never emits — sufficient for protocol-shape tests
    // here. Adapter modules have their own event-plumbing tests.
    var events: AsyncStream<BackendEvent> {
        AsyncStream { _ in }
    }
    var errors: AsyncStream<String> {
        AsyncStream { _ in }
    }
}

struct BackendTests {

    @Test func windowMenuItemRetainsOpsInOrder() {
        let item = WindowMenuItem("Unfloat & promote",
                                  [.toggleFloat, .promoteToMaster])
        #expect(item.label == "Unfloat & promote")
        #expect(item.ops.count == 2)
        #expect(!(item.isClose))
    }

    @Test func windowMenuItemCloseFlagDefaultsOff() {
        let normal = WindowMenuItem("Float", [.toggleFloat])
        let close = WindowMenuItem("Close", [], close: true)
        #expect(!(normal.isClose))
        #expect(close.isClose)
    }

    @Test func backendRecordsControllerSideEffects() {
        let b = StubBackend()
        let win = WindowID(serverID: 7)
        b.switchWorkspace(toIndex: 3)
        b.moveWindow(win, toWorkspaceIndex: 2)
        b.setLayoutMode(workspaceIndex: 2, mode: "stack")
        b.closeWindow(win)
        b.perform(.toggleFullscreen)
        b.perform(.cycleStackNext)
        b.perform(.cycleStackPrev)
        b.retileActiveWorkspace()

        #expect(b.switched == [3])
        #expect(b.moved.count == 1)
        #expect(b.moved[0].0 == win)
        #expect(b.moved[0].1 == 2)
        #expect(b.layoutChanges.count == 1)
        #expect(b.layoutChanges[0].0 == 2)
        #expect(b.layoutChanges[0].1 == "stack")
        #expect(b.closed == [win])
        // perform passes the enum through unchanged, in order.
        #expect(b.performed ==
                       [.toggleFullscreen,
                        .cycleStackNext,
                        .cycleStackPrev])
        #expect(b.retileCalls == 1)
    }

    @Test func windowMenuVariesByMode() {
        let b = StubBackend()
        #expect(b.windowMenu(mode: "bsp", floating: false,
                                    isMaster: false, windowCount: 2,
                                    isSticky: false)
                        .first?.label == "Toggle stack")
        #expect(b.windowMenu(mode: "stack", floating: false,
                                    isMaster: false, windowCount: 2,
                                    isSticky: false)
                        .first?.label == "Float")
        #expect(b.windowMenu(mode: "bsp", floating: true,
                                    isMaster: false, windowCount: 2,
                                    isSticky: false)
                        .map(\.label) ==
                       ["Toggle stack", "Unfloat", "Close window"])
    }
}
