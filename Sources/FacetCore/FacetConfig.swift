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
import Palette   // sill's pure (AppKit-free) theme layer — `canonical(_:)`
import Toml      // sill's pure TOML subset parser (`Toml.Value` accessors)

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

    // [theme] — the app-default palette. `theme` keys also live in the
    // surface-owning blocks ([tree]/[grid]/[rail], `""` = inherit this
    // one) per the family rule "theme lives with the painted surface".
    public var theme: String?               // [theme].name; see effectiveTheme
    /// Theme color-cycle period (`[theme].color-cycle-ms`, integer ms) —
    /// animatable themes (rainbow / chomp) rotate their accents over
    /// this period. Set → animate; unset → static. Independent of the
    /// border cycle. Raw; read `effectiveThemeCycleSeconds`.
    public var themeColorCycleMs: Int?

    // [grid]
    public var gridCols: Int?
    public var gridLabelPosition: String?   // "up" | "down"
    public var thumbnailRefreshSeconds: Int?
    /// Per-view theme override (`[grid].theme`); `""` / unset inherits
    /// `[theme].name`. Read through `effectiveGridTheme`.
    public var gridTheme: String?

    // [rail]
    public var railEdge: String?            // "top" | "bottom" | "left" | "right"
    public var railCells: Int?              // max strip cells shown at once
    public var railStrip: Int?              // strip band size, % of short screen edge
    /// Per-view theme override (`[rail].theme`); `""` / unset inherits
    /// `[theme].name`. Read through `effectiveRailTheme`.
    public var railTheme: String?

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
    /// Per-view theme override (`[tree].theme`); `""` / unset inherits
    /// `[theme].name`. Read through `effectiveTreeTheme`.
    public var treeTheme: String?
    /// Arcade "line-pets" that walk the tree panel's outer border —
    /// a shared sill decoration (`Effects.drawLinePets`, also on halo's
    /// ring + wand's cards). Names from `canonicalLinePetNames`
    /// (`"chomp"` / `"ghost"`); unknown names drop with a warning.
    /// A TOML array only (`["chomp", "ghost"]` — the family grammar;
    /// `[]` = off). Empty / unset = off (opt-in).
    /// Read through `effectiveTreeLinePets`.
    public var treeLinePets: [String]?
    /// Pet size multiplier on the baked-in sprite (chomp ø14 / ghost
    /// 14×16 pt at 1.0). Default 0.9 — a touch under the row height so
    /// the sprite reads without swamping the text. Read through
    /// `effectiveTreePetScale` (clamped ≥ 0.1).
    public var treePetScale: Double?
    /// Seconds for a pet to circle the row once — a size-independent
    /// tempo (the view derives pt/s from the row perimeter, so the orbit
    /// feels equally lively at any panel width). Default 8. Read through
    /// `effectiveTreePetLapSeconds` (clamped ≥ 0.5).
    public var treePetLapSeconds: Double?

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
    /// Raw (`[border].color-cycle-ms`, integer ms); read
    /// `effectiveBorderCycleSeconds`.
    public var borderColorCycleMs: Int?
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

    /// `[grouping] by` — `"workspace"` (default) or `"tag"` (M11-3).
    /// Raw; read `effectiveGrouping`.
    public var grouping: String?

    /// `[[tag]]` names in declaration order (M11-3). `nil` when the
    /// config defines none. Parsed from the raw TOML text
    /// (array-of-tables) by `load`, like `exclusionRules`. Read
    /// `effectiveTagModel`.
    public var tagDefs: [String]?

    /// `[window] raise-on-open` — how a freshly-opened floating window
    /// (sheet / dialog / palette / `[[exclude]]` `action="float"`) is
    /// surfaced on first sight. Raw; read `effectiveRaiseOnOpen`.
    public var raiseOnOpen: String?

    public init() {}

    // MARK: - Effective accessors (defaults + clamping)

    /// Returns the configured view name if valid, else `nil`
    /// (= agent-only mode). Unknown names treated as missing.
    public var effectiveDefaultView: String? {
        guard let raw = defaultView?.lowercased() else { return nil }
        return ["tree", "grid"].contains(raw) ? raw : nil
    }

    /// Falls back to `"terminal"` for unset or unrecognised values.
    /// The set of valid names is sill's `canonicalThemeNames` (the single
    /// source of truth) — `canonical(_:)` lowercases / trims and returns the
    /// matched name, or `nil` for an unknown one (silently clamped to
    /// `terminal` here; the CLI rejects loudly instead). FacetCore links
    /// sill's pure `Palette` module for this — no hand-kept duplicate list.
    /// `random` is a member of `canonicalThemeNames`, so it passes through;
    /// `paletteFor` then picks a concrete theme each call.
    public var effectiveTheme: String {
        canonical(theme ?? "terminal") ?? "terminal"
    }

    /// Per-view themes — `[tree]/[grid]/[rail].theme`. `""` / unset /
    /// unknown inherit the app default (`effectiveTheme`); a known
    /// canonical name (incl. `random`) overrides it for that surface
    /// only. Family rule: the theme key lives with the painted surface.
    public var effectiveTreeTheme: String { perViewTheme(treeTheme) }
    public var effectiveGridTheme: String { perViewTheme(gridTheme) }
    public var effectiveRailTheme: String { perViewTheme(railTheme) }

    private func perViewTheme(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return effectiveTheme }
        return canonical(raw) ?? effectiveTheme
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
    /// (the original bottom bar). Case-insensitive. A CLI `--edge`
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

    /// Validated line-pet names for the tree, in author order, lower-
    /// cased + trimmed, empty entries dropped, unknown names dropped
    /// against sill Palette's `canonicalLinePetNames` (pure since 0.6.0,
    /// so FacetCore validates here — the old "view seam drops silently"
    /// workaround is retired; typos warn via `unknownValueWarnings`).
    /// Empty `[]` and unset both ⇒ `[]` (pets off).
    public var effectiveTreeLinePets: [String] {
        (treeLinePets ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
            .filter { canonicalLinePetNames.contains($0) }
    }
    /// Pet size multiplier, clamped to a sane floor. Default 0.9.
    public var effectiveTreePetScale: CGFloat {
        CGFloat(max(0.1, treePetScale ?? 0.9))
    }
    /// Seconds per pet lap, clamped to a sane floor. Default 8.
    public var effectiveTreePetLapSeconds: CGFloat {
        CGFloat(max(0.5, treePetLapSeconds ?? 8))
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
        return LayoutRegistry.allModeNames.contains(m) ? m : "float"
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

    /// Tree-panel border effect; unknown / unset → "off" (opt-in). The
    /// name set IS sill Palette's `canonicalEffectNames` (single source
    /// of truth since sill 0.6.0 moved the pure vocabulary out of the
    /// AppKit-gated Effects module — the hand-copied list this accessor
    /// used to carry is retired). `"off"` is a member, so it
    /// canonicalizes like any other name.
    public var effectiveBorderEffect: String {
        let raw = (borderEffect ?? "off").lowercased()
        return canonicalEffectNames.contains(raw) ? raw : "off"
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
        CGFloat(max(1000, min(120_000, borderColorCycleMs ?? 6000))) / 1000
    }

    /// Theme color-cycle period (⑪), seconds. [1, 120] clamp, default 6.
    /// Independent of `effectiveBorderCycleSeconds`.
    public var effectiveThemeCycleSeconds: CGFloat {
        CGFloat(max(1000, min(120_000, themeColorCycleMs ?? 6000))) / 1000
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
        // Theme gets the richer treatment: same clamp, plus sill
        // suggest(_:)'s "did you mean" when a near-miss exists.
        if let raw = theme, !raw.isEmpty,
           raw.lowercased() != effectiveTheme.lowercased() {
            let hint = suggest(raw).map { " (did you mean \"\($0)\"?)" } ?? ""
            out.append("config: unknown theme \"\(raw)\" "
                + "— using default \"\(effectiveTheme)\"" + hint)
        }
        clamp("layout", defaultLayout, effectiveDefaultLayout)
        clamp("rail edge", railEdge, effectiveRailEdge.rawValue)
        clamp("preview-mode", treePreviewMode, effectiveTreePreviewMode)
        clamp("animation curve", animationCurve, effectiveAnimationCurve)
        clamp("border effect", borderEffect, effectiveBorderEffect)
        clamp("grid label-position", gridLabelPosition,
              effectiveGridLabelPosition)
        clamp("[window] raise-on-open", raiseOnOpen,
              effectiveRaiseOnOpen.rawValue)
        // Per-view theme typos inherit the app default — warn with a hint.
        for (key, raw) in [("[tree].theme", treeTheme),
                           ("[grid].theme", gridTheme),
                           ("[rail].theme", railTheme)] {
            if let raw, !raw.isEmpty, canonical(raw) == nil {
                let hint = suggest(raw).map { " (did you mean \"\($0)\"?)" } ?? ""
                out.append("config: unknown \(key) \"\(raw)\" "
                    + "— inheriting [theme].name" + hint)
            }
        }
        // Pet-name typos: clamp-and-log (family standard, wand wording).
        let petRaws = (treeLinePets ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        for raw in petRaws where !canonicalLinePetNames.contains(raw) {
            out.append("config: [tree].line-pets contains unrecognised "
                + "entry \"\(raw)\" — dropped (valid: "
                + canonicalLinePetNames.sorted().joined(separator: ", ") + ")")
        }
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

    /// Build from the FLAT `[section: [key: value]]` map (the literal-
    /// header dict from `Toml.parseFlat`). The uniform `[block]` keys are
    /// driven by the single declarative `configSpec` (which ALSO emits the
    /// JSON Schema — see `FacetConfig+Spec.swift`); the dynamic
    /// `[desktop.N]` sections are decoded by their own helper. The
    /// `[[exclude]]/[[tag]]` arrays-of-tables are filled by
    /// `load` from the raw text (they don't live in this flat map).
    public static func from(toml: [String: [String: TOMLValue]])
        -> FacetConfig
    {
        var c = FacetConfig()
        configSpec.decode(toml, into: &c)
        decodeDesktopSections(toml, into: &c)
        return c
    }

    /// Effective `[[exclude]]` rule set (empty when none configured).
    /// Always read through this, never the raw Optional.
    public var effectiveExclusionRules: ExclusionRules {
        ExclusionRules(exclusionRules ?? [])
    }

    // MARK: - Grouping / tags (M11-3)

    /// Effective grouping paradigm. `[grouping] by` clamped to a known
    /// value; unknown / unset → `.workspace` (the historical default).
    /// A typo here is also surfaced by `fatalConfigErrors` so it fails
    /// loud rather than silently running the default.
    public var effectiveGrouping: Grouping {
        Grouping(rawValue: (grouping ?? "workspace").lowercased())
            ?? .workspace
    }

    /// Effective tag vocabulary (empty `TagModel` when none defined).
    /// Declaration order is preserved — it fixes each tag's bit, the
    /// startup lens (`firstBit`), and the order a window's `#tag` chips
    /// list on its flat tree row (`names(in:)`).
    public var effectiveTagModel: TagModel {
        TagModel(tagDefs ?? [])
    }

    /// Fatal config errors that should refuse startup (Fail Fast /
    /// Rule of Repair — never silently fall back). Empty = OK to start.
    /// The app entry prints these to stderr and `exit 2`.
    ///
    /// Checks (tag mode only):
    ///   - `[grouping] by` is a typo (neither workspace nor tag).
    ///   - `by = tag` but no `[[tag]]` defined (nothing to show).
    ///   - `by = tag` with a default layout that's workspace-only
    ///     (`bsp` / `stack`) — incompatible per `LayoutGrouping`.
    ///   - `by = tag` with `default-view = "grid"` — the grid *view*
    ///     is workspace-only (distinct from the `grid` *layout*, which
    ///     is fine); tag mode shows the tree view only.
    public func fatalConfigErrors() -> [String] {
        var out: [String] = []
        if let raw = grouping, !raw.isEmpty,
           Grouping(rawValue: raw.lowercased()) == nil {
            out.append("config: unknown [grouping] by \"\(raw)\" "
                + "(expected \"workspace\" or \"tag\")")
        }
        guard effectiveGrouping == .tag else { return out }

        let model = effectiveTagModel
        if model.isEmpty {
            out.append("config: [grouping] by = \"tag\" but no [[tag]] "
                + "defined — add at least one [[tag]] name = \"…\"")
        }
        let layout = effectiveDefaultLayout
        if !LayoutGrouping.isCompatible(mode: layout, with: .tag) {
            out.append("config: layout \"\(layout)\" is not compatible "
                + "with [grouping] by = \"tag\" (use a stateless layout "
                + "like \"grid\" / \"master-left\" / \"float\"; "
                + "\"bsp\" / \"stack\" are workspace-only)")
        }
        // The grid VIEW (full-screen overview) is workspace-only — note
        // this is the `default-view` key, NOT the `grid` *layout* above,
        // which is a perfectly valid stateless tag-mode layout. `rail`
        // can't be a default-view (effectiveDefaultView clamps it to nil
        // → agent-only), so only grid needs flagging here.
        if effectiveDefaultView == "grid" {
            out.append("config: default-view = \"grid\" is workspace-only "
                + "— not available with [grouping] by = \"tag\" "
                + "(tag mode shows the tree view only)")
        }
        return out
    }

    /// Effective `[window] raise-on-open`. Unknown / unset →
    /// `.raise` (the default: surface freshly-opened floating windows
    /// without stealing focus). A typo clamps to the default, like
    /// every other TOML key.
    public var effectiveRaiseOnOpen: RaiseOnOpen {
        RaiseOnOpen(rawValue: (raiseOnOpen ?? "raise").lowercased())
            ?? .raise
    }

    /// Build `[ExclusionRule]` from the raw TOML text's `[[exclude]]`
    /// array-of-tables. Each table: `app` / `title` / `role` /
    /// `subrole` are strings (regex for app/title, exact for
    /// role/subrole), `max-width` / `max-height` are ints, `action`
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
                maxWidth: dbl("max-width"), maxHeight: dbl("max-height"),
                action: action)
            let hasKey = rule.app != nil || rule.title != nil
                || rule.role != nil || rule.subrole != nil
                || rule.maxWidth != nil || rule.maxHeight != nil
            return hasKey ? rule : nil
        }
    }

    /// Build the ordered `[[tag]]` name list from the raw TOML text.
    /// Each table is `name = "…"`; the name is normalized through
    /// `TagName.normalized` (space→`-`, `#`-strip, policy check) so a
    /// config tag like `name = "my tag"` becomes `my-tag` and is
    /// reachable from the CLI (#227). Names that fail the policy entirely
    /// (empty, or carrying a forbidden `:` / `=`) are dropped. Duplicate
    /// normalized names are dropped (first wins) so the bit mapping stays
    /// 1:1. Declaration order is preserved.
    public static func tagDefs(fromTOML text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in parseTOMLArrayOfTables(text, table: "tag") {
            guard case .string(let raw)? = t["name"],
                  let name = TagName.normalized(raw),
                  !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
        }
        return out
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
            let tags = tagDefs(fromTOML: text)
            if !tags.isEmpty { c.tagDefs = tags }
            return c
        }
        FileHandle.standardError.write(Data(
            "facet: could not read \(path)\n".utf8))
        return .init()
    }
}
