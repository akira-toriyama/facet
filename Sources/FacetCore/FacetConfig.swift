// User-facing config (`~/.config/facet/config.toml`). The app
// READS only — never writes — so the file (or its absence) is the
// single source of truth. Repo ships ``config.toml`` at its root
// with defaults + comments; README instructs users to ``curl`` it
// into `~/.config/facet/`. If the file is absent, ``effective*``
// accessors below supply built-in defaults (agent-only mode, no
// panel).
//
// ONE carve-out (t-hdxb): with ``[config] auto-promote = true`` +
// ``[config] export-path`` set, `bootstrapWithAutoPromote` may, at
// STARTUP ONLY, overwrite config.toml with a strictly-newer snapshot
// (the sole sanctioned write). `load` itself stays read-only; the
// snapshot writer is the pure `ConfigSnapshot`. See CLAUDE.md
// `### Configuration`.
//
// All public fields are *raw* (Optional, as parsed from TOML).
// `effective*` accessors apply defaults + clamping; consumers
// should always read through those so a typo can never break the
// UI.

import ConfigSchema // sill's pure schema validator — `ValidationError`
import CoreGraphics
import Foundation
import Palette   // sill's pure (AppKit-free) theme layer — `canonical(_:)`
import Toml      // sill's pure TOML subset parser (`Toml.Value` accessors)

/// Runtime descriptor for one facet workspace: a display `name` plus an
/// optional `layout` seed for `facet workspace --layout`. A
/// `[[desktop.N.section]]` `type = "workspace"` cell is named by its
/// optional `label` (§A); an empty label leaves `name == ""` (unnamed —
/// displayed by its 1-based index, §B). `name` is also owned at runtime by
/// `facet workspace --rename`. `layout` comes from the section's `layout`
/// (or the global `[layout] default`); an unknown / mistyped value falls
/// back to that default at seed time.
public struct WorkspaceConfig: Sendable, Equatable {
    public let name: String
    public let layout: String?
    public init(name: String, layout: String? = nil) {
        self.name = name
        self.layout = layout
    }
}

public struct FacetConfig: Sendable {
    // [theme] — the app-default palette. `theme` keys also live in the
    // surface-owning blocks ([tree]/[grid]/[rail], `""` = inherit this
    // one) per the family rule "theme lives with the painted surface".
    public var theme: String?               // [theme].name; see effectiveTheme
    /// A1: strict schema violations found on the LOAD path, recorded (not
    /// rejected) by `load(source:)`; emitted at startup/hot-reload by
    /// `Controller.logConfigWarnings()`. `[]` when clean or unparseable.
    public internal(set) var schemaWarnings: [ValidationError] = []
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
    /// Slide duration in ms (raw; clamped 80–800 at runtime by the adapter).
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
    /// the fixed `width`. Fractional like the sibling `width` (e.g.
    /// `0.5`). Raw; read `effectiveBorderMin/MaxWidth`.
    public var borderMinWidth: CGFloat?
    public var borderMaxWidth: CGFloat?

    // [config] — config auto-persistence (t-hdxb). Setting `export-path`
    // turns auto-export ON: every session edit (workspace / section rename,
    // lens match, layout, tag vocabulary) writes the full effective config
    // to that file — surgically, leaving config.toml untouched. `auto-promote`
    // (opt-in, off by default) promotes a NEWER snapshot onto config.toml at
    // the next startup — the ONE sanctioned write to the user's config file.
    /// `[config].export-path` — the auto-export snapshot target (MUST be a
    /// different file from config.toml). Raw; read `effectiveExportPath`
    /// (then `resolvePath` to absolutise against the config directory).
    public var exportPath: String?
    /// `[config].auto-promote` — promote a newer snapshot onto config.toml
    /// at startup. Raw; read `effectiveAutoPromote`. Default off.
    public var autoPromote: Bool?

    // [tags]
    /// `[tags].defined` — the tag vocabulary (names only, no colors) offered
    /// in the tag editor before any live window carries a name. Grown by
    /// auto-export as tags are created. A TOML array (`["web", "code"]`; `[]`
    /// = none). Raw; read `effectiveDefinedTags`.
    public var definedTags: [String]?

