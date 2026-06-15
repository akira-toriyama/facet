import XCTest
@testable import FacetCore

/// `WindowQueryEntry` / `WindowQuery` — the `facet query --windows`
/// JSON payload (#223). Verifies the schema (key names), explicit-null
/// encoding of the nullable fields, and round-trip stability.
final class QueryTests: XCTestCase {

    private func encoded(_ entries: [WindowQueryEntry]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try enc.encode(entries), encoding: .utf8)!
    }

    func testManagedEntryRoundTrips() throws {
        let entry = WindowQueryEntry(
            id: 12345, pid: 678, app: "Safari", title: "Example — Safari",
            bundleId: "com.apple.Safari", desktop: 2,
            frame: .init(x: 0, y: 0, w: 1280, h: 800),
            onscreen: true, focused: false,
            facet: .init(workspace: "web", workspaceIndex: 1, tags: ["190"],
                         floating: false, sticky: false, master: true,
                         mark: "a", scratchpad: nil))
        let json = try encoded([entry])
        // Schema key names present.
        for key in ["\"id\"", "\"pid\"", "\"app\"", "\"title\"",
                    "\"bundleId\"", "\"desktop\"", "\"frame\"", "\"onscreen\"",
                    "\"focused\"", "\"facet\"", "\"workspaceIndex\"",
                    "\"tags\"", "\"master\""] {
            XCTAssertTrue(json.contains(key), "missing key \(key)")
        }
        // Round-trip.
        let back = try JSONDecoder().decode([WindowQueryEntry].self,
                                            from: Data(json.utf8))
        XCTAssertEqual(back, [entry])
    }

    func testUnmanagedEntryEncodesExplicitNulls() throws {
        // An unmanaged window: facet == nil, plus nil bundleId/desktop/frame.
        let entry = WindowQueryEntry(
            id: 999, pid: 42, app: "Notes", title: "",
            bundleId: nil, desktop: nil, frame: nil,
            onscreen: false, focused: false, facet: nil)
        let json = try encoded([entry])
        // Nullable keys are PRESENT as explicit null (not omitted), so
        // `.facet == null` reliably signals "facet-unmanaged".
        XCTAssertTrue(json.contains("\"facet\" : null"), json)
        XCTAssertTrue(json.contains("\"bundleId\" : null"))
        XCTAssertTrue(json.contains("\"desktop\" : null"))
        XCTAssertTrue(json.contains("\"frame\" : null"))
        // Round-trips back to the same nil-bearing value.
        let back = try JSONDecoder().decode([WindowQueryEntry].self,
                                            from: Data(json.utf8))
        XCTAssertEqual(back, [entry])
        XCTAssertNil(back[0].facet)
    }

    func testFacetStateNullMarkAndScratchpadAreExplicit() throws {
        let entry = WindowQueryEntry(
            id: 1, pid: 1, app: "x", title: "", bundleId: nil, desktop: 1,
            frame: nil, onscreen: true, focused: true,
            facet: .init(workspace: "", workspaceIndex: 3, tags: [],
                         floating: true, sticky: false, master: false,
                         mark: nil, scratchpad: nil))
        let json = try encoded([entry])
        XCTAssertTrue(json.contains("\"mark\" : null"))
        XCTAssertTrue(json.contains("\"scratchpad\" : null"))
        XCTAssertTrue(json.contains("\"tags\" : ["))   // empty array, not null
    }

    func testWriteReadRoundTrip() throws {
        let entries = [
            WindowQueryEntry(id: 2, pid: 1, app: "B", title: "b",
                             bundleId: nil, desktop: 1, frame: nil,
                             onscreen: true, focused: false, facet: nil),
            WindowQueryEntry(id: 1, pid: 1, app: "A", title: "a",
                             bundleId: "com.a", desktop: 1,
                             frame: .init(x: 1, y: 2, w: 3, h: 4),
                             onscreen: true, focused: true,
                             facet: .init(workspace: "main", workspaceIndex: 1,
                                          tags: ["x", "y"], floating: false,
                                          sticky: true, master: false,
                                          mark: nil, scratchpad: "term")),
        ]
        let path = NSTemporaryDirectory() + "facet-query-test-\(getpid()).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try WindowQuery.write(entries, to: path)
        let back = try WindowQuery.read(from: path)
        XCTAssertEqual(back, entries)
    }
}
