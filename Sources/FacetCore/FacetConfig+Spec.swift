// FacetConfig+Spec — the ONE declarative description of facet's
// `config.toml` surface. sill's `ConfigSchema.Spec` turns this single
// source into ALL THREE:
//
//   • the decode (`FacetConfig.from(toml:)` → `configSpec.decode`)
//   • the JSON Schema (`facet config --emit-schema`) taplo uses for editor
//     completion + validation
//   • runtime validation (`facet config --validate` → `configSpec.validate`,
//     sill 1.29.0 bridge — see FacetConfig+Validate.swift)
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
// they're non-uniform): the `[[exclude]]` / `[[desktop.N.section]]`
// arrays-of-tables. The spec still DESCRIBES them so completion covers
// them.

import CoreGraphics
import ConfigSchema
import Foundation
import Palette
import Toml

// Per-view theme keys (`[tree]/[grid]/[rail].theme`) accept any catalog
// theme OR `""` (= inherit `[theme].name`). Including `""` in the enum
// keeps taplo from flagging the common inherit sentinel.
private let perViewThemeDomain = canonicalThemeNames + [""]

// The typed value shape for `[desktop.<N>]` ordinal keys — the open-map the
// bare `.dynamicTable` couldn't express (t-kz0m). Hand-built at the DESCRIPTOR
// layer (ObjectShape / NestedTable / NestedObject / SchemaField) rather than a
// new authoring builder, per t-0avb B1. Canonical spec: t-0avb「値 shape の確定形」.
// `permissive` defaults false → `additionalProperties: false`, so taplo AND the
// runtime validator reject typo'd keys / non-ordinal `[desktop.foo]`. The
// per-type conditionals are deferred to `DesktopMeta.parse`, the enforcement
// authority (t-0avb B5, retargeted by t-ec9s when `type` moved onto the
// desktop): the shared `valueShape` below declares `match` / `layout` /
// `show-non-matching` for BOTH types — a schema can't say "lens REQUIRES
// `match`, workspace IGNORES it" — so `parse` drops a `match`-less lens LOUD
// and logs-then-ignores those keys on a workspace desktop.
private enum DesktopSchema {
    // One `[[desktop.N.section]]` row — a workspace SPATIAL cell (t-ec9s: the
    // section-lens type was retired; `lens` is now only a `[desktop.N]` type).
    // `additionalProperties: false` (the permissive default is off), so a stray
    // `type` / `match` / `apply` from the retired section-lens era fails
    // `config --validate` loudly.
    static var sectionItemShape: ObjectShape {
        ObjectShape(fields: [
            SchemaField("label", .string, doc: "Display name; unset shows the section's 1-based index."),
            SchemaField("layout", .string, doc: "Layout-engine name for this workspace cell."),
            // `unassigned` was RETIRED (t-6rbc). Dropping the field makes
            // `additionalProperties: false` report a stale one as an unknown key —
            // belt to the decode diagnostic's braces, which names it as retired
            // and DROPS the row (so it can't silently become a workspace cell).
        ], doc: "One workspace spatial cell.")
    }

    // The value each `[desktop.<N>]` ordinal key maps to. A SINGLE typed table
    // (t-0sbm): `type`/`label` (+ lens-only `match`/`layout`/
    // `show-non-matching`) directly on the desktop. A `workspace` desktop
    // carries its `[[desktop.N.section]]` array.
    static var valueShape: ObjectShape {
        ObjectShape(fields: [
            SchemaField("type", .string,
                        doc: "workspace = spatial sections you file windows into (tree/grid/rail); isolate = membership comes from `match`: facet tiles the matched windows with `layout` and ANCHOR-PARKS the rest, for as long as you are on that desktop (tree only).",
                        enumDomain: DesktopType.allCases.map(\.rawValue)),
            SchemaField("label", .string, doc: "Display name for this mac desktop."),
            SchemaField("match", .string, doc: "isolate desktop only — a facet-filter WHERE-clause selecting the tiled windows. Everything it does not select is anchor-parked off-screen."),
            SchemaField("layout", .string, doc: "isolate desktop only — layout-engine name for the matched windows."),
            SchemaField("show-non-matching", .boolean, doc: "isolate desktop only — also show the parked non-matching windows as a second tree section (the `holding` section). They are parked either way; this only decides whether the tree lists them."),
        ], nested: [
            NestedTable(key: "section", item: sectionItemShape),
        ], doc: "One mac desktop (N = Mission Control ordinal): its `type`/`label`, plus its display sections.")
    }
}

