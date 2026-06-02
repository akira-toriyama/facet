// `facet status` data path.
//
// The server (Controller) keeps `/tmp/facet-status.json` in sync
// with its live state — written once at startup and again after
// every reconcile. The client (`facet status`) just reads the
// file, decodes the JSON, and renders the human-readable summary.
//
// Why a file instead of DNC round-trip: facet's existing IPC is
// post-and-exit DistributedNotificationCenter, which has no reply
// channel. A file is the cheapest reliable "ask the server what
// it thinks" mechanism — atomic write on the server side, plain
// read on the client side, zero race when the writer renames a
// fully-formed temp file into place.

import Foundation

/// A single workspace as it appears in the snapshot. `index` is
/// 1-indexed (= what the user sees in CLI / panels), not the
/// 0-indexed value the backend protocol uses.
public struct WorkspaceStatusEntry: Codable, Sendable, Equatable {
    public let index: Int
    public let name: String
    public let active: Bool
    public let windowCount: Int
    /// How many of `windowCount` are sticky (pinned across every WS).
    /// Surfaced by `facet status` as a "N sticky" suffix.
    public let stickyCount: Int

    public init(index: Int, name: String,
                active: Bool, windowCount: Int,
                stickyCount: Int = 0) {
        self.index = index
        self.name = name
        self.active = active
        self.windowCount = windowCount
        self.stickyCount = stickyCount
    }

    // Tolerate a status file written before `stickyCount` existed: a
    // stale `/tmp/facet-status.json` from an old server lingering across
    // an in-place upgrade would otherwise throw `keyNotFound` and make
    // `facet status` fail until the next reconcile rewrites the file.
    // A missing key decodes to 0. (`Encodable` stays synthesized.)
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        name = try c.decode(String.self, forKey: .name)
        active = try c.decode(Bool.self, forKey: .active)
        windowCount = try c.decode(Int.self, forKey: .windowCount)
        stickyCount = try c.decodeIfPresent(Int.self, forKey: .stickyCount) ?? 0
    }
}

/// Everything `facet status` shows in one shot. Encoded as JSON
/// so the file is also greppable / inspectable by other tools.
public struct StatusSnapshot: Codable, Sendable, Equatable {
    public let backend: String           // e.g. "rift", "native"
    public let theme: String             // e.g. "terminal", "cute"
    public let defaultView: String?      // "tree" / "grid" / nil = agent
    public let workspaces: [WorkspaceStatusEntry]
    public let lastError: String?        // nil = no error since startup
    public let timestamp: String         // ISO8601, for staleness check

    public init(backend: String,
                theme: String,
                defaultView: String?,
                workspaces: [WorkspaceStatusEntry],
                lastError: String?,
                timestamp: String) {
        self.backend = backend
        self.theme = theme
        self.defaultView = defaultView
        self.workspaces = workspaces
        self.lastError = lastError
        self.timestamp = timestamp
    }

    /// Canonical on-disk location. Same `/tmp` neighbourhood as
    /// `Log.path` (volatile, reboot-cleaned).
    public static let defaultPath = "/tmp/facet-status.json"

    // MARK: - I/O

    /// JSON-encode and atomically replace the file at `path`.
    /// Atomicity matters: a client racing the writer never sees a
    /// half-written file. `mktemp` + rename is the standard
    /// POSIX idiom.
    public func write(to path: String = defaultPath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: [])
        try FileManager.default.replaceItemAt(
            URL(fileURLWithPath: path),
            withItemAt: URL(fileURLWithPath: tmp))
    }

    /// Decode the snapshot from disk. Throws on missing file
    /// (caller surfaces that as "server not running / no status
    /// yet") or malformed JSON (caller surfaces that as
    /// "status file corrupt — restart facet").
    public static func read(from path: String = defaultPath)
        throws -> StatusSnapshot
    {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(StatusSnapshot.self, from: data)
    }

    // MARK: - Rendering

    /// Human-readable, grep-friendly multi-line format. Stable
    /// enough that downstream `grep '^backend:'` keeps working.
    public func render() -> String {
        var lines: [String] = []
        lines.append("backend: \(backend)")
        lines.append("theme: \(theme)")
        lines.append("default-view: \(defaultView ?? "(agent)")")
        lines.append("workspaces:")
        if workspaces.isEmpty {
            lines.append("  (none)")
        } else {
            // Column widths picked so 1-9 line up against 10-15 etc.
            let idxWidth = String(workspaces.map(\.index).max() ?? 1).count
            let nameWidth = max(
                workspaces.map { $0.name.isEmpty ? 0 : $0.name.count + 2 }
                    .max() ?? 0,
                3)
            for w in workspaces {
                let idx = String(w.index).padding(
                    toLength: idxWidth, withPad: " ", startingAt: 0)
                let nameQuoted = w.name.isEmpty ? "" : "\"\(w.name)\""
                let namePadded = nameQuoted.padding(
                    toLength: nameWidth, withPad: " ", startingAt: 0)
                let activeMark = w.active ? "[active]" : "        "
                let count = "\(w.windowCount) window"
                    + (w.windowCount == 1 ? "" : "s")
                let sticky = w.stickyCount > 0
                    ? ", \(w.stickyCount) sticky" : ""
                lines.append(
                    "  \(idx) \(namePadded) \(activeMark)  \(count)\(sticky)")
            }
        }
        lines.append("last error: \(lastError ?? "(none)")")
        lines.append("timestamp: \(timestamp)")
        return lines.joined(separator: "\n")
    }
}
