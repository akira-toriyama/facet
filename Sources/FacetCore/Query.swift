// `facet query --windows` data path (#223).
//
// A flat, machine-readable JSON array of EVERY window the window
// server reports — across every mac desktop, including unvisited /
// unmanaged ones (yabai `-m query` shape). Top-level keys are the raw
// window-server properties; the nested `facet` block is facet's
// management state, or `null` when facet doesn't manage the window.
// Filtering is left to `jq` (Rule of Composition):
//
//     facet query --windows | jq '.[] | select(.facet.tags[]? == "190")'
//
// Same post-and-exit file IPC as `facet query` (the status snapshot,
// `Status.swift`): the server writes `/tmp/facet-query.json` atomically
// on reconcile + startup; the client reads it and prints. The on-disk
// form is the bare array itself, so the file is directly `jq`-able.

import Foundation

/// One window in the `facet query --windows` output. Property names are
/// the JSON keys (so the synthesized `CodingKeys` produce the documented
/// schema). Nullable fields encode an explicit `null` (the `facet` block
/// being `null` is the "facet-unmanaged" sentinel).
public struct WindowQueryEntry: Codable, Sendable, Equatable {
    public let id: Int          // WindowID.serverID (CGS window id)
    public let pid: Int
    public let app: String      // owning app name
    public let title: String    // AX-resolved (on-screen); "" if unknown
    public let bundleId: String?
    /// mac desktop ordinal (1-based, Mission-Control order). `nil` when
    /// SkyLight is unavailable or the window's desktop can't be resolved.
    public let desktop: Int?
    public let frame: Frame?    // CGWindowList bounds (real, not would-be)
    public let onscreen: Bool
    public let focused: Bool
    /// facet's management state, or `nil` (encoded `null`) when the
    /// window isn't in any facet catalog (unmanaged / excluded / on an
    /// unvisited desktop).
    public let facet: FacetWindowState?

    public struct Frame: Codable, Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let w: Int
        public let h: Int
        public init(x: Int, y: Int, w: Int, h: Int) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }
    }

    public struct FacetWindowState: Codable, Sendable, Equatable {
        public let workspace: String      // slot's workspace name ("" = unnamed)
        public let workspaceIndex: Int    // 1-based
        public let tags: [String]         // tag names (floor excluded)
        public let floating: Bool
        public let sticky: Bool
        public let master: Bool
        /// ISOLATE-PARKED: anchor-parked off-screen because the window falls
        /// OUTSIDE the `match` on a `[desktop.N] type=lens` mac desktop.
        ///
        /// This is the ONLY surface that reports it, and it has to exist: a
        /// lens desktop MOVES REAL WINDOWS, and with `show-non-matching =
        /// false` a parked window appears on NO facet surface at all — not the
        /// tree, not an overview. Without this key, facet moves a window
        /// somewhere the user can't see and then can't tell them where it went
        /// (the only other way to find it is the geometric corner-sliver
        /// heuristic in `AXRescue.rescueCornerParked`). facet is CLI-first, so
        /// the CLI has to be able to answer "what did you park?".
        ///
        /// Not to be confused with a Cmd+H hide (`onscreen == false`): a parked
        /// window keeps `onscreen == true` — it sits on a 1×41 on-screen sliver.
        public let parked: Bool
        public let mark: String?
        public let scratchpad: String?    // settled shelf name; nil otherwise

        public init(workspace: String, workspaceIndex: Int, tags: [String],
                    floating: Bool, sticky: Bool, master: Bool, parked: Bool,
                    mark: String?, scratchpad: String?) {
            self.workspace = workspace
            self.workspaceIndex = workspaceIndex
            self.tags = tags
            self.floating = floating
            self.sticky = sticky
            self.master = master
            self.parked = parked
            self.mark = mark
            self.scratchpad = scratchpad
        }

        // Explicit `null` for mark / scratchpad (don't omit the key).
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(workspace, forKey: .workspace)
            try c.encode(workspaceIndex, forKey: .workspaceIndex)
            try c.encode(tags, forKey: .tags)
            try c.encode(floating, forKey: .floating)
            try c.encode(sticky, forKey: .sticky)
            try c.encode(master, forKey: .master)
            try c.encode(parked, forKey: .parked)
            try encodeOptional(&c, mark, forKey: .mark)
            try encodeOptional(&c, scratchpad, forKey: .scratchpad)
        }
    }

    public init(id: Int, pid: Int, app: String, title: String,
                bundleId: String?, desktop: Int?, frame: Frame?,
                onscreen: Bool, focused: Bool, facet: FacetWindowState?) {
        self.id = id; self.pid = pid; self.app = app; self.title = title
        self.bundleId = bundleId; self.desktop = desktop; self.frame = frame
        self.onscreen = onscreen; self.focused = focused; self.facet = facet
    }

    // Explicit `null` for the nullable top-level keys (don't omit them),
    // so the on-disk schema matches the documented contract and
    // `.facet == null` reliably signals an unmanaged window.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pid, forKey: .pid)
        try c.encode(app, forKey: .app)
        try c.encode(title, forKey: .title)
        try encodeOptional(&c, bundleId, forKey: .bundleId)
        try encodeOptional(&c, desktop, forKey: .desktop)
        try encodeOptional(&c, frame, forKey: .frame)
        try c.encode(onscreen, forKey: .onscreen)
        try c.encode(focused, forKey: .focused)
        try encodeOptional(&c, facet, forKey: .facet)
    }
}

