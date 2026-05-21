// User-facing config (`~/.config/facet/config.toml`). On first
// install (no config file), `load()` writes `config.toml.example`
// alongside and returns a default-init'd config — the Controller
// then runs in agent-only mode (no panel) until the user copies
// the example to `config.toml` and sets `default_view`.
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
        return c
    }

    // MARK: - Disk

    public static var defaultPath: String {
        let h = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return "\(h)/.config/facet/config.toml"
    }

    public static var examplePath: String { defaultPath + ".example" }

    /// Read config from `path`. Returns default-init'd config if the
    /// file is missing or unreadable. Side-effect: on missing
    /// config (and missing example), writes the example template
    /// alongside so first-run users have something to copy + edit.
    public static func load(path: String = defaultPath) -> FacetConfig {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                return .from(toml: parseTOMLSubset(text))
            }
            FileHandle.standardError.write(Data(
                "facet: could not read \(path)\n".utf8))
            return .init()
        }
        // No config file. Drop an example next to it (idempotent)
        // and return defaults — Controller will enter agent-only
        // mode since `effectiveDefaultView == nil`.
        writeExampleIfMissing()
        return .init()
    }

    /// Idempotent: writes `config.toml.example` only when neither
    /// `config.toml` nor `config.toml.example` already exists.
    /// Creates the parent directory as needed.
    public static func writeExampleIfMissing(
        configPath: String = defaultPath,
        examplePath examplePathOverride: String? = nil
    ) {
        let configURL = URL(fileURLWithPath: configPath)
        let exURL = URL(fileURLWithPath:
            examplePathOverride ?? (configPath + ".example"))
        let fm = FileManager.default
        if fm.fileExists(atPath: configURL.path) { return }
        if fm.fileExists(atPath: exURL.path) { return }
        try? fm.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? exampleTemplate.write(
            to: exURL, atomically: true, encoding: .utf8)
    }

    /// The example file's contents. Public so docs / installer
    /// scripts can re-use it.
    public static let exampleTemplate = """
        # facet config — copy to config.toml and edit.
        # https://github.com/akira-toriyama/facet

        # Show this view on startup. Omit (or comment out) to start
        # in agent-only mode — facet stays running but draws no panel
        # until the CLI asks (`facet --view=tree`).
        #
        #   "tree"  — translucent sidebar list of workspaces + windows
        #   "grid"  — full-screen TS3-style overview
        #
        # default_view = "tree"

        # Color / typography preset. "terminal" (default), "cute", or
        # "system" (native vibrancy + dynamic colors).
        #
        # theme = "terminal"

        [grid]
        # Number of columns. Clamped 1-12. Default 4.
        cols = 4

        # Workspace label position relative to its cell. "up" (default,
        # Mission Control / TS3) or "down" (Stage Manager / dock).
        label-position = "up"

        # Workspace label font size (pt). Clamped 8-32. Default 15.
        label-size = 15

        # Background ScreenCaptureKit refresh cadence (seconds) for
        # grid thumbnails. 0 disables background capture entirely
        # (cells show app-icon fallback until on-demand captures
        # land). Clamped 1-60 otherwise. Default 4.
        thumbnail-refresh-seconds = 4
        """
}
