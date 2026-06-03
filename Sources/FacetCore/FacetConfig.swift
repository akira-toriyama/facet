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

/// Per-WS configuration parsed from a `[desktop.N]` inline table:
/// `1 = { name = "Dev", layout = "bsp" }`. `name` is required;
/// `layout` is the optional seed for `facet workspace --layout`
/// (the runtime catalog can still override it for the session).
/// An unknown / mistyped layout falls back to the global
/// `[layout] default` at seed time.
public struct WorkspaceConfig: Sendable, Equatable {
    public let name: String
    public let layout: String?
    public init(name: String, layout: String? = nil) {
        self.name = name
        self.layout = layout
    }
}

public struct FacetConfig: Sendable {
    // Top-level
    public var defaultView: String?         // "tree" | "grid"
    public var theme: String?               // "terminal" | "cute" | "system"

    // [grid]
    public var gridCols: Int?
    public var gridLabelPosition: String?   // "up" | "down"
    public var thumbnailRefreshSeconds: Int?

    // [rail]
    public var railEdge: String?            // "top" | "bottom" | "left" | "right"
    public var railCells: Int?              // max strip cells shown at once
    public var railStrip: Int?              // strip band size, % of short screen edge

    // [tree]
    /// How the sidebar's hover-preview overlay is sized + placed.
    /// `"popover"` (default) keeps it next to the source row;
    /// `"mirror"` puts it at the window's own on-screen frame.
    public var treePreviewMode: String?     // "popover" | "mirror"

    // [layout]
    /// Startup layout mode every workspace begins in (`float` / `bsp`
    /// / `stack` / a registered engine name). Layout mode is otherwise
    /// session-only, so this is the seed each fresh launch (and each
    /// per-mac-desktop catalog) starts from. Raw; read
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
    /// Smart gaps: drop the outer gap when a workspace holds a single
    /// tiled window, so a lone window goes full-bleed (no screen-edge
    /// inset). Raw; read `effectiveSmartGaps`. Default off.
    public var smartGaps: Bool?

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
    /// Sub-toggle: animate event-driven retiles too (window open /
    /// close reflow). Defaults to ON when `animationsEnabled` is
    /// on; flip to false to keep WS-switch + user-triggered retile
    /// animated but snap on background opens / closes. Raw; read
    /// `effectiveAnimationEventDriven`.
    public var animationEventDriven: Bool?

    /// Per-mac-desktop `[desktop.N]` workspace configs. Outer key is
    /// the mac desktop ordinal (Mission Control order, 1-based, user
    /// desktops only); inner is `facet WS index -> WorkspaceConfig`
    /// (name + optional layout). A mac desktop without a section falls
    /// back to `defaultWorkspaceCount` unnamed slots with the global
    /// `[layout] default`. See memory `facet-per-native-space-ws`.
    public var macDesktopWorkspaceConfigs: [Int: [Int: WorkspaceConfig]] = [:]

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

    /// Which edge the rail docks against. Unknown / unset → `.bottom`
    /// (the original bottom bar). Case-insensitive. A CLI `--edge=`
    /// overrides this at show time.
    public var effectiveRailEdge: RailEdge {
        RailEdge(rawValue: (railEdge ?? "bottom").lowercased()) ?? .bottom
    }

    /// Upper bound on how many strip cells the carousel shows at once.
    /// The actual count auto-fits the strip's thumbnail size (a bigger
    /// `[rail] strip` shows fewer, larger cells), capped here. 1…20
    /// clamp, default 7 (mirrors `effectiveGridCols`' clamp shape).
    public var effectiveRailCells: Int {
        max(1, min(20, railCells ?? 7))
    }