    /// Per-mac-desktop `[[desktop.N.section]]` definitions (the section/lens
    /// model). Outer key is the mac desktop ordinal (Mission Control order,
    /// 1-based); value is that desktop's sections in config-declaration (=
    /// tree display) order. `nil`/empty when none configured. Parsed from the
    /// raw TOML text (nested array-of-tables) by `load`, like
    /// `exclusionRules`. Read through `effectiveMacDesktopSectionConfigs`.
    /// Consumed in production: `FilterProjection` (the single display path for
    /// tree/grid/rail — a `facet lens` is a pure VIEW that lists its matched
    /// windows, t-0021), `ApplyResolver` (DnD apply/un-apply), and
    /// `effectiveWorkspaceList` (workspace count + layout). Shipped #296–#301.
    public var macDesktopSectionConfigs: [Int: [DesktopSection]] = [:]

    /// Per-mac-desktop `[[desktop.N.tab]]` definitions (the board model,
    /// t-wrd2). Outer key is the mac desktop ordinal (1-based); value is that
    /// desktop's tabs in config-declaration order, each a `type` + optional
    /// `label` + ordered child sections (which inherit the tab's type). Parsed
    /// from the raw TOML text (NESTED array-of-tables, via `Toml.Annotated`) by
    /// `load`, like `macDesktopSectionConfigs`. ADDITIVE / no consumer yet
    /// (t-f19q / Wave 1 — the nesting-aware reader prerequisite); read through
    /// `effectiveMacDesktopTabConfigs`. Disjoint from the flat
    /// `[[desktop.N.section]]` decode — the two read different header shapes.
    public var macDesktopTabConfigs: [Int: [DesktopTab]] = [:]

    /// Per-mac-desktop `[desktop.N]` typed-table definitions (board abolition,
    /// t-0sbm). Outer key is the mac desktop ordinal (1-based); value is that
    /// desktop's single `DesktopMeta` (`type` + `label`, plus lens-only `match` /
    /// `layout` / `show-non-matching`). Parsed from the FLAT `parseTOMLSubset`
    /// map by `load` (via `decodeDesktopTables`). Read through `desktopType` /
    /// `desktopLens`. This is the successor to `macDesktopTabConfigs` — a mac
    /// desktop is now typed directly rather than grouped into boards.
    public var macDesktopMetaConfigs: [Int: DesktopMeta] = [:]

    /// `[[exclude]]` rules — windows matching one are floated or
    /// ignored instead of tiled (unnamed popups, auxiliary panels).
    /// `nil` when the config specifies none. Parsed from the raw TOML
    /// text (array-of-tables), not the flattened `[section]` dict, so
    /// it's filled by `load`, not `from(toml:)`.
    public var exclusionRules: [ExclusionRule]?

    /// `[[rule]]` adopt-rules (#282/#286 Phase 3) — a new window matching a
    /// rule's `match` gets the rule's facets set on adoption (the declarative
    /// successor to `[[assign]]`, #191). Global (not per-mac-desktop). `nil`
    /// when none configured. Parsed from the raw TOML text (array-of-tables)
    /// by `load`, like `exclusionRules`. Read through `effectiveRules`.
    public var rules: [Rule]?

    /// `[window] raise-on-open` — how a freshly-opened floating window
    /// (sheet / dialog / palette / `[[exclude]]` `action="float"`) is
    /// surfaced on first sight. Raw; read `effectiveRaiseOnOpen`.
    public var raiseOnOpen: String?

    public init() {}

    // MARK: - Effective accessors (defaults + clamping)

