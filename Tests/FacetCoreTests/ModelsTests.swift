import Testing
import CoreGraphics
@testable import FacetCore

struct ModelsTests {

    @Test func windowIDIdentityIsServerIDAlone() {
        // Two WindowIDs with the same serverID are interchangeable —
        // this is what lets the controller match a window across two
        // `workspaces()` snapshots even when the surrounding state
        // (focus / floating / title) has changed.
        let a = WindowID(serverID: 42)
        let b = WindowID(serverID: 42)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func workspaceCarriesItsWindowsInOrder() {
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
        #expect(ws.windows.map(\.id.serverID) == [1, 2])
        #expect(ws.windows.first?.frame?.width == 800)
        #expect(ws.windows.last?.frame == nil)
    }

    // MARK: - Sequence<Window>.predictedFocus

    /// Minimal Window for focus-pick tests — only `serverID` +
    /// `isFocused` matter to `predictedFocus`.
    private func win(_ serverID: Int, focused: Bool) -> Window {
        Window(id: WindowID(serverID: serverID), pid: 100,
               appName: "App", title: "w\(serverID)",
               isFocused: focused, isFloating: false, frame: nil)
    }

    @Test func predictedFocusEmptyIsNil() {
        #expect([Window]().predictedFocus() == nil)
    }

    @Test func predictedFocusPrefersTheFocusedWindow() {
        // The focused window wins even when it isn't the oldest.
        let wins = [win(1, focused: false),
                    win(5, focused: true),
                    win(2, focused: false)]
        #expect(wins.predictedFocus()?.id.serverID == 5)
    }

    @Test func predictedFocusFallsBackToOldestServerID() {
        // No focus → the lowest serverID (longest-resident window).
        let wins = [win(7, focused: false),
                    win(3, focused: false),
                    win(9, focused: false)]
        #expect(wins.predictedFocus()?.id.serverID == 3)
    }

    @Test func predictedFocusFocusedBeatsOlderUnfocused() {
        let wins = [win(2, focused: false), win(8, focused: true)]
        #expect(wins.predictedFocus()?.id.serverID == 8)
    }
}
