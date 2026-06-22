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
        var out: [Int: [DesktopSection]] = [:]
        let blocks = parseTOMLArraysOfTables(text) { name in
            name.hasPrefix("desktop.") && name.hasSuffix(".section")
        }
        // Iterate header texts in SORTED order and MERGE into the ordinal
        // bucket (not assign): two distinct spellings can normalize to the
        // same ordinal (`desktop.1.section` vs `desktop.01.section`/`+1`,
        // since `Int` accepts zero-pad / leading `+`). Sorting + appending
        // makes the result independent of per-process Dictionary hash-seed
        // order; file order within one spelling is already preserved by the
        // parser.
        for name in blocks.keys.sorted() {
            guard let rows = blocks[name] else { continue }
            // header = "desktop.<N>.section" → pull out N.
            let mid = name.dropFirst("desktop.".count).dropLast(".section".count)
            guard let ordinal = Int(mid), ordinal >= 1 else { continue }
            var sections: [DesktopSection] = []
            for (i, row) in rows.enumerated() {
                let (section, note) = DesktopSection.parse(fromTOMLRow: row)
                if let note {
                    Log.line("config: [[desktop.\(ordinal).section]] "
                        + "#\(i + 1): \(note)")
                }
                if let section { sections.append(section) }
            }
            if !sections.isEmpty {
                out[ordinal, default: []].append(contentsOf: sections)
            }
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
            let sections = decodeDesktopSectionSections(fromTOML: text)
            if !sections.isEmpty { c.macDesktopSectionConfigs = sections }
            return c
        }
        FileHandle.standardError.write(Data(
            "facet: could not read \(path)\n".utf8))
        return .init()
    }
}
