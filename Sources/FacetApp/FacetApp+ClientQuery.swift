// Client mode — read-only `facet query` projections. The bare query
// prints the human-readable status snapshot; a projection flag emits
// machine-readable JSON (--windows / --tags). Split out of
// FacetApp+Client.swift (P8-3); same-module extension, no logic change.
import AppKit
import FacetCore
import FacetView

extension FacetApp {
    /// `facet query [--windows [--filter EXPR] | --tags]`
    /// dispatcher. Bare → the human-readable status snapshot
    /// (`runQueryStatus`); a single projection flag → its machine-readable
    /// JSON (`--windows`, #223; `--tags`, #228). `--filter EXPR`
    /// (#284) is a modifier on `--windows` — it post-filters that array
    /// with a `facet filter` expression — so it requires `--windows`
    /// (loud exit 2 otherwise, like `--edge` requires `--view rail`).
    /// Read-only: every projection works unconditionally (`--tags`
    /// reads whatever the server reports).
    static func runQuery(_ args: [String]) -> Never {
        var windows = false
        var tags = false
        var filterExpr: String?
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--windows": windows = true
            case "--tags":    tags = true
            case "--filter":  filterExpr = cursor.value(for: "--filter")
            default:
                die("unknown `query` flag \"\(a)\" — see `facet --help`")
            }
        }
        // One projection per invocation (mirrors the `lens` / `window`
        // one-action guard). Zero is fine → the bare status snapshot.
        let count = (windows ? 1 : 0) + (tags ? 1 : 0)
        guard count <= 1 else {
            die("facet query: pick one projection "
                + "(--windows / --tags) per invocation — "
                + "see `facet --help`")
        }
        // `--filter` only filters the per-window array; it's meaningless on
        // `--tags` / the bare status. Require `--windows` (a
        // usage error → exit 2) rather than silently ignoring it — same
        // modifier-needs-its-verb rule as `--edge` / `--loading`. (A
        // malformed filter VALUE is the opposite: non-fatal, see
        // `runQueryWindows`.)
        if filterExpr != nil && !windows {
            die("facet query --filter requires --windows — "
                + "see `facet --help`")
        }
        if windows { runQueryWindows(filter: filterExpr) }
        if tags    { runQueryTags() }
        runQueryStatus()
    }

    /// `facet query` — print the server's current view of the
    /// world: backend identity, hide method, workspaces with
    /// active marker + window counts, last error (if any),
    /// snapshot timestamp. (#227: the read verb, renamed from the
    /// former `facet status`; identical snapshot output.)
    ///
    /// Reads `/tmp/facet-status.json` written atomically by the
    /// running server (Controller.writeStatus). Three exit codes:
    ///
    ///   0 — printed
    ///   3 — file missing (server not running, or never reconciled)
    ///   4 — file present but malformed (server bug — restart)
    static func runQueryStatus() -> Never {
        print(readStatusSnapshotOrExit().render())
        exit(0)
    }

    /// Read `/tmp/facet-status.json` or loud-exit with the shared status
    /// read contract: 3 = file missing (server not running / never
    /// reconciled), 4 = present but malformed (server bug — restart).
    /// Returns the decoded snapshot on success. Shared by the
    /// human-readable status render (`runQueryStatus`) and the `--tags`
    /// JSON projection (#228), which both read the same file.
    static func readStatusSnapshotOrExit() -> StatusSnapshot {
        do {
            return try StatusSnapshot.read()
        } catch let CocoaError as CocoaError
            where CocoaError.code == .fileReadNoSuchFile
        {
            let msg = "facet: no query data at "
                + "\(StatusSnapshot.defaultPath) — server not running?\n"
                + "       start with `./run.sh` (or `facet` for server mode)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(3)
        } catch {
            let msg = "facet: query data malformed — \(error)\n"
                + "       restart the server with `./stop.sh && ./run.sh`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(4)
        }
    }

    /// `facet query --tags` (#228) — the defined tag VOCABULARY as a JSON
    /// array of names (declaration order); `[]` in workspace mode. The
    /// machine-readable source a `query --windows` sweep can't give (a
    /// defined-but-unused tag appears on no window). Reads the status
    /// snapshot (#228 folded `tags` into it); same 0/3/4 exit contract.
    static func runQueryTags() -> Never {
        emitQueryJSON(readStatusSnapshotOrExit().tags)
    }

    /// Pretty-print `value` as JSON (sorted keys + trailing newline,
    /// matching the `--windows` output shape) and exit 0. Shared by the
    /// `--tags` projection (#228) so all machine
    /// readable query forms look alike to a `jq` pipeline. An encode
    /// failure (not realistically reachable for a `[String]` / small
    /// struct) is surfaced as malformed-data (exit 4), staying within
    /// the documented contract rather than trapping.
    static func emitQueryJSON<V: Encodable>(_ value: V) -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        } catch {
            let msg = "facet: query data malformed — \(error)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(4)
        }
    }

    /// `facet query --windows [--filter EXPR]` — print the full per-window
    /// JSON array (#223), a flat list of every window across every mac
    /// desktop with raw props + facet's `facet` block (or `null` when
    /// unmanaged). Reads `/tmp/facet-query.json` (server writes it
    /// atomically on reconcile + startup). Same 0/3/4 exit-code contract
    /// as the status read.
    ///
    /// Without `--filter` the file's bytes print verbatim after a
    /// validating decode, so the output is byte-stable (#223 contract).
    /// With `--filter EXPR` (#284) the array is post-filtered by a
    /// `facet filter` expression and the matching subset is re-emitted in
    /// the same shape (pretty-printed, sorted keys). A malformed EXPR is
    /// LOUD but NON-FATAL: the caret prints to stderr and all windows show
    /// (exit 0, not 2) — a bad filter VALUE isn't a flag/arity usage error.
    /// `jq` still composes downstream either way.
    static func runQueryWindows(filter: String? = nil) -> Never {
        let data: Data
        let entries: [WindowQueryEntry]
        do {
            data = try Data(contentsOf:
                URL(fileURLWithPath: WindowQuery.defaultPath))
            entries = try JSONDecoder().decode([WindowQueryEntry].self, from: data)
        } catch let CocoaError as CocoaError
            where CocoaError.code == .fileReadNoSuchFile
        {
            let msg = "facet: no query data at "
                + "\(WindowQuery.defaultPath) — server not running?\n"
                + "       start with `./run.sh` (or `facet` for server mode)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(3)
        } catch {
            let msg = "facet: query data malformed — \(error)\n"
                + "       restart the server with `./stop.sh && ./run.sh`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(4)
        }

        guard let expr = filter else {
            // No filter: byte-stable verbatim print (unchanged #223 path).
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        }

        // Apply the filter. The pure decision (parse → degrade-or-filter +
        // diagnostics) lives in FacetCore (`QueryFilter`, unit-tested);
        // this shell only renders the diagnostics + emits the result.
        // `@name` filter-alias refs resolve against the config `[alias]`
        // table, which the CLIENT reads itself (t-5312) — `query` is a
        // client-side post-filter over the on-disk array, so there is no
        // server round-trip to ask; the theoretical read-skew window right
        // after a config edit is accepted.
        let outcome = QueryFilter.apply(
            expr, to: entries,
            aliases: FacetConfig.load().effectiveFilterAliases)
        if let caret = outcome.parseErrorCaret {
            let msg = "facet query --filter:\n\(caret)\n"
                + "       showing all windows (filter ignored)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        if !outcome.unknownFields.isEmpty {
            let bad = outcome.unknownFields.joined(separator: ", ")
            let known = FacetFilter.knownFields.sorted().joined(separator: ", ")
            let msg = "facet query --filter: unknown field(s) "
                + "\(bad) — they match nothing. Known fields: \(known)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        if !outcome.undefinedAliases.isEmpty {
            let bad = outcome.undefinedAliases.map { "@\($0)" }
                .joined(separator: ", ")
            let msg = "facet query --filter: undefined filter alias(es) "
                + "\(bad) — they match nothing (define them under [alias] "
                + "in config.toml)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        if !outcome.aliasCycles.isEmpty {
            let msg = "facet query --filter: filter alias cycle: "
                + outcome.aliasCycles.joined(separator: "; ")
                + " — the cyclic reference matches nothing\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }
        // Re-emit in the on-disk shape (pretty + sorted keys), so a
        // filtered array looks identical to an unfiltered one to `jq`.
        emitQueryJSON(outcome.entries)
    }

}
