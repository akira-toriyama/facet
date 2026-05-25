// User-facing config (`~/.config/facet/config.toml`). The app
// READS only — never writes — so the file (or its absence) is the
// single source of truth. Repo ships ``config.toml`` at its root
// with defaults + comments; README instructs users to ``curl`` it
// into `~/.config/facet/`. If the file is absent, ``effective*``
// accessors below supply built-in defaults (agent-only mode, no
// panel).
//
// All public fields are *raw* (Optional, as parsed from TOML).
// `effective*` accessors apply defaults + clamping; consumers
// should always read through those so a typo can never break the
// UI.

import CoreGraphics
import Foundation

public struct FacetConfig: Sendable {
    // Top-level
    public var defaultView: String?         // "tree" | "grid"
    public var theme: String?               // "terminal" | "cute" | "system"

    // [grid]
    public var gridCols: Int?
    public var gridLabelPosition: String?   // "up" | "down"
    public var gridLabelSize: Int?
    public var thumbnailRefreshSeconds: Int?

    // [workspace]
    /// How to hide non-active-workspace windows on switch. Enum is
    /// extensible (memory [[native-window-hide-methods]] / [[facet-sip-off-core-plan]]).
    /// Phase α implements "anchor" + "minimize"; future values
    /// ("deep-tag" etc.) come with `facet-x` (deep-core, M6+).
    public var hideMethod: String?          // "anchor" | "minimize"

    public init() {}

    // MARK: - Effective accessors (defaults + clamping)

    /// Returns the configured view name if valid, else `nil`
    /// (= agent-only mode). Unknown names treated as missing.
    public var effectiveDefaultView: String? {
        guard let raw = defaultView?.lowercased() else { return nil }
        return ["tree", "grid"].contains(raw) ? raw : nil
    }

    /// Falls back to `"terminal"` for unset or unrecognised values.
    public var effectiveTheme: String {
        let raw = (theme ?? "terminal").lowercased()
        return ["terminal", "cute", "system"].contains(raw)
            ? raw : "terminal"
    }

    /// 1-12 clamp. Default 4.
    public var effectiveGridCols: Int {
        max(1, min(12, gridCols ?? 4))
    }

    /// "up" | "down". Any other input → "up". Case-insensitive.
    public var effectiveGridLabelPosition: String {
        (gridLabelPosition?.lowercased() == "down") ? "down" : "up"
    }

    /// 8-32 pt clamp. Default 15.
    public var effectiveGridLabelSize: CGFloat {
        CGFloat(max(8, min(32, gridLabelSize ?? 15)))
    }

    /// Pre-computed once for the grid view's layout math.
    public var effectiveGridLabelBandHeight: CGFloat {
        effectiveGridLabelSize + 7
    }

    /// Effective background-capture interval for grid thumbnails.
    /// `nil` → background capture disabled (cells show icon
    /// fallback until on-demand captures land). Default 4 s,
    /// clamped to [1, 60] when set.
    public var effectiveThumbnailRefreshInterval: TimeInterval? {
        let raw = thumbnailRefreshSeconds ?? 4
        if raw <= 0 { return nil }
        return TimeInterval(max(1, min(60, raw)))
    }

    /// `"anchor"` (default) — instant 1×41 px corner park.
    /// `"minimize"` — AX `kAXMinimized`, Dock genie animation.
    /// Unknown / unset → `"anchor"`. Case-insensitive.
    /// Frozen Phase α option set; extending the enum is a deep-core
    /// (`facet-x`, M6+) concern.
    public var effectiveHideMethod: String {
        let raw = (hideMethod ?? "anchor").lowercased()
        return ["anchor", "minimize"].contains(raw) ? raw : "anchor"
    }

    // MARK: - Construction from parsed TOML

    public static func from(toml: [String: [String: TOMLValue]])
        -> FacetConfig
    {
        var c = FacetConfig()
        // Top-level
        if case .string(let s)? = toml[""]?["default_view"] {
            c.defaultView = s
        }
        if case .string(let s)? = toml[""]?["theme"] {
            c.theme = s
        }
        // [grid]
        if case .int(let n)? = toml["grid"]?["cols"] { c.gridCols = n }
        if case .string(let s)? = toml["grid"]?["label-position"] {
            c.gridLabelPosition = s
        }
        if case .int(let n)? = toml["grid"]?["label-size"] {
            c.gridLabelSize = n
        }
        if case .int(let n)? = toml["grid"]?["thumbnail-refresh-seconds"] {
            c.thumbnailRefreshSeconds = n
        }
        // [workspace]
        if case .string(let s)? = toml["workspace"]?["hide_method"] {
            c.hideMethod = s
        }
        return c
    }

    // MARK: - Disk

    public static var defaultPath: String {
        let h = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return "\(h)/.config/facet/config.toml"
    }

    /// Read config from `path`. Returns default-init'd config if
    /// the file is missing or unreadable — the controller then
    /// enters agent-only mode (no panel) since
    /// ``effectiveDefaultView == nil``. Read-only by design: the
    /// app never writes to the user's config file. Repo root
    /// `config.toml` is the install template; users `curl` it
    /// into place themselves (see README).
    public static func load(path: String = defaultPath) -> FacetConfig {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .init() }
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            return .from(toml: parseTOMLSubset(text))
        }
        FileHandle.standardError.write(Data(
            "facet: could not read \(path)\n".utf8))
        return .init()
    }
}
