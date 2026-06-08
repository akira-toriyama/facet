import XCTest
import CoreGraphics
@testable import FacetCore

final class ModelsTests: XCTestCase {

    func testWindowIDIdentityIsServerIDAlone() {
        // Two WindowIDs with the same serverID are interchangeable —
        // this is what lets the controller match a window across two
        // `workspaces()` snapshots even when the surrounding state
        // (focus / floating / title) has changed.
        let a = WindowID(serverID: 42)
        let b = WindowID(serverID: 42)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testWorkspaceCarriesItsWindowsInOrder() {
        let ws = Workspace(
            index: 1, name: "code", isActive: true,
            layoutMode: "bsp",
            windows: [
                Window(id: WindowID(serverID: 1), pid: 100,
                       appName: "Code", title: "main.swift",
                       isFocused: true, isFloating: false,
                       frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                Window(id: WindowID(serverID: 2), pid: 100,
                       appName: "Code", title: "models.swift",
                       isFocused: false, isFloating: false,
                       frame: nil),
            ])
        XCTAssertEqual(ws.windows.map(\.id.serverID), [1, 2])
        XCTAssertEqual(ws.windows.first?.frame?.width, 800)
        XCTAssertNil(ws.windows.last?.frame)
    }

    // MARK: - Sequence<Window>.predictedFocus

    /// Minimal Window for focus-pick tests — only `serverID` +
    /// `isFocused` matter to `predictedFocus`.
    private func win(_ serverID: Int, focused: Bool) -> Window {
        Window(id: WindowID(serverID: serverID), pid: 100,
               appName: "App", title: "w\(serverID)",
               isFocused: focused, isFloating: false, frame: nil)
    }

    func testPredictedFocusEmptyIsNil() {
        XCTAssertNil([Window]().predictedFocus())
    }

    func testPredictedFocusPrefersTheFocusedWindow() {
        // The focused window wins even when it isn't the oldest.
        let wins = [win(1, focused: false),
                    win(5, focused: true),
                    win(2, focused: false)]
        XCTAssertEqual(wins.predictedFocus()?.id.serverID, 5)
    }

    func testPredictedFocusFallsBackToOldestServerID() {
        // No focus → the lowest serverID (longest-resident window).
        let wins = [win(7, focused: false),
                    win(3, focused: false),
                    win(9, focused: false)]
        XCTAssertEqual(wins.predictedFocus()?.id.serverID, 3)
    }

    func testPredictedFocusFocusedBeatsOlderUnfocused() {
        let wins = [win(2, focused: false), win(8, focused: true)]
        XCTAssertEqual(wins.predictedFocus()?.id.serverID, 8)
    }
}