public extension FacetConfig {

    /// The single declarative spec. Drives `from(toml:)`,
    /// `config --emit-schema`, and `config --validate`. Sections mirror the
    /// `[blocks]` in `config.toml`.
    /// Computed (not a stored `let`) so it needn't be `Sendable` — the
    /// `apply` closures capture keypaths; rebuilding ~80 small fields on
    /// the rare config (re)load is free.
    static var configSpec: ConfigSchema.Spec<FacetConfig> {
        ConfigSchema.Spec<FacetConfig>(
        title: "facet config.toml",
        sections: [
            .init("theme", doc: "App-default palette.", fields: [
                .str("name", \.theme, enum: canonicalThemeNames, default: "terminal",
                     doc: "Theme name (sill catalog); `random` picks one per launch."),
                .int("color-cycle-ms", \.themeColorCycleMs, min: 1000, max: 120000,
                     doc: "Accent-rotation period for animated themes (ms). Unset = static."),
            ]),

            .init("window", fields: [
                .str("raise-on-open", \.raiseOnOpen,
                     enum: RaiseOnOpen.allCases.map(\.rawValue),
                     enumDocs: [  // index-aligned to RaiseOnOpen.allCases (raise/activate/off)
                        "Lift the float to the front of its own app, without stealing focus (default).",
                        "Bring the owning app frontmost on every fresh float (steals focus each time).",
                        "Do nothing — leave the float where the app placed it.",
                     ],
                     default: "raise",
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
                     enumDocs: [  // index-aligned to RailEdge.allCases (top/bottom/left/right)
                        "Dock the rail against the top edge (horizontal strip).",
                        "Dock against the bottom edge (horizontal strip; default).",
                        "Dock against the left edge (vertical strip).",
                        "Dock against the right edge (vertical strip).",
                     ],
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
                     enumDocs: [
                        "Show the preview next to the source row (default).",
                        "Show the preview at the window's own on-screen frame.",
                     ],
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

            .init("config", doc: "Config auto-persistence (session edits → "
                + "config.toml, no UI). See CLAUDE.md `### Configuration`.",
                  fields: [
                .str("export-path", \.exportPath,
                     doc: "Auto-export snapshot target. Set = ON: every session "
                        + "edit (rename / isolate match / layout / tag vocab) writes "
                        + "the full effective config here, surgically — config.toml "
                        + "is left untouched. MUST be a different file from "
                        + "config.toml. `~` and config-dir-relative paths resolve."),
                .bool("auto-promote", \.autoPromote, default: false,
                      doc: "Promote a NEWER snapshot onto config.toml at startup "
                         + "(overwrite + load) — the one sanctioned write to your "
                         + "config file. A hand-edit between sessions still wins "
                         + "(mtime guard). Off by default."),
            ]),

            .init("tags", doc: "Tag vocabulary (names only — colors are runtime).",
                  fields: [
                .strArray("defined", \.definedTags,
                          doc: "Tag names offered in the tag editor before any "
                             + "window uses them (`[]` = none). Grown by "
                             + "auto-export as you create tags."),
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
                .descOnly("action", enum: ExclusionAction.allCases.map(\.rawValue),
                          enumDocs: [  // index-aligned to ExclusionAction.allCases (float/ignore/manage)
                            "Float it: still tracked + shown in the tree, just not tiled (default).",
                            "Drop it entirely: never enters a workspace, never shown.",
                            "Force-tile it even though the allowlist would otherwise float/ignore it.",
                          ],
                          default: .string("float")),
            ]),

            .init("rule", kind: .arrayOfTables,
                  doc: "Adopt-rules (#282 Phase 3): a NEW window matching "
                     + "`match` (a facet filter WHERE-clause) gets these facets "
                     + "set on creation — the declarative successor to the "
                     + "retired `[[assign]]`. The keys after `match` are the "
                     + "section `apply` vocabulary, flat here.",
                  fields: [
                .descOnly("match",
                          doc: "facet filter WHERE-clause selecting the windows "
                             + "to adopt (e.g. `app=Safari and not floating`)."),
                .descOnly("workspace",
                          doc: "Move a matched window to this named workspace."),
                .descArray("tags", doc: "Tags to add to a matched window."),
                .descOnly("floating", .boolean,
                          doc: "Force a matched window floating (or tiled = false)."),
                .descOnly("sticky", .boolean,
                          doc: "Pin a matched window across mac-desktop / workspace switches."),
                .descOnly("master", .boolean,
                          doc: "Make a matched window the layout master."),
            ]),

            .init("desktop", kind: .dynamicTable,
                  doc: "`[desktop.N]` configures one mac desktop (N = Mission "
                     + "Control ordinal) — a SINGLE TYPED table: `type` is "
                     + "workspace / isolate (omitted = workspace). A `workspace` "
                     + "desktop carries ordered `[[desktop.N.section]]` rows; "
                     + "array order = tree display order. Each row is a "
                     + "workspace SPATIAL cell `{ label, layout }` — an optional "
                     + "`label` names it, else it shows its 1-based index; "
                     + "membership changes via DnD / `facet window --move-to N` "
                     + "(sections have NO `type` / `match` / `apply` — a stray "
                     + "one fails --validate). EVERY row is a workspace cell — "
                     + "the `unassigned = true` lost-and-found MARKER was retired "
                     + "(t-6rbc: nothing could put a window in it, so it could "
                     + "only ever be an empty section). An `isolate` desktop writes "
                     + "`match` (REQUIRED — a facet-filter WHERE-clause) plus "
                     + "`layout` / `show-non-matching` / `label` directly on the "
                     + "`[desktop.N]` table and declares NO sections: while that "
                     + "mac desktop is active facet ALWAYS tiles the matched "
                     + "windows with `layout` and anchor-parks the rest. An isolate "
                     + "desktop is TREE-ONLY (`--view grid` / `--view rail` "
                     + "loud-reject there). Any `[desktop.N]` or "
                     + "`[[desktop.N.section]]` block makes facet opt-in — it "
                     + "then manages ONLY the configured mac desktops.",
                  // Typed open-map: each ordinal key maps to a
                  // `{ …scalars, section[] }` value (t-kz0m). keyPattern mirrors the runtime
                  // `Int(mid) >= 1` guard (FacetConfig+Decode.swift) — accepts
                  // `1`/`01`/`10`, rejects `0`/`00`/`foo` (t-0avb B2).
                  dynamicValue: DynamicValue(keyPattern: "^0*[1-9][0-9]*$",
                                             shape: DesktopSchema.valueShape)),
        ]
        )
    }

    // MARK: - JSON Schema (taplo) — emitted from the SAME `configSpec`

    /// The `config.toml` JSON Schema (Draft-07). Drives `facet config
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
                    enum domain: [String]? = nil, enumDocs: [String?]? = nil,
                    default def: String? = nil, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in if let s = v.asString { c[keyPath: kp] = s } },
              domain: domain, enumDocs: enumDocs, def: def.map { .string($0) }, doc: doc)
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
                         enum domain: [String]? = nil, enumDocs: [String?]? = nil,
                         default def: ConfigSchema.DefaultValue? = nil,
                         doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(scalar), apply: { _, _ in },
              domain: domain, enumDocs: enumDocs, def: def, doc: doc)
    }
    /// Schema-only string-array for an `[[array-of-tables]]` row (no decode —
    /// facet parses those from raw text); a no-op `apply`. The array sibling
    /// of `descOnly` (e.g. `[[rule]]`'s `tags`).
    static func descArray(_ key: String, item: [String]? = nil,
                          doc: String? = nil) -> Self {
        .init(key: key, kind: .stringArray(item: item), apply: { _, _ in },
              doc: doc)
    }
}
