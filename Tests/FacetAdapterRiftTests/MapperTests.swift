import XCTest
import Foundation
@testable import FacetAdapterRift
import FacetCore

/// JSON-fixture round-trip for `RiftMapper`. The mapper is the only
/// adapter component we can exercise without an installed `rift-cli`,
/// so it carries the bulk of the test budget here. CLI-touching code
/// (`RiftCLI.run`, `EventSource`) gets exercised in CI integration
/// jobs that boot rift, not in unit tests.
final class MapperTests: XCTestCase {

    func testWorkspaceJSONRoundTripPreservesShape() throws {
        let json = #"""
        [
          {
            "index": 1,
            "is_active": true,
            "name": "code",
            "layout_mode": "bsp",
            "windows": [
              {
                "app_name": "Code",
                "id": { "idx": 7, "pid": 4321 },
                "is_focused": true,
                "is_floating": false,
                "title": "main.swift",
                "window_server_id": 9001,
                "frame": {
                  "origin": { "x": 100, "y": 200 },
                  "size":   { "width": 800, "height": 600 }
                }
              },
              {
                "app_name": "Code",
                "id": { "idx": 8, "pid": 4321 },
                "is_focused": false,
                "title": "models.swift",
                "window_server_id": 9002
              }
            ]
          }
        ]
        """#
        let raw = try JSONDecoder().decode(
            [RFWorkspace].self, from: Data(json.utf8))
        XCTAssertEqual(raw.count, 1)

        let ws = RiftMapper.workspace(from: raw[0])
        XCTAssertEqual(ws.index, 1)
        XCTAssertEqual(ws.name, "code")
        XCTAssertTrue(ws.isActive)
        XCTAssertEqual(ws.layoutMode, "bsp")
        XCTAssertEqual(ws.windows.count, 2)

        let w0 = ws.windows[0]
        XCTAssertEqual(w0.id, WindowID(serverID: 9001))
        XCTAssertEqual(w0.pid, 4321)
        XCTAssertEqual(w0.appName, "Code")
        XCTAssertEqual(w0.title, "main.swift")
        XCTAssertTrue(w0.isFocused)
        XCTAssertFalse(w0.isFloating)
        XCTAssertEqual(w0.frame?.origin.x, 100)
        XCTAssertEqual(w0.frame?.size.width, 800)

        // Window without `is_floating` and `frame` keys: floating
        // defaults to false (matches ws-tabs behavior); frame is nil.
        let w1 = ws.windows[1]
        XCTAssertFalse(w1.isFloating)
        XCTAssertNil(w1.frame)
    }

    func testMissingIsFloatingDefaultsToFalse() throws {
        // Direct mapper test (no JSON) to pin down the contract.
        let rf = RFWindow(
            app_name: "Term",
            id: RFWinId(idx: 1, pid: 100),
            is_focused: false,
            is_floating: nil,
            title: "",
            window_server_id: 42,
            frame: nil)
        let w = RiftMapper.window(from: rf)
        XCTAssertFalse(w.isFloating,
            "rift omits is_floating for non-tileable workspaces; absent must mean not floating")
    }

    func testWorkspaceWindowsMappedInOrder() {
        let rfWorkspace = RFWorkspace(
            index: 3, is_active: false, name: "ws3",
            layout_mode: "stack",
            windows: (1...5).map { i in
                RFWindow(app_name: "App\(i)",
                         id: RFWinId(idx: i, pid: 100 + i),
                         is_focused: false,
                         is_floating: false,
                         title: "win\(i)",
                         window_server_id: 9000 + i,
                         frame: nil)
            })
        let ws = RiftMapper.workspace(from: rfWorkspace)
        XCTAssertEqual(ws.windows.map(\.id.serverID),
                       [9001, 9002, 9003, 9004, 9005])
    }
}
