// `facet query` data path.
//
// The server (Controller) keeps `/tmp/facet-status.json` in sync
// with its live state — written once at startup and again after
// every reconcile. The client (`facet query`) just reads the
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
    /// Surfaced by `facet query` as a "N sticky" suffix.
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
    // `facet query` fail until the next reconcile rewrites the file.
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

/// The current lens as `facet query --lens` reports it (#228, tag mode).
/// `tags` are the USER-tag names the lens reveals, declaration order
/// (the `_default` floor is never listed — it isn't a user tag).
/// `showsAll` is `true` when the lens reveals *every* window — the
/// floor-only startup/fallback lens or `lens --all` — which a machine
/// consumer can't otherwise tell from `tags == []` (a floor-only lens
/// and a lens of zero user tags both yield an empty `tags`, yet the
/// former shows everything). It is `false` for a lens of specific user
/// tags. Encoded inside `StatusSnapshot.lens`; the read verb prints it
/// as standalone JSON.
public struct LensStatus: Codable, Sendable, Equatable {
    public let tags: [String]
    public let showsAll: Bool

    public init(tags: [String], showsAll: Bool) {
        self.tags = tags
        self.showsAll = showsAll
    }

    /// Resolve the lens status from a raw lens mask + the tag
    /// vocabulary (pure — unit-testable without a backend). `showsAll`
    /// is true exactly when the lens carries the `_default` floor bit:
    /// every window carries that bit (it's the never-lost floor), so a
    /// floor-bearing lens matches them all. `tags` lists only the user
    /// bits set in the lens (the floor is excluded by `names(in:)`).
    public static func resolve(lens: UInt64, model: TagModel) -> LensStatus {
        LensStatus(tags: model.names(in: lens),
                   showsAll: (lens & TagModel.defaultBit) != 0)
    }
}

/// Everything `facet query` shows in one shot. Encoded as JSON
/// so the file is also greppable / inspectable by other tools.
public struct StatusSnapshot: Codable, Sendable, Equatable {
    public let backend: String           // e.g. "native"
    public let theme: String             // e.g. "terminal", "dracula"
    public let defaultView: String?      // "tree" / "grid" / nil = agent
    public let workspaces: [WorkspaceStatusEntry]
    /// Names of currently *stashed* scratchpad shelves — hidden,
    /// off-screen windows summonable with `facet scratchpad
    /// --toggle NAME`. A *settled* (summoned) scratchpad window
    /// instead appears in the tree under its workspace, so it's
    /// absent here. Mac-desktop-global (the shelf isn't per-WS), so it's a
    /// top-level field rather than a per-`WorkspaceStatusEntry` count.
    public let stashed: [String]
    /// The session tag VOCABULARY (`facet query --tags`, #228) — every
    /// defined tag name in declaration order. `[]` in workspace mode
    /// (no vocabulary) and the data source for `query --tags`, which a
    /// `query --windows` sweep can't supply (a defined-but-unused tag
    /// appears on no window).
    public let tags: [String]
    /// The current lens (`facet query --lens`, #228). `nil` outside tag
    /// mode — the lens is a tag-mode concept — which the read verb
    /// surfaces as JSON `null`.
    public let lens: LensStatus?
    public let lastError: String?        // nil = no error since startup
    public let timestamp: String         // ISO8601, for staleness check

    public init(backend: String,
                theme: String,
                defaultView: String?,
                workspaces: [WorkspaceStatusEntry],
                stashed: [String] = [],
                tags: [String] = [],
                lens: LensStatus? = nil,
                lastError: String?,
                timestamp: String) {
        self.backend = backend
        self.theme = theme
        self.defaultView = defaultView
        self.workspaces = workspaces
        self.stashed = stashed
        self.tags = tags
        self.lens = lens
        self.lastError = lastError
        self.timestamp = timestamp
    }

    // Tolerate a status file written before `stashed` / `tags` / `lens`
    // existed (a stale `/tmp/facet-status.json` lingering across an
    // in-place upgrade): a missing array key decodes to [], a missing
    // `lens` to nil. (`Encodable` stays synthesized.)
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decode(String.self, forKey: .backend)
        theme = try c.decode(String.self, forKey: .theme)
        defaultView = try c.decodeIfPresent(String.self, forKey: .defaultView)
        workspaces = try c.decode([WorkspaceStatusEntry].self,
                                  forKey: .workspaces)
        stashed = try c.decodeIfPresent([String].self, forKey: .stashed) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        lens = try c.decodeIfPresent(LensStatus.self, forKey: .lens)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        timestamp = try c.decode(String.self, forKey: .timestamp)
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
        if !stashed.isEmpty {
            lines.append("stashed: \(stashed.joined(separator: ", "))")
        }
        lines.append("last error: \(lastError ?? "(none)")")
        lines.append("timestamp: \(timestamp)")
        return lines.joined(separator: "\n")
    }
}
