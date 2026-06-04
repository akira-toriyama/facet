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
    public var theme: String?               // see effectiveTheme (13 themes)
    /// Theme color-cycle period (⑪) — animatable themes (rainbow / neon /
    /// cyber / vapor / kawaii) rotate their accents over this many
    /// seconds. Set → animate; unset → static. Independent of the border
    /// cycle. Raw; read `effectiveThemeCycleSeconds`.
    public var themeCycleSeconds: Int?

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
    /// Tree-panel geometry seed (`[tree]` pos-x / pos-y / width /
    /// height). TOP-LEFT screen origin (0,0 = top-left, y down), points
    /// — same as the CLI `--pos-x/...`. All four are needed to take
    /// effect; read `effectiveTreeGeometry`.
    public var treePosX: Int?
    public var treePosY: Int?
    public var treeWidth: Int?
    public var treeHeight: Int?

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
    /// Easing curve: cubic / spring / silky / snappy / random.
    /// Raw; read `effectiveAnimationCurve`. (Off is
    /// `animationsEnabled = false`, not a curve value.)
    public var animationCurve: String?
    /// Sub-toggle: animate event-driven retiles too (window open /
    /// close reflow). Defaults to ON when `animationsEnabled` is
    /// on; flip to false to keep WS-switch + user-triggered retile
    /// animated but snap on background opens / closes. Raw; read
    /// `effectiveAnimationEventDriven`.
    public var animationEventDriven: Bool?

    // [border]
    /// Tree-panel border effect: off | neon | cyber | vapor | kawaii |
    /// rainbow. Raw; read `effectiveBorderEffect`. Default off.
    public var borderEffect: String?
    /// Neon glow (bloom) on the border effect. Raw; read
    /// `effectiveBorderGlow`. Default on.
    public var borderGlow: Bool?
    /// Border line width, px. Raw; read `effectiveBorderWidth`.
    public var borderWidth: CGFloat?
    /// Continuous border-animation period — seconds per cycle (lower =
    /// faster). Drives the rainbow hue rotation AND the width breathing.
    /// Raw; read `effectiveBorderCycleSeconds`.
    public var borderCycleSeconds: Int?
    /// Width breathing: when BOTH are set (max > min), the border width
    /// oscillates min↔max over `cycle-seconds` (any effect). Unset →
    /// the fixed `width`. Raw; read `effectiveBorderMin/MaxWidth`.
    public var borderMinWidth: Int?
    public var borderMaxWidth: Int?

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
    /// This list must stay in sync with `canonicalStyles` /
    /// `paletteFor` in FacetView's Palette.swift — FacetCore is the
    /// pure-logic layer and can't import the view-side palette, so the
    /// set of valid names is duplicated here by necessity.
    public var effectiveTheme: String {
        let raw = (theme ?? "terminal").lowercased()
        let known = [
            "terminal", "cute", "system",
            "nord", "dracula", "gruvbox", "catppuccin", "rosepine",
            "everforest", "solarized", "onedark", "monokai", "hacker",
            "paper", "mono-light", "mono-dark", "monotone",
            "neon", "cyber", "vapor", "kawaii", "rainbow",
            "random",   // meta: paletteFor picks a concrete theme
        ]
        return known.contains(raw) ? raw : "terminal"
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

    /// The tree-panel geometry seed as a CGRect (TOP-LEFT origin: x,y
    /// measured from the screen's top-left, points), or nil unless all
    /// four `[tree]` keys are set and width/height are positive. Seeds the panel each launch + on
    /// reload; runtime drags / CLI geom are session-only. (CGRect is
    /// CoreGraphics — fine in the FacetCore layer.)
    public var effectiveTreeGeometry: CGRect? {
        guard let x = treePosX, let y = treePosY,
              let w = treeWidth, w > 0, let h = treeHeight, h > 0
        else { return nil }
        return CGRect(x: CGFloat(x), y: CGFloat(y),
                      width: CGFloat(w), height: CGFloat(h))
    }
    /// Some — but not all — tree-geometry keys set (so the seed was
    /// ignored). Surfaced by `unknownValueWarnings`.
    private var treeGeometryPartial: Bool {
        let n = [treePosX, treePosY, treeWidth, treeHeight]
            .lazy.filter { $0 != nil }.count
        return n > 0 && n < 4
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

    /// Tree-panel border effect: off | neon | cyber | vapor | kawaii |
    /// rainbow; unknown / unset → "off" (opt-in). Must stay in sync
    /// with `borderEffectFor` in FacetView's BorderEffect.swift —
    /// FacetCore can't import the view-side colors, so the name set is
    /// duplicated here (same pattern as `effectiveTheme`).
    public var effectiveBorderEffect: String {
        let raw = (borderEffect ?? "off").lowercased()
        let known = ["off", "neon", "cyber", "vapor", "kawaii",
                     "rainbow", "random"]
        return known.contains(raw) ? raw : "off"
    }
    /// Neon glow (bloom) on the border effect. Default on.
    public var effectiveBorderGlow: Bool { borderGlow ?? true }
    /// Border line width, px. [0.5, 30] clamp, default 1.5.
    public var effectiveBorderWidth: CGFloat {
        max(0.5, min(30, borderWidth ?? 1.5))
    }
    /// Seconds per continuous border-animation cycle — the rainbow hue
    /// rotation and the width breath share this period (lower = faster).
    /// [1, 120] clamp, default 6.
    public var effectiveBorderCycleSeconds: CGFloat {
        CGFloat(max(1, min(120, borderCycleSeconds ?? 6)))
    }

    /// Theme color-cycle period (⑪), seconds. [1, 120] clamp, default 6.
    /// Independent of `effectiveBorderCycleSeconds`.
    public var effectiveThemeCycleSeconds: CGFloat {
        CGFloat(max(1, min(120, themeCycleSeconds ?? 6)))
    }
    /// Width-breathing bounds, px (each clamped 0.5–30), or `nil` when
    /// unset. Breathing runs only when BOTH are set and max > min.
    public var effectiveBorderMinWidth: CGFloat? {
        borderMinWidth.map { max(0.5, min(30, CGFloat($0))) }
    }
    public var effectiveBorderMaxWidth: CGFloat? {
        borderMaxWidth.map { max(0.5, min(30, CGFloat($0))) }
    }

    /// Named-enum config values that were written but didn't match any
    /// known name, so the matching `effective*` accessor silently
    /// clamped them to a default. Returns one human-readable warning
    /// per clamp (empty when every written value was valid).
    ///
    /// The clamp itself is deliberate — a typo'd layout / theme / edge
    /// must never break the panel (see each `effective*`). But the
    /// fallback is otherwise invisible: a config carried across a
    /// breaking rename (e.g. `tall` → `master-left`) silently degrades
    /// to `float` with no signal. This surfaces that, without changing
    /// behaviour.
    ///
    /// Detection is "raw written, non-empty, and differs from the
    /// effective value", so it carries **no copy** of any key's
    /// known-set — it can't drift from the accessors and never fires
    /// for an unset key. Numeric range-clamps (gaps, cell counts) are
    /// bounds, not typos, so they're intentionally excluded.
    ///
    /// Call once per load (the server logs each via `Log.line` at
    /// startup + hot-reload) — never from an `effective*` accessor,
    /// which runs every refresh tick.
    public func unknownValueWarnings() -> [String] {
        var out: [String] = []
        func clamp(_ key: String, _ raw: String?, _ effective: String) {
            guard let raw, !raw.isEmpty,
                  raw.lowercased() != effective.lowercased() else { return }
            out.append("config: unknown \(key) \"\(raw)\" "
                + "— using default \"\(effective)\"")
        }
        clamp("theme", theme, effectiveTheme)
        clamp("layout", defaultLayout, effectiveDefaultLayout)
        clamp("rail edge", railEdge, effectiveRailEdge.rawValue)
        clamp("preview-mode", treePreviewMode, effectiveTreePreviewMode)
        clamp("animation curve", animationCurve, effectiveAnimationCurve)
        clamp("border effect", borderEffect, effectiveBorderEffect)
        clamp("grid label-position", gridLabelPosition,
              effectiveGridLabelPosition)
        if treeGeometryPartial {
            out.append("config: [tree] geometry needs all of pos-x / "
                + "pos-y / width / height — partial set ignored")
        }
        // Startup view clamps to agent-only mode (nil), not a value.
        if let raw = defaultView, !raw.isEmpty, effectiveDefaultView == nil {
            out.append("config: unknown view \"\(raw)\" "
                + "— starting in agent-only mode (no panel shown)")
        }
        return out
    }

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
        if case .int(let n)? = toml[""]?["theme-cycle-seconds"] {
            c.themeCycleSeconds = n
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
        if case .int(let n)? = toml["tree"]?["pos-x"] { c.treePosX = n }
        if case .int(let n)? = toml["tree"]?["pos-y"] { c.treePosY = n }
        if case .int(let n)? = toml["tree"]?["width"] { c.treeWidth = n }
        if case .int(let n)? = toml["tree"]?["height"] { c.treeHeight = n }
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
        // [border]
        if case .string(let s)? = toml["border"]?["effect"] {
            c.borderEffect = s
        }
        if case .bool(let b)? = toml["border"]?["glow"] {
            c.borderGlow = b
        }
        if case .int(let n)? = toml["border"]?["width"] {
            c.borderWidth = CGFloat(n)
        }
        if case .int(let n)? = toml["border"]?["cycle-seconds"] {
            c.borderCycleSeconds = n
        }
        if case .int(let n)? = toml["border"]?["min-width"] {
            c.borderMinWidth = n
        }
        if case .int(let n)? = toml["border"]?["max-width"] {
            c.borderMaxWidth = n
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
