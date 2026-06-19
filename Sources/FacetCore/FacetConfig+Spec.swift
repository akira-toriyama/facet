// FacetConfig+Spec — the ONE declarative description of facet's
// `config.toml` surface. sill's `ConfigSchema.Spec` turns this single
// source into BOTH:
//
//   • the decode (`FacetConfig.from(toml:)` → `configSpec.decode`)
//   • the JSON Schema (`facet --emit-schema`) taplo uses for editor
//     completion + validation
//
// so a key can never be in the parser but missing from the schema (or
// vice-versa). The `apply` closures reproduce the old hand-written reads
// EXACTLY (same `Toml.Value` accessor, write-only-when-present), so the
// resolved config is byte-identical — see FacetCoreTests.
//
// Enum DOMAINS come from the single sources of truth: sill's
// `canonical*Names` (theme / effect / pet) and facet's own enums
// (`RailEdge`, `RaiseOnOpen`). Numeric `min`/`max` mirror the clamps in
// the `effective*` accessors (advisory in the editor; the app still
// clamps at runtime so a typo can't break the layout).
//
// NOT decoded here (facet parses these from the raw TOML text itself —
// they're non-uniform): the `[[exclude]]` / `[[tag]]` /
// `[[desktop.N.section]]` arrays-of-tables. The spec still DESCRIBES them
// so completion covers them.

import CoreGraphics
import ConfigSchema
import Foundation
import Palette
import Toml

// Per-view theme keys (`[tree]/[grid]/[rail].theme`) accept any catalog
// theme OR `""` (= inherit `[theme].name`). Including `""` in the enum
// keeps taplo from flagging the common inherit sentinel.
private let perViewThemeDomain = canonicalThemeNames + [""]

public extension FacetConfig {

