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
    public var thumbnailRefreshSeconds: Int?

    // [tree]
    /// How the sidebar's hover-preview overlay is sized + placed.
    /// `"popover"` (default) keeps it next to the source row;
    /// `"mirror"` puts it at the window's own on-screen frame.
    public var treePreviewMode: String?     // "popover" | "mirror"

    // [layout]
    /// Startup layout mode every workspace begins in (`float` / `bsp`
    /// / `stack` / a registered engine name). Layout mode is otherwise
    /// session-only, so this is the seed each fresh launch (and each
    /// per-native-Space catalog) starts from. Raw; read
    /// `effectiveDefaultLayout`.
    public var defaultLayout: String?
    /// Gap between adjacent tiled windows, px (inner gap). Raw value;
    /// read `effectiveInnerGap`.
    public var innerGap: CGFloat?
    /// Outer gap: inset from the screen edges for the whole tiling
    /// area, px. `outerGap` is the all-edges default; the four
    /// per-edge values override it where set. Raw; read the
    /// `effectiveOuterGap*` accessors.
    public var outerGap: CGFloat?
    public var outerGapTop: CGFloat?
    public var outerGapBottom: CGFloat?
    public var outerGapLeft: CGFloat?
    public var outerGapRight: CGFloat?

    // [animation]
    /// Window-move animation (枠 E). When on, geometry transitions
    /// (Phase 1: workspace switch) slide via per-frame AX writes instead
    /// of jumping. Raw; read `effectiveAnimationsEnabled`.
    public var animationsEnabled: Bool?
    /// Slide duration in ms. Raw; read `effectiveAnimationDuration`.
    /// When unset, each curve uses its own natural default.
    public var animationDurationMs: Int?
    /// Easing curve: none / cubic / spring / silky / snappy / random.
    /// Raw; read `effectiveAnimationCurve`.
    public var animationCurve: String?

    // [workspace]
    /// Raw `[workspace]` inline-mapping entries (e.g. `1 = "dev"`).
    /// Keys are 1-indexed integers matching what the user types
    /// into `facet workspace --focus=N`. Empty string values are
    /// permitted (= name-less slot, renders as "(N)" in status).
    /// Read through `effectiveWorkspaceNames` for clamped values.
    public var workspaceNames: [Int: String] = [:]

    /// Per-native-Space `[space.N]` workspace names. Outer key is the
    /// native macOS Space ordinal (Mission Control order, 1-based,
    /// user Spaces only); inner is the same `facet WS index -> name`
    /// shape as `workspaceNames`. A native Space without a section
    /// falls back to the global `[workspace]` list. See memory
    /// `facet-per-native-space-ws`.
    public var spaceWorkspaceNames: [Int: [Int: String]] = [:]

    /// External shell hooks invoked once at startup, after the
    /// backend has subscribed to events and the CLI DNC listener
    /// is live. Vitest-style: the user's "set things up the way I
    /// want them on launch" escape hatch, kept outside facet's
    /// own state (architecture.md Phase α frozen decisions).
    /// Each path is tilde / env-var expanded before spawn; see
    /// `effectiveSetupFiles`.
    public var setupFiles: [String]?

    /// `[[exclude]]` rules — windows matching one are floated or
    /// ignored instead of tiled (unnamed popups, auxiliary panels).
    /// `nil` when the config specifies none. Parsed from the raw TOML
    /// text (array-of-tables), not the flattened `[section]` dict, so
    /// it's filled by `load`, not `from(toml:)`.
    public var exclusionRules: [ExclusionRule]?

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

    /// Effective background-capture interval for grid thumbnails.
    /// `nil` → background capture disabled (cells show icon
    /// fallback until on-demand captures land). Default 4 s,
    /// clamped to [1, 60] when set.
    public var effectiveThumbnailRefreshInterval: TimeInterval? {
        let raw = thumbnailRefreshSeconds ?? 4
        if raw <= 0 { return nil }
        return TimeInterval(max(1, min(60, raw)))
    }

    /// `"popover"` (default) — small thumbnail next to the source
    /// row, capped + auto-flipped to stay on-screen.
    /// `"mirror"` — full-size preview at the window's *would-be*
    /// on-screen frame (where it lands after switching to its WS),
    /// computed by the adapter's `wouldBeFrame` from the pre-park
    /// position / tile slot / full display — NOT the 1×41 parked
    /// sliver.
    /// Unknown / unset → `"popover"`. Case-insensitive.
    public var effectiveTreePreviewMode: String {
        let raw = (treePreviewMode ?? "popover").lowercased()
        return ["popover", "mirror"].contains(raw) ? raw : "popover"
    }

    /// Gap between adjacent tiled windows, px. [0, 1000] clamp,
    /// default 0 (= flush tiling, the pre-gap behaviour). Applied by
    /// `applyInnerGap` to every layout's frames; the screen-edge side
    /// of an outermost window is left flush (that distance is the
    /// outer gap, not this).
    public var effectiveInnerGap: CGFloat { max(0, min(1000,innerGap ?? 0)) }

    /// Startup layout mode for every workspace. Lowercased + clamped
    /// to a known mode (`float` / `bsp` / `stack` / a registered
    /// engine); an unknown / unset value falls back to `"float"`
    /// (the Phase γ frozen default — facet tiles nothing until asked).
    public var effectiveDefaultLayout: String {
        let m = (defaultLayout ?? "float").lowercased()
        let known = ["float", "bsp", "stack"] + LayoutRegistry.names
        return known.contains(m) ? m : "float"
    }

    /// Window-move animation on? Default on. False when explicitly
    /// disabled OR the curve is "none". Read this, not the raw fields.
    public var effectiveAnimationsEnabled: Bool {
        (animationsEnabled ?? true) && effectiveAnimationCurve != "none"
    }
    /// Slide duration (seconds), clamped 0.08–0.8 s. Default 0.28 s.
    public var effectiveAnimationDuration: TimeInterval {
        Double(min(800, max(80, animationDurationMs ?? 280))) / 1000
    }
    /// Animation curve: none / cubic / spring / silky / snappy / random.
    /// Unknown clamps to "cubic"; "random" picks per transition.
    public var effectiveAnimationCurve: String {
        let known = ["none", "cubic", "spring", "silky", "snappy", "random"]
        let c = (animationCurve ?? "cubic").lowercased()
        return known.contains(c) ? c : "cubic"
    }

    /// Per-edge outer gap, px: inset from that screen edge for the
    /// whole tiling area, applied before any layout runs (it shrinks
    /// the rect every layout tiles into — bsp / stack / stateless
    /// alike). Each edge falls back to `outerGap` (the all-edges
    /// default), then 0. [0, 1000] clamp. Edges are in screen
    /// orientation; the adapter maps them onto the tiling rect.
    public var effectiveOuterGapTop: CGFloat { clampedGap(outerGapTop ?? outerGap) }
    public var effectiveOuterGapBottom: CGFloat { clampedGap(outerGapBottom ?? outerGap) }
    public var effectiveOuterGapLeft: CGFloat { clampedGap(outerGapLeft ?? outerGap) }
    public var effectiveOuterGapRight: CGFloat { clampedGap(outerGapRight ?? outerGap) }

    private func clampedGap(_ v: CGFloat?) -> CGFloat { max(0, min(1000,v ?? 0)) }

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
        Self.sortedSlots(workspaceNames)
            ?? (1...Self.defaultWorkspaceCount).map { ($0, "") }
    }

    /// Workspace list for a given native-Space ordinal (1-based,
    /// Mission Control order). Returns the `[space.N]` config when
    /// that Space has a non-empty section, else the global
    /// `[workspace]` list. `nil` ordinal (SkyLight unavailable, or
    /// single-space mode) → global list.
    public func effectiveWorkspaceList(forSpaceOrdinal ordinal: Int?)
        -> [(index: Int, name: String)]
    {
        guard let ordinal,
              let names = spaceWorkspaceNames[ordinal],
              let list = Self.sortedSlots(names)
        else { return effectiveWorkspaceList }
        return list
    }

    /// Clamp + order a raw `index → name` map into `(index, name)`
    /// slots: drop keys < 1, sort ascending. `nil` when nothing
    /// valid remains (lets callers fall back). Shared by the global
    /// and per-Space workspace-list accessors.
    private static func sortedSlots(_ names: [Int: String])
        -> [(index: Int, name: String)]?
    {
        let valid = names.filter { $0.key >= 1 }
        guard !valid.isEmpty else { return nil }
        return valid.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Whether facet manages the native Space at `ordinal`.
    ///
    /// - With **any** `[space.N]` section present, facet is opt-in:
    ///   it manages ONLY the Spaces that have a section. A Space
    ///   without one is left untouched — no facet workspaces, no
    ///   window parking, and the panel hides there.
    /// - With **no** `[space.N]` sections at all, every native Space
    ///   is managed via the global `[workspace]` default (the
    ///   automatic per-Space behaviour).
    /// - `nil` ordinal (SkyLight unavailable / single-space mode) is
    ///   always managed.
    public func isSpaceManaged(ordinal: Int?) -> Bool {
        if spaceWorkspaceNames.isEmpty { return true }
        guard let ordinal else { return true }
        return spaceWorkspaceNames[ordinal] != nil
    }

    // MARK: - Construction from parsed TOML

    public static func from(toml: [String: [String: TOMLValue]])
        -> FacetConfig
    {
        var c = FacetConfig()
        // Top-level
        if case .string(let s)? = toml[""]?["default-view"] {
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
        if case .int(let n)? = toml["grid"]?["thumbnail-refresh-seconds"] {
            c.thumbnailRefreshSeconds = n
        }
        // [tree]
        if case .string(let s)? = toml["tree"]?["preview-mode"] {
            c.treePreviewMode = s
        }
        // [layout]
        if case .string(let s)? = toml["layout"]?["default"] {
            c.defaultLayout = s
        }
        if case .int(let n)? = toml["layout"]?["inner-gap"] {
            c.innerGap = CGFloat(n)
        }
        if case .int(let n)? = toml["layout"]?["outer-gap"] {
            c.outerGap = CGFloat(n)
        }
        if case .int(let n)? = toml["layout"]?["outer-gap-top"] {
            c.outerGapTop = CGFloat(n)
        }
        if case .int(let n)? = toml["layout"]?["outer-gap-bottom"] {
            c.outerGapBottom = CGFloat(n)
        }
        if case .int(let n)? = toml["layout"]?["outer-gap-left"] {
            c.outerGapLeft = CGFloat(n)
        }
        if case .int(let n)? = toml["layout"]?["outer-gap-right"] {
            c.outerGapRight = CGFloat(n)
        }
        // [animation]
        if case .bool(let b)? = toml["animation"]?["enabled"] {
            c.animationsEnabled = b
        }
        if case .int(let n)? = toml["animation"]?["duration-ms"] {
            c.animationDurationMs = n
        }
        if case .string(let s)? = toml["animation"]?["curve"] {
            c.animationCurve = s
        }
        // [workspace]
        if case .stringArray(let xs)? = toml["workspace"]?["setup-files"] {
            c.setupFiles = xs
        }
        // [workspace] inline mapping (e.g. `1 = "dev"`). Any int
        // key inside the section that isn't a known meta-field
        // (`setup-files` etc.) is treated as a workspace name slot.
        if let section = toml["workspace"] {
            for (key, value) in section {
                guard let idx = Int(key),
                      case .string(let name) = value
                else { continue }
                c.workspaceNames[idx] = name
            }
        }
        // [space.N] per-native-Space workspace names. The TOML
        // parser flattens `[space.1]` to the section name "space.1";
        // N is the native-Space ordinal (Mission Control order).
        // Inline int keys are WS-index → name, same as [workspace].
        for (sectionName, section) in toml
        where sectionName.hasPrefix("space.") {
            guard let ordinal = Int(sectionName.dropFirst("space.".count)),
                  ordinal >= 1 else { continue }
            var names: [Int: String] = [:]
            for (key, value) in section {
                guard let idx = Int(key), idx >= 1,
                      case .string(let name) = value else { continue }
                names[idx] = name
            }
            if !names.isEmpty { c.spaceWorkspaceNames[ordinal] = names }
        }
        return c
    }

    /// Effective `[[exclude]]` rule set (empty when none configured).
    /// Always read through this, never the raw Optional.
    public var effectiveExclusionRules: ExclusionRules {
        ExclusionRules(exclusionRules ?? [])
    }

    /// Build `[ExclusionRule]` from the raw TOML text's `[[exclude]]`
    /// array-of-tables. Each table: `app` / `title` / `role` /
    /// `subrole` are strings (regex for app/title, exact for
    /// role/subrole), `max_width` / `max_height` are ints, `action`
    /// is `"float"` (default) or `"ignore"`. A table with no match
    /// key is dropped (it would match nothing). Unknown/typo'd keys
    /// are ignored — a bad rule never breaks the others.
    public static func exclusionRules(fromTOML text: String)
        -> [ExclusionRule]
    {
        parseTOMLArrayOfTables(text, table: "exclude").compactMap { t in
            func str(_ k: String) -> String? {
                if case .string(let s)? = t[k] { return s }
                return nil
            }
            func dbl(_ k: String) -> Double? {
                if case .int(let n)? = t[k] { return Double(n) }
                return nil
            }
            let action: ExclusionAction = {
                if case .string(let s)? = t["action"],
                   let a = ExclusionAction(rawValue: s) { return a }
                return .float
            }()
            let rule = ExclusionRule(
                app: str("app"), title: str("title"),
                role: str("role"), subrole: str("subrole"),
                maxWidth: dbl("max_width"), maxHeight: dbl("max_height"),
                action: action)
            let hasKey = rule.app != nil || rule.title != nil
                || rule.role != nil || rule.subrole != nil
                || rule.maxWidth != nil || rule.maxHeight != nil
            return hasKey ? rule : nil
        }
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
            var c = FacetConfig.from(toml: parseTOMLSubset(text))
            let rules = exclusionRules(fromTOML: text)
            if !rules.isEmpty { c.exclusionRules = rules }
            return c
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
