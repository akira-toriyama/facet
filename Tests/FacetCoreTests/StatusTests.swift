import XCTest
import Foundation
@testable import FacetCore

final class StatusTests: XCTestCase {

    // MARK: - Codable round-trip

    func testSnapshotRoundTripsThroughJSON() throws {
        let snap = StatusSnapshot(
            backend: "rift",
            hideMethod: "anchor",
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
            hideMethod: "minimize",
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

    // MARK: - Rendering

    func testRenderIncludesAllHeaderFields() {
        let snap = StatusSnapshot(
            backend: "rift",
            hideMethod: "anchor",
            workspaces: [],
            lastError: nil,
            timestamp: "2026-05-25T12:00:00Z")
        let out = snap.render()
        XCTAssertTrue(out.contains("backend: rift"))
        XCTAssertTrue(out.contains("hide_method: anchor"))
        XCTAssertTrue(out.contains("last error: (none)"))
        XCTAssertTrue(out.contains("timestamp: 2026-05-25T12:00:00Z"))
        XCTAssertTrue(out.contains("workspaces:\n  (none)"))
    }

    func testRenderMarksActiveAndPluralisesWindowCount() {
        let snap = StatusSnapshot(
            backend: "rift",
            hideMethod: "anchor",
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

    func testRenderSurfacesLastError() {
        let snap = StatusSnapshot(
            backend: "rift",
            hideMethod: "anchor",
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
