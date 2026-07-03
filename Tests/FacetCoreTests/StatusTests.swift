import Testing
import Foundation
@testable import FacetCore

struct StatusTests {

    // MARK: - Codable round-trip

    @Test func snapshotRoundTripsThroughJSON() throws {
        let snap = StatusSnapshot(
            backend: "native",
            theme: "terminal",
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
        #expect(back == snap)
    }

    // MARK: - Atomic file I/O

    @Test func writeThenReadRoundTripsOnDisk() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let snap = StatusSnapshot(
            backend: "stub",
            theme: "dracula",
            workspaces: [
                .init(index: 1, name: "main",
                      active: true, windowCount: 5),
            ],
            lastError: "Window 99: AX permission failed",
            timestamp: "2026-05-25T11:22:33Z")
        try snap.write(to: path)
        let back = try StatusSnapshot.read(from: path)
        #expect(back == snap)
    }

    @Test func readThrowsForMissingFile() {
        let missing = NSTemporaryDirectory()
            + "facet-status-missing-\(UUID().uuidString).json"
        #expect(throws: (any Error).self) {
            try StatusSnapshot.read(from: missing)
        }
    }

    @Test func entryDecodesMissingStickyCountAsZero() throws {
        // A status file written by a pre-sticky server (no stickyCount
        // key) must decode to 0, not throw `keyNotFound` — otherwise
        // `facet query` would fail across an in-place upgrade until the
        // next reconcile rewrote the file.
        let json = Data("""
        {"index":1,"name":"dev","active":true,"windowCount":3}
        """.utf8)
        let entry = try JSONDecoder().decode(
            WorkspaceStatusEntry.self, from: json)
        #expect(entry.stickyCount == 0)
        #expect(entry.windowCount == 3)
    }

    // MARK: - Rendering

    @Test func renderIncludesAllHeaderFields() {
        let snap = StatusSnapshot(
            backend: "native",
            theme: "terminal",
            workspaces: [],
            lastError: nil,
            timestamp: "2026-05-25T12:00:00Z")
        let out = snap.render()
        #expect(out.contains("backend: native"))
        #expect(out.contains("theme: terminal"))
        #expect(out.contains("last error: (none)"))
        #expect(out.contains("timestamp: 2026-05-25T12:00:00Z"))
        #expect(out.contains("workspaces:\n  (none)"))
    }

    @Test func renderMarksActiveAndPluralisesWindowCount() {
        let snap = StatusSnapshot(
            backend: "native",
            theme: "terminal",
            workspaces: [
                .init(index: 1, name: "dev",
                      active: true, windowCount: 1),
                .init(index: 2, name: "",
                      active: false, windowCount: 3),
            ],
            lastError: nil,
            timestamp: "ts")
        let out = snap.render()
        #expect(out.contains("[active]"))
        #expect(out.contains("\"dev\""))
        #expect(out.contains("1 window"),
                "singular for count == 1")
        #expect(out.contains("3 windows"),
                "plural for count > 1")
        #expect(!(out.contains("\"\"")),
                "empty workspace name should not be quoted")
    }

    @Test func renderShowsStickyCountSuffixOnlyWhenNonZero() {
        let snap = StatusSnapshot(
            backend: "native",
            theme: "terminal",
            workspaces: [
                .init(index: 1, name: "dev", active: true,
                      windowCount: 3, stickyCount: 1),
                .init(index: 2, name: "", active: false,
                      windowCount: 2, stickyCount: 0),
            ],
            lastError: nil,
            timestamp: "ts")
        let out = snap.render()
        #expect(out.contains("3 windows, 1 sticky"),
                "sticky suffix shown when count > 0")
        #expect(!(out.contains("0 sticky")),
                "no sticky suffix when count is 0")
    }

    @Test func snapshotDecodesMissingStashedAsEmpty() throws {
        // A status file written by a pre-scratchpad server (no `stashed`
        // key) must decode to [] rather than throw, so `facet query`
        // survives an in-place upgrade until the next reconcile.
        let json = Data("""
        {"backend":"native","theme":"terminal","workspaces":[],"timestamp":"ts"}
        """.utf8)
        let snap = try JSONDecoder().decode(StatusSnapshot.self, from: json)
        #expect(snap.stashed == [])
        #expect(snap.lastError == nil)
    }

    @Test func renderShowsStashedLineOnlyWhenNonEmpty() {
        let withShelf = StatusSnapshot(
            backend: "native", theme: "terminal",
            workspaces: [], stashed: ["editor", "notes"],
            lastError: nil, timestamp: "ts")
        #expect(withShelf.render().contains("stashed: editor, notes"),
                "stashed line lists shelf names when non-empty")
        let none = StatusSnapshot(
            backend: "native", theme: "terminal",
            workspaces: [], stashed: [],
            lastError: nil, timestamp: "ts")
        #expect(!(none.render().contains("stashed:")),
                "no stashed line when there are no shelves")
    }

    @Test func renderSurfacesLastError() {
        let snap = StatusSnapshot(
            backend: "native",
            theme: "terminal",
            workspaces: [],
            lastError: "Window 7: AX permission failed",
            timestamp: "ts")
        #expect(snap.render().contains(
            "last error: Window 7: AX permission failed"))
    }

    // MARK: - Tag projection (#228; `facet query --tags`)

    @Test func snapshotRoundTripsTags() throws {
        let snap = StatusSnapshot(
            backend: "native", theme: "terminal",
            workspaces: [], stashed: [],
            tags: ["work", "web", "media"],
            lastError: nil, timestamp: "ts")
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(StatusSnapshot.self, from: data)
        #expect(back == snap)
        #expect(back.tags == ["work", "web", "media"])
    }

    @Test func snapshotDecodesMissingTags() throws {
        // A status file written by a pre-#228 server (no `tags` key) must
        // decode to [] rather than throw, so `facet query` survives an
        // in-place upgrade until the next reconcile.
        let json = Data("""
        {"backend":"native","theme":"terminal","workspaces":[],"timestamp":"ts"}
        """.utf8)
        let snap = try JSONDecoder().decode(StatusSnapshot.self, from: json)
        #expect(snap.tags == [])
    }

    // MARK: - Helpers

    private func tempPath() -> String {
        NSTemporaryDirectory()
            + "facet-status-test-\(UUID().uuidString).json"
    }
}