    /// Maximum strip band size, as a percentage of the SHORT screen edge
    /// — the cap on the thumbnail scale; the hero fills the rest. The
    /// strip's thumbnails grow to fill the run (so the cells span the
    /// width / height with even, tight gaps) up to this cap; a higher
    /// value allows bigger thumbnails (and, for very few workspaces, a
    /// taller strip + smaller hero). Short-edge-based so the split stays
    /// balanced in any orientation / on any display size. 8…50 clamp,
    /// default 30.
    public var effectiveRailStrip: Int {
        max(8, min(50, railStrip ?? 30))
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

    /// Window-move animation on? **Default off** (opt-in): a fresh
    /// install gets instant transitions until `enabled = true`. Read
    /// this, not the raw field.
    public var effectiveAnimationsEnabled: Bool { animationsEnabled ?? false }
    /// Animate event-driven retiles (window open / close reflow)?
    /// Defaults to true when `effectiveAnimationsEnabled` is on —
    /// a single master switch covers the common case; set
    /// `event-driven = false` to keep WS-switch + user-triggered
    /// retile animated but snap on background opens / closes.
    /// Always false when the master switch is off (sub-key can't
    /// turn animation on by itself).
    public var effectiveAnimationEventDriven: Bool {
        effectiveAnimationsEnabled && (animationEventDriven ?? true)
    }
    /// Slide duration (seconds), clamped 0.08–0.8 s. Default 0.28 s.
    public var effectiveAnimationDuration: TimeInterval {
        Double(min(800, max(80, animationDurationMs ?? 280))) / 1000
    }
    /// Animation curve (used when enabled): cubic / spring / silky /
    /// snappy / random. Unknown clamps to "cubic"; "random" picks per
    /// transition. (Off is `enabled = false`, not a curve value.)
    public var effectiveAnimationCurve: String {
        let known = ["cubic", "spring", "silky", "snappy", "random"]
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

    /// Whether smart gaps are on. Default off — a lone tiled window
    /// keeps its outer-gap inset unless the user opts in.
    public var effectiveSmartGaps: Bool { smartGaps ?? false }

    /// Facet workspace defaults for a mac desktop without a
    /// `[desktop.N]` section. 5 is the memory-confirmed (`facet-workspace-model`
    /// N2) "control above zero, easy to expand" starting point.
    public static let defaultWorkspaceCount = 5

    /// Workspace list for a given mac-desktop ordinal (1-based,
    /// Mission Control order). Returns the `[desktop.N]` config when
    /// that mac desktop has a non-empty section, else
    /// `defaultWorkspaceCount` unnamed slots with no layout
    /// override. `nil` ordinal (SkyLight unavailable / single-desktop
    /// mode) → default slots.
    public func effectiveWorkspaceList(forMacDesktopOrdinal ordinal: Int?)
        -> [(index: Int, config: WorkspaceConfig)]
    {
        guard let ordinal,
              let configs = macDesktopWorkspaceConfigs[ordinal],
              let list = Self.sortedSlots(configs)
        else {
            return (1...Self.defaultWorkspaceCount).map {
                ($0, WorkspaceConfig(name: ""))
            }
        }
        return list
    }

    /// Clamp + order a raw `index → WorkspaceConfig` map into
    /// `(index, config)` slots: drop keys < 1, sort ascending.
    /// `nil` when nothing valid remains (lets callers fall back).
    private static func sortedSlots(_ configs: [Int: WorkspaceConfig])
        -> [(index: Int, config: WorkspaceConfig)]?
    {
        let valid = configs.filter { $0.key >= 1 }
        guard !valid.isEmpty else { return nil }
        return valid.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Whether facet manages the mac desktop at `ordinal`.
    ///
    /// - With **any** `[desktop.N]` section present, facet is opt-in:
    ///   it manages ONLY the mac desktops that have a section. A mac
    ///   desktop without one is left untouched — no facet workspaces,
    ///   no window parking, and the panel hides there.
    /// - With **no** `[desktop.N]` sections at all, every mac desktop
    ///   is managed with `defaultWorkspaceCount` unnamed slots.
    /// - `nil` ordinal (SkyLight unavailable / single-desktop mode) is
    ///   always managed.
    public func isMacDesktopManaged(ordinal: Int?) -> Bool {
        if macDesktopWorkspaceConfigs.isEmpty { return true }
        guard let ordinal else { return true }
        return macDesktopWorkspaceConfigs[ordinal] != nil
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
        // [rail]
        if case .string(let s)? = toml["rail"]?["edge"] { c.railEdge = s }
        if case .int(let n)? = toml["rail"]?["cells"] { c.railCells = n }
        if case .int(let n)? = toml["rail"]?["strip"] { c.railStrip = n }
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
        if case .bool(let b)? = toml["layout"]?["smart-gaps"] {
            c.smartGaps = b
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
        if case .bool(let b)? = toml["animation"]?["event-driven"] {
            c.animationEventDriven = b
        }
        // [desktop.N] per-mac-desktop workspace configs. The TOML
        // parser flattens `[desktop.1]` to the section name
        // "desktop.1"; N is the mac desktop ordinal (Mission Control
        // order). Each int key is a WS index whose value is an inline
        // table:
        //   1 = { name = "Dev", layout = "bsp" }
        // `layout` is optional; a missing / mistyped value is left
        // to the catalog's seed step to clamp to the global default.
        // A non-table value (typo) is silently dropped.
        for (sectionName, section) in toml
        where sectionName.hasPrefix("desktop.") {
            guard let ordinal = Int(sectionName.dropFirst("desktop.".count)),
                  ordinal >= 1 else { continue }
            var configs: [Int: WorkspaceConfig] = [:]
            for (key, value) in section {
                guard let idx = Int(key), idx >= 1,
                      case .table(let t) = value,
                      case .string(let name)? = t["name"]
                else { continue }
                var layout: String? = nil
                if case .string(let l)? = t["layout"] { layout = l }
                configs[idx] = WorkspaceConfig(name: name, layout: layout)
            }
            if !configs.isEmpty { c.macDesktopWorkspaceConfigs[ordinal] = configs }
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
