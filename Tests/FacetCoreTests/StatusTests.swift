import XCTest
import Foundation
@testable import FacetCore

final class StatusTests: XCTestCase {

    // MARK: - Codable round-trip

    func testSnapshotRoundTripsThroughJSON() throws {
        let snap = StatusSnapshot(
            backend: "rift",
            theme: "terminal",
            defaultView: "tree",
            workspaces: [
                .init(index: 1, name: "dev",
                      active: true, windowCount: 3),
                .init(index: 2, name: "",
                      active: false, windowCount: 0),
            ],
            lastError: nil,
            timestamp: "2026-05-25T10:00:00Z")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(StatusSnapshot.self,
                                            from: data)
        XCTAssertEqual(back, snap)
    }

    // MARK: - Atomic file I/O

    func testWriteThenReadRoundTripsOnDisk() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let snap = StatusSnapshot(
            backend: "stub",
            theme: "dracula",
            defaultView: nil,
            workspaces: [
                .init(index: 1, name: "main",
                      active: true, windowCount: 5),
            ],
            lastError: "Window 99: AX permission failed",
            timestamp: "2026-05-25T11:22:33Z")
        try snap.write(to: path)
        let back = try StatusSnapshot.read(from: path)
        XCTAssertEqual(back, snap)
    }

    func testReadThrowsForMissingFile() {
        let missing = NSTemporaryDirectory()
            + "facet-status-missing-\(UUID().uuidString).json"
        XCTAssertThrowsError(try StatusSnapshot.read(from: missing))
    }

    func testEntryDecodesMissingStickyCountAsZero() throws {
        // A status file written by a pre-sticky server (no stickyCount
        // key) must decode to 0, not throw `keyNotFound` — otherwise
        // `facet status` would fail across an in-place upgrade until the
        // next reconcile rewrote the file.
        let json = Data("""
        {"index":1,"name":"dev","active":true,"windowCount":3}
        """.utf8)
        let entry = try JSONDecoder().decode(
            WorkspaceStatusEntry.self, from: json)
        XCTAssertEqual(entry.stickyCount, 0)
        XCTAssertEqual(entry.windowCount, 3)
    }

    // MARK: - Rendering

    func testRenderIncludesAllHeaderFields() {
        let snap = StatusSnapshot(
            backend: "rift",
            theme: "terminal",
            defaultView: "tree",
            workspaces: [],
            lastError: nil,
            timestamp: "2026-05-25T12:00:00Z")
        let out = snap.render()
        XCTAssertTrue(out.contains("backend: rift"))
        XCTAssertTrue(out.contains("theme: terminal"))
        XCTAssertTrue(out.contains("default-view: tree"))
        XCTAssertTrue(out.contains("last error: (none)"))
        XCTAssertTrue(out.contains("timestamp: 2026-05-25T12:00:00Z"))
        XCTAssertTrue(out.contains("workspaces:\n  (none)"))
    }

    func testRenderAgentModeWhenDefaultViewNil() {
        let snap = StatusSnapshot(
            backend: "rift",
            theme: "system",
            defaultView: nil,
            workspaces: [],
            lastError: nil,
            timestamp: "ts")
        XCTAssertTrue(snap.render().contains("default-view: (agent)"),
                      "nil defaultView renders as (agent)")
    }

    func testRenderMarksActiveAndPluralisesWindowCount() {
        let snap = StatusSnapshot(
            backend: "rift",
            theme: "terminal",
            defaultView: "grid",
            workspaces: [
                .init(index: 1, name: "dev",
                      active: true, windowCount: 1),
                .init(index: 2, name: "",
                      active: false, windowCount: 3),
            ],
            lastError: nil,
            timestamp: "ts")
        let out = snap.render()
        XCTAssertTrue(out.contains("[active]"))
        XCTAssertTrue(out.contains("\"dev\""))
        XCTAssertTrue(out.contains("1 window"),
                      "singular for count == 1")
        XCTAssertTrue(out.contains("3 windows"),
                      "plural for count > 1")
        XCTAssertFalse(out.contains("\"\""),
                       "empty workspace name should not be quoted")
    }

    func testRenderShowsStickyCountSuffixOnlyWhenNonZero() {
        let snap = StatusSnapshot(
            backend: "native",
            theme: "terminal",
            defaultView: "tree",
            workspaces: [
                .init(index: 1, name: "dev", active: true,
                      windowCount: 3, stickyCount: 1),
                .init(index: 2, name: "", active: false,
                      windowCount: 2, stickyCount: 0),
            ],
            lastError: nil,
            timestamp: "ts")
        let out = snap.render()
        XCTAssertTrue(out.contains("3 windows, 1 sticky"),
                      "sticky suffix shown when count > 0")
        XCTAssertFalse(out.contains("0 sticky"),
                       "no sticky suffix when count is 0")
    }

    func testSnapshotDecodesMissingStashedAsEmpty() throws {
        // A status file written by a pre-scratchpad server (no `stashed`
        // key) must decode to [] rather than throw, so `facet status`
        // survives an in-place upgrade until the next reconcile.
        let json = Data("""
        {"backend":"native","theme":"terminal","defaultView":"tree",
         "workspaces":[],"timestamp":"ts"}
        """.utf8)
        let snap = try JSONDecoder().decode(StatusSnapshot.self, from: json)
        XCTAssertEqual(snap.stashed, [])
        XCTAssertNil(snap.lastError)
    }

    func testRenderShowsStashedLineOnlyWhenNonEmpty() {
        let withShelf = StatusSnapshot(
            backend: "native", theme: "terminal", defaultView: "tree",
            workspaces: [], stashed: ["editor", "notes"],
            lastError: nil, timestamp: "ts")
        XCTAssertTrue(withShelf.render().contains("stashed: editor, notes"),
                      "stashed line lists shelf names when non-empty")
        let none = StatusSnapshot(
            backend: "native", theme: "terminal", defaultView: "tree",
            workspaces: [], stashed: [],
            lastError: nil, timestamp: "ts")
        XCTAssertFalse(none.render().contains("stashed:"),
                       "no stashed line when there are no shelves")
    }

    func testRenderSurfacesLastError() {
        let snap = StatusSnapshot(
            backend: "rift",
            theme: "terminal",
            defaultView: "tree",
            workspaces: [],
            lastError: "Window 7: AX permission failed",
            timestamp: "ts")
        XCTAssertTrue(snap.render().contains(
            "last error: Window 7: AX permission failed"))
    }

    // MARK: - Helpers

    private func tempPath() -> String {
        NSTemporaryDirectory()
            + "facet-status-test-\(UUID().uuidString).json"
    }
}