    /// The configured auto-export snapshot target (`[config] export-path`),
    /// trimmed; `nil` (auto-export OFF) when unset or blank. Returned RAW /
    /// unresolved — callers absolutise it against the config file's own
    /// directory via `resolvePath(_:relativeTo:)` (the sidecar convention),
    /// because a `FacetConfig` value doesn't carry its own source path.
    public var effectiveExportPath: String? {
        guard let raw = exportPath?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// Whether a newer snapshot is promoted onto config.toml at startup
    /// (`[config] auto-promote`). Default off — persistence only writes the
    /// snapshot until the user opts in to the promote-back step.
    public var effectiveAutoPromote: Bool { autoPromote ?? false }

    /// The tag vocabulary (`[tags] defined`): trimmed, blanks dropped,
    /// de-duplicated in author order. Names only (no colors). Offered as
    /// autocomplete in the tag editor even before any window uses them.
    public var effectiveDefinedTags: [String] {
        var seen: Set<String> = []
        return (definedTags ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Expand a `~`-prefixed or relative path against `baseDir`, then
    /// CANONICALIZE it (collapse `.` / `..` / redundant `//`). An already-
    /// absolute path (post tilde-expansion) is canonicalized in place. Used to
    /// resolve `[config] export-path` against the config file's directory, the
    /// same sidecar logic as the `config.schema.json` neighbour. Canonicalising
    /// is what lets the self-write guards (`isSameFile`) catch an `export-path`
    /// like `./config.toml` or `../facet/config.toml` that aliases config.toml —
    /// otherwise a raw-string compare would miss it and facet would write the
    /// snapshot onto config.toml at runtime. Symlinks are NOT resolved here (a
    /// user's chosen export-path may legitimately be a link); `isSameFile`
    /// resolves those for the guard comparison only.
    public static func resolvePath(_ raw: String, relativeTo baseDir: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let joined = expanded.hasPrefix("/")
            ? expanded
            : (baseDir as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: joined).standardizedFileURL.path
    }

    /// True when two paths refer to the SAME file, comparing symlink-resolved,
    /// standardized forms — so `./config.toml`, `../facet/config.toml`, and a
    /// symlink alias all correctly match config.toml. Used by the snapshot
    /// self-write guards: a snapshot (`export-path`) must never target
    /// config.toml (it would trip the ConfigWatcher → reload loop and breach
    /// the read-only rule).
    public static func isSameFile(_ a: String, _ b: String) -> Bool {
        func canon(_ p: String) -> String {
            URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        }
        return canon(a) == canon(b)
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
    public var effectiveInnerGap: CGFloat { clampedGap(innerGap) }

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
        borderMinWidth.map { max(0.5, min(30, $0)) }
    }
    public var effectiveBorderMaxWidth: CGFloat? {
        borderMaxWidth.map { max(0.5, min(30, $0)) }
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
        return out
    }

    /// Facet workspace count for a mac desktop without a configured section
    /// model. 5 is the memory-confirmed (`facet-workspace-model` N2) "control
    /// above zero, easy to expand" starting point.
    public static let defaultWorkspaceCount = 5

    /// Workspace list for a given mac-desktop ordinal (1-based, Mission
    /// Control order). When the section model is active there (≥1
    /// `type = "workspace"` section, flat OR in a board), the COUNT and
    /// per-workspace layout seed come from those sections (via
    /// `workspaceSubstrateSections`); a section's name is its `label` if set,
    /// else it stays UNNAMED and is shown by its 1-based index (§B — the
    /// `WorkspaceNaming` emoji pool was retired). Else `defaultWorkspaceCount`
    /// unnamed slots with no layout override. `nil` ordinal (SkyLight
    /// unavailable / single-desktop mode) → default slots.
    public func effectiveWorkspaceList(forMacDesktopOrdinal ordinal: Int?)
        -> [(index: Int, config: WorkspaceConfig)]
    {
        // Section model (authoritative when active): the workspace COUNT and
        // per-workspace layout seed come from the `type = "workspace"`
        // sections. §A: a non-empty `label` names the workspace FROM CONFIG
        // (the old "always auto-named" rule was reversed). §B: an empty label
        // leaves the workspace UNNAMED (`name == ""`) — displayed by its
        // 1-based index, not an emoji. Runtime `facet workspace --rename`
        // still overrides. `isSectionModelActive` guarantees a non-nil ordinal
        // with ≥1 workspace section, so this list is non-empty.
        if isSectionModelActive(ordinal: ordinal), let ordinal {
            let wsSections = workspaceSubstrateSections(forOrdinal: ordinal)
            // §B: a non-empty `label` names the workspace; an empty one stays
            // UNNAMED (`name == ""`) and is displayed by its 1-based index
            // (the view composes it via `sectionDisplayLabel`). No emoji
            // auto-name — so unnamed slots can't collide on a fabricated name
            // (`index(ofName:)` nil-guards "" → they're index-addressed only).
            // The A-2 emoji-dodge is gone with the pool that necessitated it.
            return wsSections.enumerated().map { k, s in
                (index: k + 1, config: WorkspaceConfig(name: s.label, layout: s.layout))
            }
        }
        return (1...Self.defaultWorkspaceCount).map {
            ($0, WorkspaceConfig(name: ""))
        }
    }

    /// Whether facet manages the mac desktop at `ordinal`.
    ///
    /// - With **any** `[[desktop.N.section]]` present, facet is opt-in: it
    ///   manages ONLY the mac desktops that have a section block. A mac
    ///   desktop without one is left untouched — no facet workspaces, no
    ///   window parking, and the panel hides there.
    /// - With **none** present (the shipped default), every mac desktop is
    ///   managed with `defaultWorkspaceCount` unnamed slots.
    /// - `nil` ordinal (SkyLight unavailable / single-desktop mode) is
    ///   always managed.
    ///
    /// The section signal is read through `effectiveMacDesktopSectionConfigs`
    /// AND `effectiveMacDesktopTabConfigs` (the board model, t-wrd2 / M1): a
    /// tab-only config opts facet in exactly like a section config. Keying on
    /// the flat dict alone made an empty flat dict (every tab-only config)
    /// return `true` for EVERY ordinal — facet would adopt + default-slot-seed
    /// every unconfigured desktop. The gate is the UNION of the two ordinal
    /// sets (not substrate presence — a lens-only config is deliberately
    /// MANAGED-but-model-inactive, see `isSectionModelActive`).
    public func isMacDesktopManaged(ordinal: Int?) -> Bool {
        let sections = effectiveMacDesktopSectionConfigs
        let tabs = effectiveMacDesktopTabConfigs
        let metas = macDesktopMetaConfigs
        if sections.isEmpty && tabs.isEmpty && metas.isEmpty { return true }
        guard let ordinal else { return true }
        return sections[ordinal] != nil || tabs[ordinal] != nil
            || metas[ordinal] != nil
    }

    /// The declared `type` of the mac desktop at `ordinal` (board abolition,
    /// t-0sbm). Resolution order:
    ///   • an explicit `[desktop.N] type = …` table wins;
    ///   • else `.workspace` if the desktop has `[[desktop.N.section]]` blocks
    ///     (back-compat — a flat-sections config with no `[desktop.N]` table
    ///     reads as a workspace desktop);
    ///   • else `nil` (no typed desktop / unconfigured — e.g. a board-only
    ///     desktop while boards still exist, or a bare default desktop).
    public func desktopType(ordinal: Int?) -> SectionType? {
        guard let ordinal else { return nil }
        if let meta = macDesktopMetaConfigs[ordinal] { return meta.type }
        if macDesktopSectionConfigs[ordinal] != nil { return .workspace }
        return nil
    }

    /// The lens definition for a `type = "lens"` mac desktop at `ordinal`, else
    /// `nil` (not a lens desktop). The single always-on lens (`match` + `layout`
    /// + `show-non-matching`) that drives the desktop-lens park + tile.
    public func desktopLens(ordinal: Int?) -> DesktopMeta? {
        guard let ordinal, let meta = macDesktopMetaConfigs[ordinal],
              meta.type == .lens else { return nil }
        return meta
    }

    /// The synthesized `[DesktopSection]` a `type = "lens"` mac desktop feeds to
    /// `FilterProjection.project` (board abolition, t-0sbm). A lens desktop has no
    /// authored sections — its single always-on lens becomes ONE `.lens` section
    /// (its matched windows, id `section:0:<label>` — the handle the runtime
    /// change-match uses). When `show-non-matching` is set, a second `unassigned`
    /// receptacle is appended so the tree ALSO shows the non-matching ("holding")
    /// windows as the projection's leftover (universe − matched); otherwise the
    /// tree is the lens section alone. Empty (`[]`) when `ordinal` is not a lens
    /// desktop, so the caller falls back to the workspace path. Pure.
    public func lensDesktopSections(ordinal: Int?) -> [DesktopSection] {
        guard let lens = desktopLens(ordinal: ordinal) else { return [] }
        var out: [DesktopSection] = [
            DesktopSection(type: .lens, label: lens.label, match: lens.match,
                           layout: lens.layout),
        ]
        if lens.showNonMatching {
            out.append(DesktopSection(type: .workspace, unassigned: true))
        }
        return out
    }

    /// Whether the section/lens model drives the mac desktop at `ordinal` —
    /// i.e. it has at least one `type = "workspace"` section in EITHER the flat
    /// `[[desktop.N.section]]` list OR any `[[desktop.N.tab]]` board (the board
    /// model, t-wrd2 / W2.5). This is the gate the read path, auto-naming, and
    /// the overview/tree consult to decide between the section model and the
    /// default unnamed slots.
    ///
    /// Board-INDEPENDENT — a config property, not the current selection: the
    /// gate is true whenever a workspace substrate is DECLARED, even if the
    /// session-selected board is a lens board (a display-only switch never
    /// removes the substrate). Shares `workspaceSubstrateSections` with
    /// `effectiveWorkspaceList`, so "gate active" and "seed N workspaces" can
    /// never disagree (the W2.5 SSOT).
    ///
    /// `nil` ordinal (SkyLight unavailable / single-desktop) is `false`: the
    /// section model is a per-ordinal opt-in, and an unresolvable ordinal
    /// falls back to the default-slot path.
    public func isSectionModelActive(ordinal: Int?) -> Bool {
        guard let ordinal else { return false }
        return !workspaceSubstrateSections(forOrdinal: ordinal).isEmpty
    }

    /// The `type = "workspace"` sections that form the spatial substrate for
    /// `ordinal` — the count + per-workspace layout seed source. Board-
    /// INDEPENDENT (a display-only board switch never reshapes the tiling):
    /// boards present → every board's workspace sections in declaration order;
    /// else the flat `[[desktop.N.section]]` workspace sections. The boards-win
    /// precedence mirrors `activeBoardSections` so the substrate and the
    /// projection agree. With no boards this is byte-identical to the
    /// pre-board flat filter. The shared SSOT for `isSectionModelActive`
    /// (non-empty?) and `effectiveWorkspaceList` (the actual list).
    private func workspaceSubstrateSections(forOrdinal ordinal: Int)
        -> [DesktopSection]
    {
        // W2.6: exclude `unassigned` receptacles — a receptacle now carries a
        // workspace/lens type (the marker, not a `.unassigned` type), but it is
        // NOT a spatial substrate, so it must not seed a workspace or flip the
        // section-model gate.
        if let tabs = effectiveMacDesktopTabConfigs[ordinal], !tabs.isEmpty {
            return tabs.flatMap {
                $0.sections.filter { $0.type == .workspace && !$0.unassigned }
            }
        }
        return (effectiveMacDesktopSectionConfigs[ordinal] ?? [])
            .filter { $0.type == .workspace && !$0.unassigned }
    }

    /// Effective `[[exclude]]` rule set (empty when none configured).
    /// Always read through this, never the raw Optional.
    public var effectiveExclusionRules: ExclusionRules {
        ExclusionRules(exclusionRules ?? [])
    }

    /// Effective `[[rule]]` adopt-rule set (empty when none configured).
    /// Always read through this, never the raw Optional.
    public var effectiveRules: [Rule] { rules ?? [] }

    /// Effective `[[desktop.N.section]]` definitions (the section/lens
    /// model). Always read through this, never the raw dict.
    ///
    /// N1 (boards-win is TOTAL): an ordinal that ALSO has `[[desktop.N.tab]]`
    /// boards has its flat sections SHADOWED here — boards already win in
    /// `activeBoardSections` / `workspaceSubstrateSections`, so a tab-config
    /// ordinal's flat sections are inert and must not surface as a parallel
    /// SSOT. The adapter's id resolver (`lensSection(forID:)`) is now board-
    /// aware (W2.5-adapter — it reads `activeBoardSections`, not this accessor),
    /// so the shadow no longer guards a flat mis-resolve; it stays as the
    /// boards-win invariant (a tab-config ordinal is driven entirely by its
    /// boards). No tabs anywhere ⇒ the raw dict verbatim (byte-identical to the
    /// pre-N1 accessor).
    public var effectiveMacDesktopSectionConfigs: [Int: [DesktopSection]] {
        guard !macDesktopTabConfigs.isEmpty else { return macDesktopSectionConfigs }
        return macDesktopSectionConfigs.filter { macDesktopTabConfigs[$0.key] == nil }
    }

    /// Effective `[[desktop.N.tab]]` definitions (the board model). Always read
    /// through this, never the raw dict.
    public var effectiveMacDesktopTabConfigs: [Int: [DesktopTab]] {
        macDesktopTabConfigs
    }

    /// The section list that drives the overview projection for `ordinal`,
    /// given the session-selected BOARD index (the board model, t-wrd2 / W2.2).
    ///
    /// - With `[[desktop.N.tab]]` boards present, returns the selected board's
    ///   child sections. `board` is CLAMPED into range, so a stale selection
    ///   (e.g. a hot-reload dropped boards) lands on the nearest in-range board
    ///   rather than crashing or blanking the tree.
    /// - With NO boards (every config today, until the W2.5 migration), DEGRADES
    ///   to the flat `[[desktop.N.section]]` list — byte-identical to the
    ///   pre-board path. The board layer is a transparent SELECTOR over the same
    ///   section model `FilterProjection` already consumes, so projecting a
    ///   board's sections equals projecting an equivalent flat config (the W2.2
    ///   byte-一致 invariant).
    /// - `nil` ordinal (SkyLight unavailable / single-desktop) → empty, like the
    ///   flat reads keyed off the ordinal.
    ///
    /// Pure / read-only: never persists, never touches the backend (a board
    /// switch re-groups the SAME windows — display only).
    public func activeBoardSections(forMacDesktopOrdinal ordinal: Int?, board: Int)
        -> [DesktopSection]
    {
        guard let ordinal else { return [] }
        if let tabs = effectiveMacDesktopTabConfigs[ordinal], !tabs.isEmpty {
            let b = max(0, min(board, tabs.count - 1))
            return tabs[b].sections
        }
        return effectiveMacDesktopSectionConfigs[ordinal] ?? []
    }

    /// The selected board's `DesktopTab` for `ordinal` — the handle the focus-mode
    /// re-park (t-c6fm) reads to learn whether the active board is a `type == .lens`
    /// board (lens boards always park). Board index is CLAMPED into range (like
    /// `activeBoardSections`), so a stale selection lands on the nearest board.
    /// `nil` when the ordinal is absent / has no `[[desktop.N.tab]]` boards (a
    /// flat / unconfigured desktop has no board to gate on). Pure / read-only —
    /// the board type it exposes gates the park, a board switch itself moves nothing.
    public func activeBoardTab(forMacDesktopOrdinal ordinal: Int?, board: Int)
        -> DesktopTab?
    {
        guard let ordinal,
              let tabs = effectiveMacDesktopTabConfigs[ordinal], !tabs.isEmpty
        else { return nil }
        return tabs[max(0, min(board, tabs.count - 1))]
    }

    /// One pruned per-board remembered lens (B1, t-1rck) — the payload the
    /// Controller logs when a board's stored `.lens(id)` no longer resolves
    /// after a config reload.
    public struct DroppedBoardLens: Equatable, Sendable {
        public let ordinal: Int
        public let board: Int
        public let id: String
        public init(ordinal: Int, board: Int, id: String) {
            self.ordinal = ordinal
            self.board = board
            self.id = id
        }
    }

    /// Prune a per-board remembered-active-section map after a hot-reload: any
    /// `.lens(id)` whose stable id no longer resolves to a lens section on its
    /// OWN board (`activeBoardSections(forMacDesktopOrdinal:board:)`) is replaced
    /// with `fallback`. Pure — the Controller drives its `boardActiveSection`
    /// sweep through this so a stale lens can't relight as a wrong / missing
    /// highlight when the user switches BACK to a non-active board whose lens the
    /// edited config dropped or reordered (B1, t-1rck). The ACTIVE board's live
    /// `currentActiveSection` is pruned separately by `reloadConfig` (it also
    /// clears the backend's live lens; a non-active board's lens is not live, so
    /// this sweep needs no backend op). Returns the pruned map + the dropped
    /// entries, in a deterministic (ordinal, board)-sorted order so the log and
    /// the unit tests are stable.
    public func prunedBoardActiveSections(
        _ map: [Int: [Int: ActiveSection]],
        fallback: ActiveSection
    ) -> (pruned: [Int: [Int: ActiveSection]], dropped: [DroppedBoardLens]) {
        var pruned = map
        var dropped: [DroppedBoardLens] = []
        for ordinal in map.keys.sorted() {
            for (board, section) in map[ordinal]!.sorted(by: { $0.key < $1.key }) {
                guard case .lens(let id) = section else { continue }
                let sections = activeBoardSections(forMacDesktopOrdinal: ordinal, board: board)
                if ApplyResolver.section(forSectionID: id, in: sections) == nil {
                    pruned[ordinal]?[board] = fallback
                    dropped.append(DroppedBoardLens(ordinal: ordinal, board: board, id: id))
                }
            }
        }
        return (pruned, dropped)
    }

    /// Fatal config errors that should refuse startup (Fail Fast /
    /// Rule of Repair — never silently fall back). Empty = OK to start.
    /// The app entry prints these to stderr and `exit 2`.
    ///
    /// No fatal checks remain (the legacy tag-mode startup checks were
    /// removed in EX-4); kept as a stable seam so the entry point's
    /// `exit 2` path survives a future Fail-Fast addition.
    public func fatalConfigErrors() -> [String] {
        []
    }

    /// Effective `[window] raise-on-open`. Unknown / unset →
    /// `.raise` (the default: surface freshly-opened floating windows
    /// without stealing focus). A typo clamps to the default, like
    /// every other TOML key.
    public var effectiveRaiseOnOpen: RaiseOnOpen {
        RaiseOnOpen(rawValue: (raiseOnOpen ?? "raise").lowercased())
            ?? .raise
    }
}
