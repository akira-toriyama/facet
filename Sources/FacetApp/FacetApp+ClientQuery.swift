// Client mode — read-only `facet query` projections. The bare query
// prints the human-readable status snapshot; a projection flag emits
// machine-readable JSON (--windows / --tags / --lens). Split out of
// FacetApp+Client.swift (P8-3); same-module extension, no logic change.
import AppKit
import FacetCore
import FacetView

extension FacetApp {
    /// `facet query [--windows | --tags | --lens]` dispatcher. Bare → the
    /// human-readable status snapshot (`runQueryStatus`); a single
    /// projection flag → its machine-readable JSON (`--windows`, #223;
    /// `--tags` / `--lens`, #228). Read-only + mode-tolerant: every
    /// projection works in workspace OR tag mode (`--tags` is `[]` /
    /// `--lens` is `null` where the concept doesn't apply), so there's no
    /// `requireGrouping` gate — only the write verbs (`lens`,
    /// `window --retag`) gate on tag mode.
    static func runQuery(_ args: [String]) -> Never {
        var windows = false
        var tags = false
        var lens = false
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--windows": windows = true
            case "--tags":    tags = true
            case "--lens":    lens = true
            default:
                die("unknown `query` flag \"\(a)\" — see `facet --help`")
            }
        }
        // One projection per invocation (mirrors the `lens` / `window`
        // one-action guard). Zero is fine → the bare status snapshot.
        let count = (windows ? 1 : 0) + (tags ? 1 : 0) + (lens ? 1 : 0)
        guard count <= 1 else {
            die("facet query: pick one projection "
                + "(--windows / --tags / --lens) per invocation — "
                + "see `facet --help`")
        }
        if windows { runQueryWindows() }
        if tags    { runQueryTags() }
        if lens    { runQueryLens() }
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
    /// human-readable status render (`runQueryStatus`) and the `--tags` /
    /// `--lens` JSON projections (#228), which all read the same file.
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

    /// `facet query --lens` (#228) — the current lens as
    /// `{ "tags": [...], "showsAll": bool }` (tag mode), or JSON `null`
    /// in workspace mode (the lens is a tag-mode concept). `showsAll`
    /// disambiguates a floor-only / `--all` lens (shows every window,
    /// `tags` may be `[]`) from a lens of zero user tags. Same 0/3/4
    /// exit contract as the other reads.
    static func runQueryLens() -> Never {
        guard let lens = readStatusSnapshotOrExit().lens else {
            // Workspace mode (or a pre-#228 status file): no lens. Emit
            // JSON null — a valid, mode-tolerant answer (exit 0).
            FileHandle.standardOutput.write(Data("null\n".utf8))
            exit(0)
        }
        emitQueryJSON(lens)
    }

    /// Pretty-print `value` as JSON (sorted keys + trailing newline,
    /// matching the `--windows` output shape) and exit 0. Shared by the
    /// `--tags` / `--lens` projections (#228) so all three machine
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

    /// `facet query --windows` — print the full per-window JSON array
    /// (#223), a flat list of every window across every mac desktop with
    /// raw props + facet's `facet` block (or `null` when unmanaged).
    /// Filter with `jq`. Reads `/tmp/facet-query.json` (server writes it
    /// atomically on reconcile + startup). Same 0/3/4 exit-code contract
    /// as the status read; prints the file's bytes verbatim after a
    /// validating decode so the output is byte-stable.
    static func runQueryWindows() -> Never {
        do {
            let data = try Data(contentsOf:
                URL(fileURLWithPath: WindowQuery.defaultPath))
            _ = try JSONDecoder().decode([WindowQueryEntry].self, from: data)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
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
    }

}