/// `facet filter` field resolution for a query entry (#283 PR#2).
///
/// `WindowQueryEntry` is the COMPLETE window-centric record — top-level
/// window-server fields PLUS the nested `facet` management block — so it,
/// not the partial `FacetWindowState`, is the conformer.
///
/// FROZEN unmanaged-window rule: when `facet == nil` (the window isn't in
/// any catalog), the management fields default to `workspace=""`,
/// `tags=[]`, `floating=true`, everything else `false`/`nil`. So
/// `not tag` MATCHES an unmanaged window while tag-presence does NOT, and
/// an unmanaged window reads as floating (facet doesn't tile it).
extension WindowQueryEntry: WindowFields {
    public func filterValue(_ field: String) -> String? {
        switch field {
        case "app": return app
        case "title": return title
        case "bundleId": return bundleId
        case "desktop": return desktop.map(String.init)
        case "onscreen": return onscreen ? "true" : "false"
        case "focused": return focused ? "true" : "false"
        case "workspace": return facet?.workspace ?? ""
        case "tag":
            let tags = facet?.tags ?? []
            return tags.isEmpty ? nil : tags.joined(separator: " ")
        case "mark": return facet?.mark
        case "scratchpad": return facet?.scratchpad
        case "floating": return (facet?.floating ?? true) ? "true" : "false"
        case "sticky": return (facet?.sticky ?? false) ? "true" : "false"
        case "master": return (facet?.master ?? false) ? "true" : "false"
        default: return nil
        }
    }

    public func filterHas(_ field: String) -> Bool {
        switch field {
        case "tag": return !(facet?.tags ?? []).isEmpty
        case "floating": return facet?.floating ?? true
        case "sticky": return facet?.sticky ?? false
        case "master": return facet?.master ?? false
        case "focused": return focused
        case "onscreen": return onscreen
        case "mark": return facet?.mark != nil
        case "scratchpad": return facet?.scratchpad != nil
        case "app": return !app.isEmpty
        case "title": return !title.isEmpty
        case "bundleId": return !(bundleId ?? "").isEmpty
        case "workspace": return !(facet?.workspace ?? "").isEmpty
        case "desktop": return desktop != nil
        default: return false
        }
    }
}

/// Encode an optional as an explicit `null` (rather than omitting the
/// key, which `encodeIfPresent` / the synthesized encoder would do).
private func encodeOptional<K: CodingKey, V: Encodable>(
    _ c: inout KeyedEncodingContainer<K>, _ value: V?, forKey key: K
) throws {
    if let value { try c.encode(value, forKey: key) }
    else { try c.encodeNil(forKey: key) }
}

/// On-disk read/write for the window-query payload. The file is the bare
/// `[WindowQueryEntry]` array (directly `jq`-able), written atomically
/// via mktemp + rename — same idiom as `StatusSnapshot.write`.
public enum WindowQuery {
    public static let defaultPath = "/tmp/facet-query.json"

    public static func write(_ entries: [WindowQueryEntry],
                             to path: String = defaultPath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: [])
        try FileManager.default.replaceItemAt(
            URL(fileURLWithPath: path),
            withItemAt: URL(fileURLWithPath: tmp))
    }

    public static func read(from path: String = defaultPath)
        throws -> [WindowQueryEntry]
    {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode([WindowQueryEntry].self, from: data)
    }
}
