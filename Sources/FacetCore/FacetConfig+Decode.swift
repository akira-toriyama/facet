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
        var d: [ConfigDiagnostic] = []
        return exclusionRules(fromTOML: text, diagnostics: &d)
    }

    /// `exclusionRules`, reporting each DROPPED table (t-r5yz). The drop was
    /// previously not even logged — a `[[exclude]]` with no constraint simply
    /// vanished.
    public static func exclusionRules(fromTOML text: String,
                                      diagnostics diags: inout [ConfigDiagnostic])
        -> [ExclusionRule]
    {
        var out: [ExclusionRule] = []
        for (i, t) in parseTOMLArrayOfTables(text, table: "exclude").enumerated() {
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
            guard rule.matcher.isConstrained else {
                diags.append(.init(.error, "config: [[exclude]] #\(i + 1): no "
                    + "constraint (app / title / role / subrole / max-width / "
                    + "max-height) — it would match nothing; dropping it"))
                continue
            }
            out.append(rule)
        }
        return out
    }

    /// Build the per-mac-desktop `[[desktop.N.section]]` map from the raw
    /// TOML text (the section model). Each block header is
    /// `desktop.<N>.section` (`N` = Mission Control ordinal ≥ 1); rows are
    /// `{ label, layout, unassigned }` — every row is a workspace SPATIAL cell
    /// (t-ec9s retired the section `type` / `match` / `apply`), so
    /// `DesktopSection.parse` is total and no row is dropped for its shape; a
    /// stray key from the retired section-lens era is ignored here and flagged
    /// by `config --validate`. A duplicate non-empty `label` within one desktop
    /// IS dropped, LOUD + first-wins (§A — the label is an addressing handle).
    /// A desktop with no usable rows contributes no entry. Section order within
    /// a desktop is file order. The decoded sections are consumed in production
    /// — read through `effectiveMacDesktopSectionConfigs`.
    public static func decodeDesktopSectionSections(fromTOML text: String)
        -> [Int: [DesktopSection]]
    {
        var d: [ConfigDiagnostic] = []
        return decodeDesktopSectionSections(fromTOML: text, diagnostics: &d)
    }

    /// `decodeDesktopSectionSections`, reporting every dropped row (t-r5yz).
    public static func decodeDesktopSectionSections(
        fromTOML text: String,
        diagnostics diags: inout [ConfigDiagnostic]) -> [Int: [DesktopSection]]
    {
        decodeDesktopSectionOrigins(fromTOML: text, diagnostics: &diags)
            .mapValues { $0.map(\.section) }
    }

    /// The origin-tracking core of `decodeDesktopSectionSections` (t-hdxb B4).
    /// Produces the SAME per-desktop, merged + deduped section lists, but each
    /// section is wrapped in a `DesktopSectionOrigin` that also carries the RAW
    /// header spelling it came from and its 0-based position among blocks of
    /// that spelling. The snapshot writer replays THIS (never a re-implemented
    /// index) to map a projected section id back to the exact
    /// `[[desktop.N.section]]` array-of-tables element to edit — so the mapping
    /// can never drift from the projection's `declOrder`.
    ///
    /// t-r5yz: the decoder no longer LOGS — it reports. Pass `diagnostics:` to
    /// collect the parse notes + dup-label drops (`load` threads them onto
    /// `FacetConfig.diagnostics`, whence the daemon logs them once and
    /// `--validate` exits 1); the snapshot writer, which re-derives origins on
    /// every export, calls the plain overload and discards them — which is what
    /// the old `log: false` meant, now expressed as "I am not the reporter".
    public static func decodeDesktopSectionOrigins(fromTOML text: String)
        -> [Int: [DesktopSectionOrigin]]
    {
        var d: [ConfigDiagnostic] = []
        return decodeDesktopSectionOrigins(fromTOML: text, diagnostics: &d)
    }

    public static func decodeDesktopSectionOrigins(
        fromTOML text: String,
        diagnostics diags: inout [ConfigDiagnostic]) -> [Int: [DesktopSectionOrigin]]
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
            guard let ordinal = Int(mid), ordinal >= 1 else {
                // `[[desktop.0.section]]` / `[[desktop.foo.section]]` — every row
                // under it is discarded. Was a bare `continue`: the user's
                // sections simply never existed (t-r5yz).
                diags.append(.init(.error, "config: [[\(name)]]: not a mac-desktop "
                    + "ordinal (expected `desktop.N.section`, N ≥ 1 = the Mission "
                    + "Control position) — dropping its \(rows.count) section(s)"))
                continue
            }
            for (i, row) in rows.enumerated() {
                let (section, note) = DesktopSection.parse(fromTOMLRow: row)
                if let note {
                    // A note WITH a section = the row survived, facet ignored part
                    // of it; a note with NO section = the row is gone.
                    diags.append(.init(section == nil ? .error : .warning,
                                       "config: [[desktop.\(ordinal).section]] "
                                        + "#\(i + 1): \(note)"))
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
                    diags.append(.init(.error, "config: [[desktop.\(ordinal).section]]: "
                        + "duplicate label \"\(p.section.label)\" — a label is an "
                        + "addressing handle and must be unique within one mac "
                        + "desktop; keeping the first, dropping this section"))
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

    /// Build `[Rule]` from the raw TOML text's `[[rule]]` array-of-tables
    /// (the Phase 3 adopt-rules — #282/#286). Each table: `match` (a facet
    /// filter WHERE-clause string) + the FLAT apply keys (`workspace` /
    /// `tags` / `floating` / `sticky` / `master`) read by the shared
    /// `ApplyOp.list` over the whole row (it ignores `match` + any unknown
    /// key, in canonical op order). A table missing `match` / with a blank
    /// `match`, or whose flat keys yield no usable `apply` op (it would adopt
    /// nothing), is DROPPED — a bad rule never breaks the others. The `match`
    /// GRAMMAR is NOT validated here (parse-only stays total); the consumer
    /// compiles it loud + non-fatal at eval time, like an isolate desktop's `match`.
    public static func decodeRuleSections(fromTOML text: String) -> [Rule] {
        var d: [ConfigDiagnostic] = []
        return decodeRuleSections(fromTOML: text, diagnostics: &d)
    }

    /// `decodeRuleSections`, reporting each DROPPED table (t-r5yz). Both drops
    /// were previously not even logged — a `[[rule]]` with a typo'd apply key
    /// vanished without a trace, and the user's windows silently never adopted.
    public static func decodeRuleSections(fromTOML text: String,
                                          diagnostics diags: inout [ConfigDiagnostic])
        -> [Rule]
    {
        var out: [Rule] = []
        for (i, t) in parseTOMLArrayOfTables(text, table: "rule").enumerated() {
            // `#N` is the rule's position IN THE FILE, always — never its position
            // among the survivors. Numbering the grammar check over the decoded
            // list instead would shift every diagnostic after a dropped rule by
            // one, and the whole point of this channel is to name the block the
            // user has to go and edit.
            let at = "[[rule]] #\(i + 1)"
            guard case .string(let match)? = t["match"],
                  !match.trimmingCharacters(in: .whitespaces).isEmpty
            else {
                diags.append(.init(.error, "config: \(at): missing or blank `match` "
                    + "— a rule with nothing to match on adopts nothing; dropping it"))
                continue
            }
            // Tag names that fail `TagName` policy yield no op and used to vanish
            // in silence — with `tags = ["ok", "bad:tag"]` the rule survived, one
            // tag short, and nothing said so.
            var rejectedTags: [String] = []
            let apply = ApplyOp.list(from: .table(t), rejectingTags: &rejectedTags)
            for raw in rejectedTags {
                diags.append(.init(.error, "config: \(at): \"\(raw)\" is not a valid "
                    + "tag name (no leading `_`, no `:` / `=` / `,`, no internal "
                    + "spaces) — dropping that tag"))
            }
            guard !apply.isEmpty else {
                diags.append(.init(.error, "config: \(at) (match \"\(match)\"): no "
                    + "`apply` key (expected workspace / tags / floating / sticky / "
                    + "master) — the rule would do nothing; dropping it"))
                continue
            }
            // Parse-only stays TOTAL: a malformed `match` is stored verbatim and
            // the rule LIVES (`RuleDecodeTests.matchGrammarNotValidatedAtDecode`).
            // We only say so out loud.
            diags += matchDiagnostics(for: match, at: "\(at) match")
            out.append(Rule(match: match, apply: apply))
        }
        return out
    }

    /// Grammar-check ONE `match` predicate (t-r5yz / D1). Not a drop — the block
    /// survives — and yet it is worse than a drop: the tree paints a caret while
    /// the park side silently falls out of its `case .success` and does nothing,
    /// so an isolate desktop with an unparseable predicate tiles nothing, parks
    /// nothing, and never says why. A DEAD desktop.
    ///
    /// The verdict comes from `classifyMatchPredicate` — the same pure function
    /// the live match editor shows — so `--validate` and the GUI can never
    /// disagree: malformed SYNTAX is hard (`.error`), an unknown FIELD is soft
    /// (`.warning`; the predicate is valid, it simply selects nothing).
    ///
    /// Called from the DECODERS rather than from a pass over the decoded config,
    /// because only the decoder knows WHICH block this is (the literal
    /// `[desktop.01]` header, the file position of a `[[rule]]`) — and a
    /// diagnostic that names the wrong block is worse than none.
    static func matchDiagnostics(for match: String, at where_: String)
        -> [ConfigDiagnostic]
    {
        switch classifyMatchPredicate(match) {
        case .ok:
            return []
        case .unknownField(let fields):
            return [.init(.warning, "config: \(where_) \"\(match)\": unknown field"
                + "\(fields.count == 1 ? "" : "s") \(fields.joined(separator: ", "))"
                + " — the predicate is valid but matches nothing")]
        case .malformed(let error):
            // Indent BOTH lines of the caret, or the `^` lands a column short.
            let caret = error.caret(in: match)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  " + $0 }.joined(separator: "\n")
            return [.init(.error, "config: \(where_): the predicate does not parse, "
                + "so it selects NOTHING (an isolate desktop with an unparseable "
                + "match tiles nothing and parks nothing)\n\(caret)")]
        }
    }

    /// The retired `[[desktop.N.tab]]` board headers this TOML still declares,
    /// sorted. Empty for a migrated config.
    ///
    /// This is the ONE piece of board code left, and it is load-bearing. Boards
    /// no longer decode, so a leftover tab-only config declares NOTHING facet
    /// recognises — which silently flips it from **opt-in** (manage just the
    /// configured mac desktops) to the **manage-every-desktop** default. The
    /// caller warns once per header, every load, so that flip is never silent.
    /// (`config --validate` rejects the block separately, via unknown-key.)
    ///
    /// Matched on the literal array-of-tables header text, so it is
    /// nesting-agnostic — `[[desktop.1.tab]]` and any `[[desktop.1.tab.section]]`
    /// under it both surface.
    static func retiredBoardHeaders(inTOML text: String) -> [String] {
        parseTOMLArraysOfTables(text, where: {
            $0.hasPrefix("desktop.") && $0.hasSuffix(".tab")
        }).keys.sorted()
    }

    /// Build the per-mac-desktop `[desktop.N]` typed-table map from the raw TOML
    /// text (board abolition, t-0sbm). Each `[desktop.<N>]` is a SINGLE table
    /// (`N` = Mission Control ordinal ≥ 1) carrying `type` (workspace / lens) +
    /// `label`, plus lens-only `match` / `layout` / `show-non-matching`. Read from
    /// the FLAT `parseTOMLSubset` map keyed by the literal header text
    /// `desktop.<N>` (a single table, so it lands in `.tables`, NOT the
    /// array-of-tables `.arrays` the section decoders read). A table with an
    /// absent / unknown `type`, or an isolate desktop missing `match`, is DROPPED LOUD.
    /// Successor to the retired `[[desktop.N.tab]]` board decode.
    public static func decodeDesktopTables(fromTOML text: String)
        -> [Int: DesktopMeta]
    {
        var d: [ConfigDiagnostic] = []
        return decodeDesktopTables(fromTOML: text, diagnostics: &d)
    }

    /// `decodeDesktopTables`, reporting every dropped table (t-r5yz).
    ///
    /// Iterates the headers in SORTED order so the result can't depend on the
    /// per-process Dictionary hash seed. That ordering is a diagnosis, not a
    /// cure: two spellings of the SAME ordinal (`[desktop.1]` + `[desktop.01]`
    /// — `Int` accepts zero-pad / leading `+`) still collide, and one of the
    /// user's two tables is still discarded. Sorting only makes WHICH one
    /// survives deterministic; the collision itself is now reported LOUD rather
    /// than being a coin flip that changed between runs.
    public static func decodeDesktopTables(fromTOML text: String,
                                           diagnostics diags: inout [ConfigDiagnostic])
        -> [Int: DesktopMeta]
    {
        var out: [Int: DesktopMeta] = [:]
        var spellingOf: [Int: String] = [:]
        let tables = parseTOMLSubset(text)
        for header in tables.keys.sorted() {
            guard let row = tables[header] else { continue }
            // Match EXACTLY `desktop.<N>` — one dotted level, ordinal ≥ 1. Skip
            // the top-level scope (`""`) and other `[section]` blocks in silence
            // (they are not addressed to us); a header that IS addressed to us
            // but names no ordinal (`[desktop.0]`, `[desktop.foo]`) is a DROP,
            // and drops are loud.
            guard header.hasPrefix("desktop.") else { continue }
            let mid = header.dropFirst("desktop.".count)
            // A deeper `desktop.N.foo` single table is not ours either — the
            // section / tab arrays-of-tables live in their own decoders.
            guard !mid.contains(".") else { continue }
            guard let ordinal = Int(mid), ordinal >= 1 else {
                diags.append(.init(.error, "config: [\(header)]: not a mac-desktop "
                    + "ordinal (expected `desktop.N`, N ≥ 1 = the Mission Control "
                    + "position) — dropping the table"))
                continue
            }
            let (meta, note) = DesktopMeta.parse(fromTOMLRow: row)
            if let note {
                // Same rule as the section rows: a note with no meta = the whole
                // `[desktop.N]` table is gone (error); a note WITH a meta = the
                // table lives and facet ignored a stray key (warning). Name the
                // LITERAL header — `[desktop.01]` must not be reported as
                // `[desktop.1]`, or the user goes looking at the wrong line.
                diags.append(.init(meta == nil ? .error : .warning,
                                   "config: [\(header)]: \(note)"))
            }
            // A DROPPED table claims nothing. Reserving the ordinal before the
            // parse verdict is known would let a broken spelling evict a VALID
            // sibling — `[desktop.01]` (no `match`) sorts first, dies, and takes
            // a perfectly good `[desktop.1]` down with it — leaving zero decoded
            // desktops, which under the opt-in rule means facet manages NOTHING.
            // Worse, the collision message would then name a "survivor" that did
            // not survive.
            guard let meta else { continue }
            if let prior = spellingOf[ordinal] {
                diags.append(.init(.error, "config: [\(header)] and [\(prior)] both "
                    + "name mac desktop \(ordinal) — one desktop is one table, so "
                    + "only [\(prior)] is kept and [\(header)] is dropped"))
                continue
            }
            spellingOf[ordinal] = header
            out[ordinal] = meta
            // The isolate `match` GRAMMAR — checked here, where the literal header
            // is in hand (see `matchDiagnostics`). The table still decodes: a
            // malformed match is not a drop, it is a DEAD desktop.
            if meta.type == .isolate {
                diags += matchDiagnostics(for: meta.match, at: "[\(header)] match")
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
        // FAIL CLOSED (t-r5yz / (c)). The file EXISTS — the user HAS configured
        // facet, we simply can't read what they said (bad permissions, not UTF-8).
        // Returning a bare default here would say "nobody ever configured me" and
        // facet would seize EVERY mac desktop, which is the same destructive flip
        // the all-dropped case just closed. An unreadable config is the loudest
        // possible "I don't know what you want": manage nothing, and say so.
        // (`config --validate` already refuses this path with exit 2, calling the
        // lenient collapse "a trap" — the daemon walked straight into it.)
        var c = FacetConfig()
        c.declaresDesktopBlocks = true
        c.diagnostics = [.init(.error, "config: \(path) exists but could not be read "
            + "(bad permissions? not UTF-8?) — facet is managing NO mac desktop "
            + "until it can read your config")]
        return c
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
        guard !isSameFile(snapshotPath, path) else {
            Log.line("config: [config] export-path must differ from config.toml "
                + "— auto-promote skipped")
            return fresh
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshotPath) else { return fresh }
        // Follow a symlinked config.toml (dotfiles managers — stow / chezmoi /
        // yadm — symlink `~/.config/*` into a repo) to the REAL target, for BOTH
        // the mtime gate and the write. `attributesOfItem` does NOT dereference,
        // so the gate would otherwise read the LINK's own mtime (its creation
        // time) instead of the repo file the user actually hand-edits, and the
        // atomic write (temp-file + rename(2)) would REPLACE the symlink with a
        // plain file and orphan the repo target. Resolving fixes both.
        let isLink = ((try? fm.attributesOfItem(atPath: path)[.type])
            as? FileAttributeType) == .typeSymbolicLink
        let realConfigPath = isLink ? (path as NSString).resolvingSymlinksInPath : path
        // mtime gate — snapshot must be strictly newer. Unreadable snapshot
        // mtime is fail-CLOSED (don't promote); a missing config mtime counts
        // as ancient so a present snapshot wins.
        guard let snapMTime = fileModificationDate(snapshotPath) else { return fresh }
        let configMTime = fileModificationDate(realConfigPath) ?? .distantPast
        guard snapMTime > configMTime else { return fresh }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: snapshotPath))
        else { return fresh }                  // fail-soft on unreadable snapshot
        do {
            try data.write(to: URL(fileURLWithPath: realConfigPath), options: .atomic)
        } catch {
            Log.line("config: auto-promote could not write \(realConfigPath): \(error)")
            return fresh                       // fail-soft on unwritable config
        }
        Log.debug("config: auto-promoted \(snapshotPath) → \(realConfigPath)")
        return load(path: path)                // read #2 — the promoted config (via the link)
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
        var diags: [ConfigDiagnostic] = []
        var c = FacetConfig.from(toml: parseTOMLSubset(text))
        let rules = exclusionRules(fromTOML: text, diagnostics: &diags)
        if !rules.isEmpty { c.exclusionRules = rules }
        let sections = decodeDesktopSectionSections(fromTOML: text, diagnostics: &diags)
        if !sections.isEmpty { c.macDesktopSectionConfigs = sections }
        let metas = decodeDesktopTables(fromTOML: text, diagnostics: &diags)
        if !metas.isEmpty { c.macDesktopMetaConfigs = metas }
        for header in retiredBoardHeaders(inTOML: text) {
            diags.append(.init(.error, "config: [[\(header)]] — boards were retired "
                + "(t-0sbm) and this block is IGNORED; type the desktop with "
                + "[desktop.N] and/or [[desktop.N.section]] instead"))
        }
        // A `type = "isolate"` desktop has no sections — flag it if it ALSO declares
        // `[[desktop.N.section]]` (they're ignored; the isolate desktop uses its
        // single `match`). `desktopType` resolves the explicit meta first, so the
        // stray sections never render. `.error`: the DESKTOP survives, but every
        // section block the user wrote under it is discarded whole.
        for ordinal in metas.keys.sorted()
        where metas[ordinal]?.type == .isolate && sections[ordinal] != nil {
            diags.append(.init(.error, "config: desktop \(ordinal) is type=isolate but "
                + "also declares [[desktop.\(ordinal).section]] — an isolate desktop "
                + "has no sections; dropping them"))
        }
        let adoptRules = decodeRuleSections(fromTOML: text, diagnostics: &diags)
        if !adoptRules.isEmpty { c.rules = adoptRules }
        // A1: run the STRICT schema validate on the LOAD path and RECORD any
        // violations as warnings — load still clamps/drops (never rejects).
        // The daemon surfaces these via Controller.logConfigWarnings at
        // startup + hot-reload.
        do {
            c.schemaWarnings = try Self.validate(text)
        } catch {
            // Syntactically-bad TOML can't be strict-parsed. It used to be
            // swallowed by a `try?` — and the LENIENT parser above just drops
            // each malformed line, so facet booted on a half-read config saying
            // absolutely nothing. Everything after the busted line is gone
            // (t-r5yz).
            diags.append(.init(.error, "config: not parseable as TOML — \(error). "
                + "facet fell back to a partial read: every line the parser could "
                + "not understand was SKIPPED, so keys may be silently missing"))
            c.schemaWarnings = []
        }
        // (c) OPT-IN SURVIVES ITS OWN BLOCKS. Whether facet is opt-in is declared
        // by the TEXT ("I wrote desktop blocks"), not by the survivors — but
        // `isMacDesktopManaged` could only see the survivors, so a config whose
        // desktop blocks ALL got dropped read as "no desktop config at all" and
        // flipped facet to manage-EVERY-desktop: it would adopt, park and tile
        // mac desktops the user explicitly never handed it. That is "a typo broke
        // the layout" in its most destructive form. Now a declaration that
        // decoded to nothing means facet manages NOTHING and says why — broken
        // config → hands off, the same rule a partially-broken config already
        // followed for its dropped desktops.
        c.declaresDesktopBlocks = declaresDesktopBlocks(inTOML: text)
        if c.declaresDesktopBlocks && sections.isEmpty && metas.isEmpty {
            diags.append(.init(.error, "config: this config declares mac-desktop "
                + "blocks but NONE of them decoded — facet is opt-in, so it will "
                + "manage NO mac desktop until at least one [desktop.N] / "
                + "[[desktop.N.section]] block is valid (see the errors above)"))
        }
        c.diagnostics = diags + c.layoutDiagnostics()
        return c
    }

    /// Does this config TEXT declare mac-desktop blocks at all — regardless of
    /// whether any of them survived decode? The opt-in question (c / t-r5yz).
    ///
    /// Matched on the literal header text, so it sees the shapes the decoders
    /// THREW AWAY as well as the ones they kept: `[desktop.N]`, `[[desktop.N.section]]`,
    /// a retired `[[desktop.N.tab]]`, and the junk ordinals (`[desktop.0]`,
    /// `[desktop.foo]`). If any of these is present, the user has asked facet to
    /// be selective — and a broken block must not un-ask it.
    static func declaresDesktopBlocks(inTOML text: String) -> Bool {
        if parseTOMLSubset(text).keys.contains(where: { $0.hasPrefix("desktop.") }) {
            return true
        }
        return !parseTOMLArraysOfTables(text, where: { $0.hasPrefix("desktop.") }).isEmpty
    }
}