    /// The single declarative spec. Drives `from(toml:)` and
    /// `--emit-schema`. Sections mirror the `[blocks]` in `config.toml`.
    /// Computed (not a stored `let`) so it needn't be `Sendable` — the
    /// `apply` closures capture keypaths; rebuilding ~80 small fields on
    /// the rare config (re)load is free.
    static var configSpec: ConfigSchema.Spec<FacetConfig> {
        ConfigSchema.Spec<FacetConfig>(
        title: "facet config.toml",
        sections: [
            // Top-level (`""` scope) — the one bare key.
            .init("", fields: [
                .str("default-view", \.defaultView, enum: ["tree", "grid"],
                     doc: "Panel shown at launch; unset = agent-only (no panel)."),
            ]),

            .init("theme", doc: "App-default palette.", fields: [
                .str("name", \.theme, enum: canonicalThemeNames, default: "terminal",
                     doc: "Theme name (sill catalog); `random` picks one per launch."),
                .int("color-cycle-ms", \.themeColorCycleMs, min: 1000, max: 120000,
                     doc: "Accent-rotation period for animated themes (ms). Unset = static."),
            ]),

            .init("grouping", fields: [
                .str("by", \.grouping, enum: ["workspace", "tag"], default: "workspace",
                     doc: "Window grouping paradigm."),
            ]),

            .init("window", fields: [
                .str("raise-on-open", \.raiseOnOpen,
                     enum: RaiseOnOpen.allCases.map(\.rawValue), default: "raise",
                     doc: "How a freshly-opened floating window is surfaced."),
            ]),

            .init("grid", fields: [
                .int("cols", \.gridCols, min: 1, max: 12, default: 4),
                .str("label-position", \.gridLabelPosition, enum: ["up", "down"],
                     default: "up"),
                .int("thumbnail-refresh-seconds", \.thumbnailRefreshSeconds,
                     min: 0, max: 60, default: 4,
                     doc: "Background thumbnail capture interval; 0 disables."),
                .str("theme", \.gridTheme, enum: perViewThemeDomain, default: "",
                     doc: "Per-view theme; `\"\"` inherits `[theme].name`."),
            ]),

            .init("rail", fields: [
                .str("edge", \.railEdge, enum: RailEdge.allCases.map(\.rawValue),
                     default: "bottom", doc: "Screen edge the rail docks against."),
                .int("cells", \.railCells, min: 1, max: 20, default: 7,
                     doc: "Max strip cells shown at once."),
                .int("strip", \.railStrip, min: 8, max: 50, default: 30,
                     doc: "Strip band size, % of the short screen edge."),
                .str("theme", \.railTheme, enum: perViewThemeDomain, default: "",
                     doc: "Per-view theme; `\"\"` inherits `[theme].name`."),
            ]),

            .init("tree", fields: [
                .str("preview-mode", \.treePreviewMode, enum: ["popover", "mirror"],
                     default: "popover", doc: "How the hover preview is sized/placed."),
                .str("theme", \.treeTheme, enum: perViewThemeDomain, default: "",
                     doc: "Per-view theme; `\"\"` inherits `[theme].name`."),
                .int("pos-x", \.treePosX, doc: "Panel seed X (top-left origin, px). All four needed."),
                .int("pos-y", \.treePosY, doc: "Panel seed Y (top-left origin, px)."),
                .int("width", \.treeWidth, doc: "Panel seed width (px)."),
                .int("height", \.treeHeight, doc: "Panel seed height (px)."),
                .strArray("line-pets", \.treeLinePets, item: canonicalLinePetNames,
                          doc: "Arcade pets walking the panel border; `[]` = off."),
                .dbl("pet-scale", \.treePetScale, min: 0.1, default: 0.9,
                     doc: "Pet size multiplier."),
                .dbl("pet-lap-seconds", \.treePetLapSeconds, min: 0.5, default: 8,
                     doc: "Seconds for a pet to circle a row once."),
            ]),

            .init("layout", fields: [
                // No enum: registered layout-engine names are dynamic, so a
                // strict enum would false-flag a valid engine.
                .str("default", \.defaultLayout, default: "float",
                     doc: "Startup layout: float | bsp | stack | a registered engine."),
                .cgInt("inner-gap", \.innerGap, min: 0, max: 1000, default: 0,
                       doc: "Gap between adjacent tiled windows (px)."),
                .cgInt("outer-gap", \.outerGap, min: 0, max: 1000, default: 0,
                       doc: "Inset from screen edges (px); per-edge keys override."),
                .cgInt("outer-gap-top", \.outerGapTop, min: 0, max: 1000),
                .cgInt("outer-gap-bottom", \.outerGapBottom, min: 0, max: 1000),
                .cgInt("outer-gap-left", \.outerGapLeft, min: 0, max: 1000),
                .cgInt("outer-gap-right", \.outerGapRight, min: 0, max: 1000),
                .bool("smart-gaps", \.smartGaps, default: false,
                      doc: "Drop the outer gap for a lone tiled window."),
            ]),

            .init("animation", fields: [
                .bool("enabled", \.animationsEnabled, default: false,
                      doc: "Animate window-geometry transitions (opt-in)."),
                .int("duration-ms", \.animationDurationMs, min: 80, max: 800,
                     doc: "Slide duration (ms). Unset = per-curve default."),
                .str("curve", \.animationCurve,
                     enum: ["cubic", "spring", "silky", "snappy", "random"],
                     default: "cubic", doc: "Easing curve."),
                .bool("event-driven", \.animationEventDriven, default: true,
                      doc: "Also animate window open/close reflow."),
            ]),

            .init("border", doc: "Tree-panel border effect.", fields: [
                .str("effect", \.borderEffect, enum: canonicalEffectNames, default: "off"),
                .bool("glow", \.borderGlow, default: true, doc: "Neon bloom under the stroke."),
                .cgDbl("width", \.borderWidth, min: 0.5, max: 30, default: 1.5),
                .int("color-cycle-ms", \.borderColorCycleMs, min: 1000, max: 120000,
                     doc: "Border animation period (ms)."),
                .cgDbl("min-width", \.borderMinWidth, min: 0.5, max: 30,
                     doc: "Width-breathing floor (set with max-width)."),
                .cgDbl("max-width", \.borderMaxWidth, min: 0.5, max: 30,
                     doc: "Width-breathing ceil."),
            ]),

            // ── Schema-only below (facet decodes these from raw text) ──

            .init("exclude", kind: .arrayOfTables,
                  doc: "Windows matching a rule are floated/ignored, not tiled.",
                  fields: [
                .descOnly("app", doc: "App-name regex (substring unless anchored)."),
                .descOnly("title", doc: "Title regex."),
                .descOnly("role", doc: "AX role (exact)."),
                .descOnly("subrole", doc: "AX subrole (exact)."),
                .descOnly("max-width", .integer),
                .descOnly("max-height", .integer),
                .descOnly("action", enum: ["float", "ignore", "manage"],
                          default: .string("float")),
            ]),

            .init("tag", kind: .arrayOfTables, doc: "Declared tag names (M11-3).",
                  fields: [
                .descOnly("name", doc: "Tag name (required)."),
            ]),

            .init("desktop", kind: .dynamicTable,
                  doc: "`[[desktop.N.section]]` ordered per-mac-desktop display "
                     + "sections (N = Mission Control ordinal; LIVE under "
                     + "[grouping] by = \"workspace\") — the sole way to "
                     + "configure a mac desktop. Each has a required `type` of "
                     + "workspace / lens / unassigned: workspace = "
                     + "`{ type, layout }` (auto-named spatial cell — workspaces "
                     + "are not named from config); lens = "
                     + "`{ type, label, match, apply }` where match = a facet "
                     + "filter WHERE-clause and apply = "
                     + "`{ workspace, tags = [], floating, sticky, master }` "
                     + "set on a window routed in; unassigned = "
                     + "`{ type, label }`. Array order = tree display order. "
                     + "Any section block makes facet opt-in (manages only "
                     + "configured desktops). Workspace-axis only (ignored "
                     + "under [grouping] by = \"tag\")."),
        ]
        )
    }

