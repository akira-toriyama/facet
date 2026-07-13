import Foundation
import Testing
@testable import FacetCore

/// `WindowQueryEntry` / `WindowQuery` — the `facet query --windows`
/// JSON payload (#223). Verifies the schema (key names), explicit-null
/// encoding of the nullable fields, and round-trip stability.
struct QueryTests {

    private func encoded(_ entries: [WindowQueryEntry]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try enc.encode(entries), encoding: .utf8)!
    }

    @Test func managedEntryRoundTrips() throws {
        let entry = WindowQueryEntry(
            id: 12345, pid: 678, app: "Safari", title: "Example — Safari",
            bundleId: "com.apple.Safari", desktop: 2,
            frame: .init(x: 0, y: 0, w: 1280, h: 800),
            onscreen: true, focused: false,
            facet: .init(workspace: "web", workspaceIndex: 1, tags: ["190"],
                         floating: false, sticky: false, master: true,
                         parked: true,
                         mark: "a", scratchpad: nil))
        let json = try encoded([entry])
        // Schema key names present. `parked` (t-pvay) is the CLI's only view of
        // a window an isolate desktop anchor-parked — keep it in the contract.
        for key in ["\"id\"", "\"pid\"", "\"app\"", "\"title\"",
                    "\"bundleId\"", "\"desktop\"", "\"frame\"", "\"onscreen\"",
                    "\"focused\"", "\"facet\"", "\"workspaceIndex\"",
                    "\"tags\"", "\"master\"", "\"parked\""] {
            #expect(json.contains(key), "missing key \(key)")
        }
        #expect(json.contains("\"parked\" : true"))
        // Round-trip.
        let back = try JSONDecoder().decode([WindowQueryEntry].self,
                                            from: Data(json.utf8))
        #expect(back == [entry])
    }

    @Test func unmanagedEntryEncodesExplicitNulls() throws {
        // An unmanaged window: facet == nil, plus nil bundleId/desktop/frame.
        let entry = WindowQueryEntry(
            id: 999, pid: 42, app: "Notes", title: "",
            bundleId: nil, desktop: nil, frame: nil,
            onscreen: false, focused: false, facet: nil)
        let json = try encoded([entry])
        // Nullable keys are PRESENT as explicit null (not omitted), so
        // `.facet == null` reliably signals "facet-unmanaged".
        #expect(json.contains("\"facet\" : null"), "\(json)")
        #expect(json.contains("\"bundleId\" : null"))
        #expect(json.contains("\"desktop\" : null"))
        #expect(json.contains("\"frame\" : null"))
        // Round-trips back to the same nil-bearing value.
        let back = try JSONDecoder().decode([WindowQueryEntry].self,
                                            from: Data(json.utf8))
        #expect(back == [entry])
        #expect(back[0].facet == nil)
    }

    @Test func facetStateNullMarkAndScratchpadAreExplicit() throws {
        let entry = WindowQueryEntry(
            id: 1, pid: 1, app: "x", title: "", bundleId: nil, desktop: 1,
            frame: nil, onscreen: true, focused: true,
            facet: .init(workspace: "", workspaceIndex: 3, tags: [],
                         floating: true, sticky: false, master: false,
                         parked: false,
                         mark: nil, scratchpad: nil))
        let json = try encoded([entry])
        #expect(json.contains("\"mark\" : null"))
        #expect(json.contains("\"scratchpad\" : null"))
        #expect(json.contains("\"tags\" : ["))   // empty array, not null
    }

    @Test func writeReadRoundTrip() throws {
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
                                          parked: false,
                                          mark: nil, scratchpad: "term")),
        ]
        let path = NSTemporaryDirectory() + "facet-query-test-\(getpid()).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try WindowQuery.write(entries, to: path)
        let back = try WindowQuery.read(from: path)
        #expect(back == entries)
    }
}
