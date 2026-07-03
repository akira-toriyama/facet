// FacetConfig decoding & disk I/O — the raw-TOML orchestration layer
// (`from(toml:)` plus the `[[exclude]]` / `[[desktop.N.section]]`
// array-of-tables decoders) and the config-file load path. Extracted
// unchanged from FacetConfig.swift — same-module extension, no logic
// change. The declarative `[block]` schema lives in
// FacetConfig+Spec.swift; the `effective*` accessors stay on the core
// struct, next to the raw fields they clamp.

import Foundation
import Toml

extension FacetConfig {
    // MARK: - Construction from parsed TOML

    /// Build from the FLAT `[section: [key: value]]` map (the literal-
    /// header dict from `Toml.parseFlat`). The uniform `[block]` keys are
    /// driven by the single declarative `configSpec` (which ALSO emits the
    /// JSON Schema — see `FacetConfig+Spec.swift`). The
    /// `[[exclude]]/[[desktop.N.section]]` arrays-of-tables are
    /// filled by `load` from the raw text (they don't live in this flat map).
    public static func from(toml: [String: [String: TOMLValue]])
        -> FacetConfig
    {
        var c = FacetConfig()
        configSpec.decode(toml, into: &c)
        return c
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
            // Drop a blank `[[exclude]]` (no constraints → matches
            // nothing) — same six-field disjunction as the old inline
            // `hasKey`, single-sourced on the matcher.
            return rule.matcher.isConstrained ? rule : nil
        }
    }

    /// Build the per-mac-desktop `[[desktop.N.section]]` map from the raw
    /// TOML text (the section/lens model). Each block header is
    /// `desktop.<N>.section` (`N` = Mission Control ordinal ≥ 1); rows are
    /// `{ type, label, match, apply, layout }`. A row with an absent /
    /// unknown `type`, or one missing a required per-type field, is DROPPED
    /// with a LOUD `Log.line` (the ordinal + row index for context) — never
    /// a silent clamp (see `DesktopSection.parse`). A desktop with no usable
    /// rows contributes no entry. Section order within a desktop is file
    /// order. The decoded sections are consumed in production — read through
    /// `effectiveMacDesktopSectionConfigs`.
    public static func decodeDesktopSectionSections(fromTOML text: String)
        -> [Int: [DesktopSection]]
    {
        decodeDesktopSectionOrigins(fromTOML: text, log: true)
            .mapValues { $0.map(\.section) }
    }

    /// The origin-tracking core of `decodeDesktopSectionSections` (t-hdxb B4).
    /// Produces the SAME per-desktop, merged + deduped section lists, but each
    /// section is wrapped in a `DesktopSectionOrigin` that also carries the RAW
    /// header spelling it came from and its 0-based position among blocks of
    /// that spelling. The snapshot writer replays THIS (never a re-implemented
    /// index) to map a projected section id back to the exact
    /// `[[desktop.N.section]]` array-of-tables element to edit — so the mapping
    /// can never drift from the projection's `declOrder`. `log:` mirrors the
    /// load-path `Log.line` diagnostics (parse notes + dup-label drops); the
    /// writer passes `false` so re-deriving origins on every snapshot is quiet.
    public static func decodeDesktopSectionOrigins(fromTOML text: String,
                                                   log: Bool = true)
        -> [Int: [DesktopSectionOrigin]]
    {
        let blocks = parseTOMLArraysOfTables(text) { name in
            name.hasPrefix("desktop.") && name.hasSuffix(".section")
        }
        struct Pending {
            let section: DesktopSection
            let headerName: String
            let rawOrdinal: Int
        }
        // Iterate header texts in SORTED order and MERGE into the ordinal
        // bucket (not assign): two distinct spellings can normalize to the
        // same ordinal (`desktop.1.section` vs `desktop.01.section`/`+1`,
        // since `Int` accepts zero-pad / leading `+`). Sorting + appending
        // makes the result independent of per-process Dictionary hash-seed
        // order; file order within one spelling is already preserved by the
        // parser. `rawOrdinal` = the row index within THAT spelling's group,
        // which is exactly swift-toml-edit's array-of-tables ordinal for the
        // matching header path.
        var buckets: [Int: [Pending]] = [:]
        for name in blocks.keys.sorted() {
            guard let rows = blocks[name] else { continue }
            // header = "desktop.<N>.section" → pull out N.
            let mid = name.dropFirst("desktop.".count).dropLast(".section".count)
            guard let ordinal = Int(mid), ordinal >= 1 else { continue }
            for (i, row) in rows.enumerated() {
                let (section, note) = DesktopSection.parse(fromTOMLRow: row)
                if log, let note {
                    Log.line("config: [[desktop.\(ordinal).section]] "
                        + "#\(i + 1): \(note)")
                }
                if let section {
                    buckets[ordinal, default: []].append(
                        Pending(section: section, headerName: name, rawOrdinal: i))
                }
            }
        }
        // §A: within one mac desktop a NON-EMPTY label must be unique (it is a
        // stable addressing handle: `facet section --focus "label"`). Duplicates
        // are loud + first-wins — drop the later section so the layout isn't
        // broken; EMPTY labels may repeat freely. Runs AFTER the merge above so
        // two header spellings folding into one ordinal (`desktop.1` vs
        // `desktop.01`) are de-duped together. `declOrder` is assigned over the
        // SURVIVING list — the same index `FilterProjection` mints ids from.
        var out: [Int: [DesktopSectionOrigin]] = [:]
        for ordinal in buckets.keys.sorted() {
            guard let pend = buckets[ordinal] else { continue }
            var seen: Set<String> = []
            var origins: [DesktopSectionOrigin] = []
            for p in pend {
                if !p.section.label.isEmpty, !seen.insert(p.section.label).inserted {
                    if log {
                        Log.line("config: [[desktop.\(ordinal).section]]: duplicate "
                            + "label \"\(p.section.label)\" — keeping first, "
                            + "dropping this section")
                    }
                    continue
                }
                origins.append(DesktopSectionOrigin(
                    section: p.section, declOrder: origins.count,
                    headerName: p.headerName, rawOrdinal: p.rawOrdinal))
            }
            out[ordinal] = origins
        }
        return out
    }

    /// Build the per-mac-desktop `[[desktop.N.tab]]` map from the raw TOML text
    /// (the board model, t-wrd2 — the nesting-aware sibling of
    /// `decodeDesktopSectionSections`). Each tab block is `[[desktop.<N>.tab]]`
    /// (`N` = Mission Control ordinal ≥ 1) with a required `type` of
    /// `workspace` / `lens` (an absent / unknown / `unassigned` tab type DROPS
    /// the whole tab, LOUD) + an optional `label`. Its nested
    /// `[[desktop.N.tab.section]]` children carry NO `type` — each INHERITS the
    /// tab's type, then runs through `DesktopSection.parse` so the per-type
    /// field rules (t-qtpx) re-apply at the inheritance seam. A child marked
    /// `unassigned = true` is the per-tab lost-and-found receptacle — it decodes
    /// to a `.unassigned` section regardless of the parent type; at most one per
    /// tab (a 2nd is dropped, LOUD). Tab + section order is file order. ADDITIVE
    /// / no consumer yet — read through `effectiveMacDesktopTabConfigs`. Disjoint
    /// from `decodeDesktopSectionSections` (the two read different headers).
    public static func decodeDesktopTabs(fromTOML text: String)
        -> [Int: [DesktopTab]]
    {
        var out: [Int: [DesktopTab]] = [:]
        let grouped = parseTOMLNestedTabs(text)
        for ordinal in grouped.keys.sorted() {
            guard let rawTabs = grouped[ordinal] else { continue }
            var tabs: [DesktopTab] = []
            for (ti, raw) in rawTabs.enumerated() {
                // A tab's `type` is REQUIRED and may only be workspace / lens —
                // an absent / unknown / `unassigned` one DROPS the whole tab
                // (LOUD), never a silent clamp (it would mis-route every child).
                guard case .string(let rawType)? = raw.tab["type"],
                      let parentType = SectionType(rawValue: rawType.lowercased()),
                      parentType == .workspace || parentType == .lens
                else {
                    Log.line("config: [[desktop.\(ordinal).tab]] #\(ti + 1): "
                        + "missing / invalid `type` (expected workspace / lens) "
                        + "— dropping tab")
                    continue
                }
                let label: String = {
                    if case .string(let s)? = raw.tab["label"] { return s }
                    return ""
                }()
                // Each child INHERITS the parent type (children carry no `type`)
                // — the inherited type is injected into the row so
                // `DesktopSection.parse` re-applies the per-type field rules
                // (t-qtpx) at the seam. A child marked `unassigned = true` is the
                // per-tab lost-and-found receptacle (W2.6): it STILL inherits the
                // parent type (the preserved `unassigned` key drives `parse`'s
                // marker branch), and at most one per tab is honoured (a 2nd is
                // dropped LOUD).
                var sections: [DesktopSection] = []
                var sawUnassigned = false
                for (si, childRow) in raw.sections.enumerated() {
                    var injected = childRow
                    injected["type"] = .string(parentType.rawValue)
                    if case .bool(true)? = childRow["unassigned"] {
                        if sawUnassigned {
                            Log.line("config: [[desktop.\(ordinal).tab.section]] "
                                + "#\(si + 1): a tab may have at most one "
                                + "`unassigned = true` section — dropping this one")
                            continue
                        }
                        sawUnassigned = true
                    }
                    let (section, note) = DesktopSection.parse(fromTOMLRow: injected)
                    if let note {
                        Log.line("config: [[desktop.\(ordinal).tab.section]] "
                            + "#\(si + 1): \(note)")
                    }
                    if let section { sections.append(section) }
                }
                // §A: within ONE tab a non-empty section label must be unique
                // (its addressing handle) — first-wins, loud. Empty labels repeat.
                sections = dedupByLabel(sections, label: \.label) { s in
                    Log.line("config: [[desktop.\(ordinal).tab.section]]: duplicate "
                        + "label \"\(s.label)\" — keeping first, dropping this section")
                }
                tabs.append(DesktopTab(type: parentType, label: label,
                                       sections: sections))
            }
            // §A: within ONE mac desktop a non-empty tab label must be unique
            // (the `facet board --focus "label"` handle) — first-wins, loud.
            tabs = dedupByLabel(tabs, label: \.label) { t in
                Log.line("config: [[desktop.\(ordinal).tab]]: duplicate label "
                    + "\"\(t.label)\" — keeping first, dropping this tab")
            }
            if !tabs.isEmpty { out[ordinal] = tabs }
        }
        return out
    }

    /// Drop later entries whose NON-EMPTY label repeats (first-wins, loud);
    /// empty labels may repeat. The §A uniqueness rule, reused for both tabs
    /// (unique per mac desktop) and a tab's sections (unique per tab).
    private static func dedupByLabel<T>(
        _ items: [T], label: (T) -> String, onDrop: (T) -> Void
    ) -> [T] {
        var seen: Set<String> = []
        var kept: [T] = []
        for item in items {
            let l = label(item)
            if !l.isEmpty, !seen.insert(l).inserted { onDrop(item); continue }
            kept.append(item)
        }
        return kept
    }

    /// Build `[Rule]` from the raw TOML text's `[[rule]]` array-of-tables
    /// (the Phase 3 adopt-rules — #282/#286). Each table: `match` (a facet
    /// filter WHERE-clause string) + the FLAT apply keys (`workspace` /
    /// `tags` / `floating` / `sticky` / `master`) read by the shared
    /// `ApplyOp.list` over the whole row (it ignores `match` + any unknown
    /// key, in canonical op order). A table missing `match` / with a blank
    /// `match`, or whose flat keys yield no usable `apply` op (it would adopt
    /// nothing), is DROPPED — a bad rule never breaks the others. The `match`
    /// GRAMMAR is NOT validated here (parse-only stays total); the consumer
    /// compiles it loud + non-fatal at eval time, like a `type="lens"` match.
    public static func decodeRuleSections(fromTOML text: String) -> [Rule] {
        parseTOMLArrayOfTables(text, table: "rule").compactMap { t in
            guard case .string(let match)? = t["match"],
                  !match.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let apply = ApplyOp.list(from: .table(t))
            return apply.isEmpty ? nil : Rule(match: match, apply: apply)
        }
    }

    // MARK: - Disk

    public static var defaultPath: String {
        let h = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return "\(h)/.config/facet/config.toml"
    }

    /// Read config from `path`. Returns default-init'd config if
    /// the file is missing or unreadable. Read-only by design: the
    /// app never writes to the user's config file. Repo root
    /// `config.toml` is the install template; users `curl` it
    /// into place themselves (see README). (The ONE sanctioned write
    /// to config.toml — startup `auto-promote` — lives in the separate
    /// `bootstrapWithAutoPromote`, never here.)
    public static func load(path: String = defaultPath) -> FacetConfig {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .init() }
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            return load(source: text)
        }
        FileHandle.standardError.write(Data(
            "facet: could not read \(path)\n".utf8))
        return .init()
    }

    /// Startup config load WITH auto-promote (t-hdxb). Behaves exactly like
    /// `load(path:)`, EXCEPT: when the user opted into `[config] auto-promote`
    /// AND a newer `[config] export-path` snapshot exists, that snapshot is
    /// PROMOTED — it overwrites config.toml (the one sanctioned write to the
    /// user's config file, carved out of the "never writes" rule) and is then
    /// loaded. Guards:
    ///   • **Staleness**: the snapshot only wins when its mtime is STRICTLY
    ///     newer than config.toml, so a hand-edit between sessions always
    ///     wins. After promotion config.toml is newer, so the same snapshot
    ///     never promotes twice (no sentinel needed).
    ///   • **Self-write**: a snapshot path equal to config.toml is refused
    ///     (that would be an in-place write loop, forbidden by design).
    ///   • **Fail-soft**: any read/write I/O error falls back to the
    ///     un-promoted config; an unreadable snapshot mtime is fail-CLOSED
    ///     (no promotion).
    /// Promotion happens ONLY here (startup) — never in `reloadConfig`, the
    /// config watcher, or `config --validate/--emit-schema`, which is why this
    /// is a separate entry point from `load`.
    public static func bootstrapWithAutoPromote(path: String = defaultPath)
        -> FacetConfig
    {
        let fresh = load(path: path)           // read #1 — learns the [config] keys
        guard fresh.effectiveAutoPromote,
              let rawExport = fresh.effectiveExportPath else { return fresh }
        let baseDir = (path as NSString).deletingLastPathComponent
        let snapshotPath = resolvePath(rawExport, relativeTo: baseDir)
        guard snapshotPath != path else {
            Log.line("config: [config] export-path must differ from config.toml "
                + "— auto-promote skipped")
            return fresh
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshotPath) else { return fresh }
        // mtime gate — snapshot must be strictly newer. Unreadable snapshot
        // mtime is fail-CLOSED (don't promote); a missing config mtime counts
        // as ancient so a present snapshot wins.
        guard let snapMTime = fileModificationDate(snapshotPath) else { return fresh }
        let configMTime = fileModificationDate(path) ?? .distantPast
        guard snapMTime > configMTime else { return fresh }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        else { return fresh }                  // fail-soft on unreadable snapshot
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            Log.line("config: auto-promote could not write \(path): \(error)")
            return fresh                       // fail-soft on unwritable config
        }
        Log.debug("config: auto-promoted \(snapshotPath) → \(path)")
        return load(path: path)                // read #2 — the promoted config
    }

    /// Modification date of a file, or nil if unavailable (missing / unreadable
    /// attributes). Used by the auto-promote mtime gate.
    private static func fileModificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date
    }

    /// Build a `FacetConfig` from config.toml SOURCE TEXT — the pure
    /// text→config half of `load(path:)`, factored out so a caller that
    /// already holds the source (e.g. `facet config --validate`, which reads
    /// the file itself to tell a missing file from an unreadable one) needn't
    /// re-read the same bytes off disk. No disk I/O; an empty string yields a
    /// default-init config (the missing-file case).
    public static func load(source text: String) -> FacetConfig {
        var c = FacetConfig.from(toml: parseTOMLSubset(text))
        let rules = exclusionRules(fromTOML: text)
        if !rules.isEmpty { c.exclusionRules = rules }
        let sections = decodeDesktopSectionSections(fromTOML: text)
        if !sections.isEmpty { c.macDesktopSectionConfigs = sections }
        let tabs = decodeDesktopTabs(fromTOML: text)
        if !tabs.isEmpty { c.macDesktopTabConfigs = tabs }
        // N1: a desktop declaring BOTH `[[desktop.N.section]]` and
        // `[[desktop.N.tab]]` is ambiguous — boards win and the flat
        // sections are shadowed (see `effectiveMacDesktopSectionConfigs`).
        // Warn loudly once so the dropped flat block isn't a silent
        // surprise (it would otherwise look configured but never render).
        for ordinal in tabs.keys.sorted() where sections[ordinal] != nil {
            Log.line("config: desktop \(ordinal) declares both "
                + "[[desktop.\(ordinal).section]] and [[desktop.\(ordinal).tab]]"
                + " — boards win; the flat section block is ignored")
        }
        let adoptRules = decodeRuleSections(fromTOML: text)
        if !adoptRules.isEmpty { c.rules = adoptRules }
        return c
    }
}
