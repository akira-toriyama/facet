import XCTest
@testable import FacetCore

/// In-memory `WindowBackend` used to exercise the protocol surface in
/// pure-logic tests. Adapters get their own contract tests under
/// their module — this is just enough to prove the protocol compiles
/// and that views/controller code can be written against it.
///
/// `@unchecked Sendable` is OK here because every test method touches
/// this instance from a single thread (XCTest's test runner) — no
/// real cross-actor sharing. Production conformers (`FacetAdapterRift`
/// et al.) earn their Sendable conformance via internal serialization.
private final class StubBackend: WindowBackend, @unchecked Sendable {
    let name = "stub"
    let layoutModes = ["bsp", "stack"]
    var state: [Workspace] = []
    var focused: WindowID?
    private(set) var switched: [Int] = []
    private(set) var moved: [(WindowID, Int)] = []
    private(set) var layoutChanges: [(Int, String)] = []
    private(set) var closed: [WindowID] = []
    private(set) var performed: [WindowAction] = []

    func workspaces() -> [Workspace] { state }
    func focusedWindow() -> WindowID? { focused }

    func switchWorkspace(toIndex index: Int) { switched.append(index) }
    func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        moved.append((id, index))
    }
    func setLayoutMode(workspaceIndex index: Int, mode: String) {
        layoutChanges.append((index, mode))
    }
    func closeWindow(_ id: WindowID) { closed.append(id) }
    func perform(_ action: WindowAction) { performed.append(action) }

    func windowMenu(mode: String, floating: Bool) -> [WindowMenuItem] {
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

final class BackendTests: XCTestCase {

    func testWindowMenuItemRetainsOpsInOrder() {
        let item = WindowMenuItem("Unfloat & promote",
                                  [.toggleFloat, .promoteToMaster])
        XCTAssertEqual(item.label, "Unfloat & promote")
        XCTAssertEqual(item.ops.count, 2)
        XCTAssertFalse(item.isClose)
    }

    func testWindowMenuItemCloseFlagDefaultsOff() {
        let normal = WindowMenuItem("Float", [.toggleFloat])
        let close = WindowMenuItem("Close", [], close: true)
        XCTAssertFalse(normal.isClose)
        XCTAssertTrue(close.isClose)
    }

    func testBackendRecordsControllerSideEffects() {
        let b = StubBackend()
        let win = WindowID(serverID: 7)
        b.switchWorkspace(toIndex: 3)
        b.moveWindow(win, toWorkspaceIndex: 2)
        b.setLayoutMode(workspaceIndex: 2, mode: "stack")
        b.closeWindow(win)
        b.perform(.toggleFullscreen)

        XCTAssertEqual(b.switched, [3])
        XCTAssertEqual(b.moved.count, 1)
        XCTAssertEqual(b.moved[0].0, win)
        XCTAssertEqual(b.moved[0].1, 2)
        XCTAssertEqual(b.layoutChanges.count, 1)
        XCTAssertEqual(b.layoutChanges[0].0, 2)
        XCTAssertEqual(b.layoutChanges[0].1, "stack")
        XCTAssertEqual(b.closed, [win])
        XCTAssertEqual(b.performed, [.toggleFullscreen])
    }

    func testWindowMenuVariesByMode() {
        let b = StubBackend()
        XCTAssertEqual(b.windowMenu(mode: "bsp", floating: false).first?.label,
                       "Toggle stack")
        XCTAssertEqual(b.windowMenu(mode: "stack", floating: false).first?.label,
                       "Float")
        XCTAssertEqual(b.windowMenu(mode: "bsp", floating: true)
                        .map(\.label),
                       ["Toggle stack", "Unfloat", "Close window"])
    }
}