    // MARK: - JSON Schema (taplo) — emitted from the SAME `configSpec`

    /// The `config.toml` JSON Schema (Draft-07). Drives `facet
    /// --emit-schema` and the sidecar install — generated from the one
    /// `configSpec`, so it can never drift from the decode.
    static var jsonSchema: String { configSpec.jsonSchema() }

    /// Where the schema sidecar lives — next to the user config, so a
    /// `#:schema ./config.schema.json` directive resolves on the user's
    /// machine (taplo reads it relative to the .toml's own directory).
    static var schemaPath: String {
        (defaultPath as NSString).deletingLastPathComponent
            + "/config.schema.json"
    }

    /// Write the schema next to the user config. IDEMPOTENT (writes only
    /// when the content differs) so it never churns the file or trips the
    /// watcher (which watches `config.toml`, not this sibling). Creates
    /// `~/.config/facet/` if absent. Best-effort: a failure is non-fatal
    /// (completion just won't resolve), so the daemon never fails to
    /// start over it. Returns true if it actually wrote.
    @discardableResult
    static func installSchema() -> Bool {
        let path = schemaPath
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let want = jsonSchema
        if let current = try? String(contentsOfFile: path, encoding: .utf8),
           current == want {
            return false
        }
        return (try? want.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}

// MARK: - Field builders (keypath + Toml accessor → declarative field)

private extension ConfigSchema.Field where Root == FacetConfig {
    static func str(_ key: String, _ kp: WritableKeyPath<FacetConfig, String?>,
                    enum domain: [String]? = nil, default def: String? = nil,
                    doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in if let s = v.asString { c[keyPath: kp] = s } },
              domain: domain, def: def.map { .string($0) }, doc: doc)
    }
    static func int(_ key: String, _ kp: WritableKeyPath<FacetConfig, Int?>,
                    min lo: Double? = nil, max hi: Double? = nil,
                    default def: Int? = nil, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.integer),
              apply: { c, v in if let n = v.asInt { c[keyPath: kp] = n } },
              def: def.map { .int($0) }, min: lo, max: hi, doc: doc)
    }
    static func dbl(_ key: String, _ kp: WritableKeyPath<FacetConfig, Double?>,
                    min lo: Double? = nil, max hi: Double? = nil,
                    default def: Double? = nil, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.number),
              apply: { c, v in if let d = v.asDouble { c[keyPath: kp] = d } },
              def: def.map { .number($0) }, min: lo, max: hi, doc: doc)
    }
    static func bool(_ key: String, _ kp: WritableKeyPath<FacetConfig, Bool?>,
                     default def: Bool? = nil, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.boolean),
              apply: { c, v in if let b = v.asBool { c[keyPath: kp] = b } },
              def: def.map { .bool($0) }, doc: doc)
    }
    /// Integer in TOML → `CGFloat` field (the px-gap pattern).
    static func cgInt(_ key: String, _ kp: WritableKeyPath<FacetConfig, CGFloat?>,
                      min lo: Double? = nil, max hi: Double? = nil,
                      default def: Int? = nil, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.integer),
              apply: { c, v in if let n = v.asInt { c[keyPath: kp] = CGFloat(n) } },
              def: def.map { .int($0) }, min: lo, max: hi, doc: doc)
    }
    /// Number in TOML → `CGFloat` field (`border.width` accepts `2` or `1.5`).
    static func cgDbl(_ key: String, _ kp: WritableKeyPath<FacetConfig, CGFloat?>,
                      min lo: Double? = nil, max hi: Double? = nil,
                      default def: Double? = nil, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.number),
              apply: { c, v in if let d = v.asDouble { c[keyPath: kp] = CGFloat(d) } },
              def: def.map { .number($0) }, min: lo, max: hi, doc: doc)
    }
    static func strArray(_ key: String, _ kp: WritableKeyPath<FacetConfig, [String]?>,
                         item: [String]? = nil, doc: String? = nil) -> Self {
        .init(key: key, kind: .stringArray(item: item),
              apply: { c, v in if let a = v.asStringArray { c[keyPath: kp] = a } },
              doc: doc)
    }
    /// Schema-only scalar for an `[[array-of-tables]]` row (no decode —
    /// facet parses those from raw text); a no-op `apply`.
    static func descOnly(_ key: String, _ scalar: ConfigSchema.Scalar = .string,
                         enum domain: [String]? = nil,
                         default def: ConfigSchema.DefaultValue? = nil,
                         doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(scalar), apply: { _, _ in },
              domain: domain, def: def, doc: doc)
    }
}
