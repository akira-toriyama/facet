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
    /// How to hide non-active-workspace windows on switch.
    /// See memory [[native-window-hide-methods]] for the choice rationale.
    public var hideMethod: String?          // "anchor" | "minimize"

    /// Raw `[workspace]` inline-mapping entries (e.g. `1 = "dev"`).
    /// Keys are 1-indexed integers matching what the user types
    /// into `facet --workspace=N`. Empty string values are
    /// permitted (= name-less slot, renders as "(N)" in status).
    /// Read through `effectiveWorkspaceNames` for clamped values.
    public var workspaceNames: [Int: String] = [:]

    /// External shell hooks invoked once at startup, after the
    /// backend has subscribed to events and the CLI DNC listener
    /// is live. Vitest-style: the user's "set things up the way I
    /// want them on launch" escape hatch, kept outside facet's
    /// own state (architecture.md Phase α frozen decisions).
    /// Each path is tilde / env-var expanded before spawn; see
    /// `effectiveSetupFiles`.
    public var setupFiles: [String]?

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
    public var effectiveHideMethod: String {
        let raw = (hideMethod ?? "anchor").lowercased()
        return ["anchor", "minimize"].contains(raw) ? raw : "anchor"
    }

    /// Facet workspace defaults when the user hasn't (yet) edited
    /// `[workspace]` at all. 5 is the memory-confirmed
    /// (`facet-workspace-model` N2) "control above zero, easy to
    /// expand" starting point.
    public static let defaultWorkspaceCount = 5

    /// Tilde + env-var expanded `setupFiles` paths, in declared
    /// order, with empty / whitespace-only entries dropped.
    /// `~` expands against `$HOME`; `$VAR` and `${VAR}` expand
    /// against the current environment (unset → empty string,
    /// which then trips the empty-path drop).
    public var effectiveSetupFiles: [String] {
        guard let raw = setupFiles else { return [] }
        return raw.compactMap { path in
            let expanded = expandPath(path)
                .trimmingCharacters(in: .whitespaces)
            return expanded.isEmpty ? nil : expanded
        }
    }

    /// Effective workspace list as `(index, name)` pairs, 1-indexed,
    /// sorted by index. Returns `defaultWorkspaceCount` empty-name
    /// slots when the user hasn't configured any.
    ///
    /// Negative / zero / duplicate keys are dropped (clamping;
    /// `facet-workspace-model` N2.2 = no upper bound). Adapters
    /// build their workspace state from this list.
    public var effectiveWorkspaceList: [(index: Int, name: String)] {
        let valid = workspaceNames
            .filter { $0.key >= 1 }
        if valid.isEmpty {
            return (1...Self.defaultWorkspaceCount).map {
                ($0, "")
            }
        }
        return valid
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
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
        if case .stringArray(let xs)? = toml["workspace"]?["setupFiles"] {
            c.setupFiles = xs
        }
        // [workspace] inline mapping (e.g. `1 = "dev"`). Any int
        // key inside the section that isn't a known meta-field
        // (`hide_method` etc.) is treated as a workspace name slot.
        if let section = toml["workspace"] {
            for (key, value) in section {
                guard let idx = Int(key),
                      case .string(let name) = value
                else { continue }
                c.workspaceNames[idx] = name
            }
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

/// Expand `~` against `$HOME` and `$VAR` / `${VAR}` against the
/// current process environment. Public for unit-testability; the
/// only caller is `FacetConfig.effectiveSetupFiles`.
public func expandPath(_ path: String) -> String {
    let env = ProcessInfo.processInfo.environment
    var s = path
    // `~` only at the start (paths like `/foo/~bar` are kept
    // literal — matches sh expansion).
    if s == "~" || s.hasPrefix("~/") {
        let home = env["HOME"] ?? NSHomeDirectory()
        s = s == "~" ? home : home + String(s.dropFirst())
    }
    // Single pass over `$VAR` / `${VAR}`. Naive but matches the
    // parser's "subset, not full sh" stance — escaping (`\$`) or
    // nested expansion isn't supported.
    var out = ""
    var i = s.startIndex
    while i < s.endIndex {
        if s[i] == "$", let next = s.index(i, offsetBy: 1,
                                           limitedBy: s.endIndex),
           next < s.endIndex {
            let braced = s[next] == "{"
            let nameStart = braced ? s.index(after: next) : next
            var nameEnd = nameStart
            while nameEnd < s.endIndex {
                let ch = s[nameEnd]
                if braced ? (ch == "}") :
                            !(ch.isLetter || ch.isNumber || ch == "_") {
                    break
                }
                nameEnd = s.index(after: nameEnd)
            }
            let name = String(s[nameStart..<nameEnd])
            if !name.isEmpty {
                out.append(env[name] ?? "")
                i = braced && nameEnd < s.endIndex
                    ? s.index(after: nameEnd) : nameEnd
                continue
            }
        }
        out.append(s[i])
        i = s.index(after: i)
    }
    return out
}
