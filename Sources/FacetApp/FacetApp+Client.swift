// Client mode — the half of facet's CLI surface that runs when at
// least one recognised flag / subcommand was passed: post the
// matching control notification to the running server instance over
// the DNC, then exit. The server-side observer
// (``Controller.installCLIControl``) routes it. Also home to the
// canonical-name tables + parse helpers the argv loop in
// ``FacetApp.main()`` (Main.swift) reads. Extracted unchanged from
// Main.swift (#182 phase 1) — same-module extension, no logic change.

import AppKit
import FacetCore
import FacetView

extension ArgCursor {
    /// Consume the next token as `flag`'s required value, or loud-exit(2)
    /// with a "missing argument" usage error when the args are exhausted
    /// (#227). Strict consumption: the token is taken verbatim — even a
    /// `--`-looking one — and the per-flag validator decides whether it's
    /// acceptable, so a negative coordinate or a literal `0` reads fine
    /// while a dropped value surfaces as a loud usage error rather than a
    /// silent mis-parse.
    mutating func value(for flag: String) -> String {
        guard let v = next() else {
            FacetApp.die("\(flag): missing argument")
        }
        return v
    }
}

extension FacetApp {

    // MARK: - Client mode posting

    /// Post a raw control string to the running instance, then
    /// exit. Never returns.
    static func postControl(_ object: String) -> Never {
        DistributedNotificationCenter.default().postNotificationName(
            .init(ctrlNotificationName),
            object: object,
            userInfo: nil,
            deliverImmediately: true)
        exit(0)
    }

    /// Post ``style:NAME``. Name must already be canonical
    /// (validated by ``canonicalStyle`` at parse time).
    static func postStyle(_ name: String) -> Never {
        postControl("style:" + name)
    }

    /// Post ``view:NAME[+active][+loading:MS][+geom:X,Y,W,H][+edge:E]``.
    /// Name must already be canonical. Geom + loading are optional and
    /// only meaningful for tree; edge is only meaningful for rail (each
    /// view silently ignores the modifiers it doesn't use, same pattern
    /// as +active).
    static func postView(_ name: String,
                         active: Bool,
                         loadingMs: Int?,
                         geom: (Int, Int, Int, Int)?,
                         edge: String? = nil) -> Never {
        var payload = "view:\(name)"
        if active { payload += "+active" }
        if let ms = loadingMs { payload += "+loading:\(ms)" }
        if let g = geom {
            payload += "+geom:\(g.0),\(g.1),\(g.2),\(g.3)"
        }
        if let e = edge { payload += "+edge:\(e)" }
        postControl(payload)
    }

    static func postHide(_ name: String) -> Never {
        postControl("hide:\(name)")
    }

    static func postToggle(_ name: String) -> Never {
        postControl("toggle:\(name)")
    }

    /// Post ``workspace:TARGET`` where TARGET is an absolute 1-based
    /// index (`"2"`) or a relative keyword (`next` / `prev` /
    /// `recent`). The server resolves relatives against its live
    /// state. Absolute is idempotent (no-op if already there).
    static func postWorkspaceFocus(_ target: String) -> Never {
        postControl("workspace:" + target)
    }

    /// Post ``lens:TARGET`` (M11-3 tag mode) where TARGET is
    /// `only:NAME` / `toggle:NAME` / `all`. The server resolves the tag
    /// name and surfaces an unknown-tag error.
    static func postLens(_ target: String) -> Never {
        postControl("lens:" + target)
    }

    /// Post ``window-move:N`` (1-indexed). Moves the focused
    /// window to the Nth workspace via the backend.
    static func postWindowMove(_ index: Int) -> Never {
        postControl("window-move:\(index)")
    }

    /// Post ``window-move-follow:N`` — move the focused window to the
    /// Nth workspace, then switch the active workspace to N so focus
    /// follows the window (send-and-follow).
    static func postWindowMoveFollow(_ index: Int) -> Never {
        postControl("window-move-follow:\(index)")
    }

    /// Post ``set-layout:NAME``. NAME must be one of
    /// ``canonicalLayoutModes`` (validated by ``canonicalLayoutMode``
    /// at parse time). Targets the currently-active workspace.
    static func postSetLayout(_ name: String) -> Never {
        postControl("set-layout:" + name)
    }

    /// Post ``retile``. Re-apply the active WS's layout via the
    /// native adapter's layout engine.
    static func postRetile() -> Never {
        postControl("retile")
    }

    /// Post ``window-toggle-float`` / ``window-toggle-sticky`` /
    /// ``window-toggle-orientation``. Target is the focused window.
    static func postWindowToggleFloat() -> Never {
        postControl("window-toggle-float")
    }

    static func postWindowToggleSticky() -> Never {
        postControl("window-toggle-sticky")
    }

    static func postWindowToggleOrientation() -> Never {
        postControl("window-toggle-orientation")
    }

    /// Post ``window-cycle-stack:next`` / ``:prev``. Direction
    /// already canonical by parse time (`parseCycleStack`).
    static func postWindowCycleStack(_ direction: String) -> Never {
        postControl("window-cycle-stack:" + direction)
    }

    /// Post master-knob nudges (the master-* engines). The active
    /// WS's master ratio (`grow` / `shrink`, ±0.05) or master count
    /// (`inc` / `dec`, ±1); no-op for other modes.
    static func postWindowGrowMaster() -> Never {
        postControl("window-grow-master")
    }

    static func postWindowShrinkMaster() -> Never {
        postControl("window-shrink-master")
    }

    static func postWindowIncMaster() -> Never {
        postControl("window-inc-master")
    }

    static func postWindowDecMaster() -> Never {
        postControl("window-dec-master")
    }

    /// Post ``window-focus-dir:DIR`` / ``window-move-dir:DIR`` (②).
    /// Direction already canonical by parse time (`canonicalDirection`).
    static func postWindowFocusDir(_ dir: String) -> Never {
        postControl("window-focus-dir:" + dir)
    }

    static func postWindowMoveDir(_ dir: String) -> Never {
        postControl("window-move-dir:" + dir)
    }

    /// Validate + canonicalise a direction (up|down|left|right). Loud
    /// reject on typo (``exit(2)``) — same pattern as `canonicalLayoutMode`.
    static let canonicalDirections = ["up", "down", "left", "right"]

    static func canonicalDirection(_ name: String) -> String {
        switch canonicalize(name, allowed: canonicalDirections) {
        case .success(let n): return n
        case .failure(.unknownValue(let v, let expected)):
            die("unknown direction \"\(v)\" — expected one of: "
                + expected.joined(separator: ", "))
        case .failure:
            die("unknown direction \"\(name)\"")
        }
    }

    /// Validate + canonicalise a layout-mode name. Loud reject on
    /// typo (`exit(2)`) — same pattern as `canonicalView` /
    /// `canonicalStyle`.
    static let canonicalLayoutModes =
        ["bsp", "stack", "float"] + LayoutRegistry.names

    static func canonicalLayoutMode(_ name: String) -> String {
        switch canonicalize(name, allowed: canonicalLayoutModes) {
        case .success(let n): return n
        case .failure(.unknownValue(let v, let expected)):
            die("unknown layout \"\(v)\" — expected one of: "
                + expected.joined(separator: ", "))
        case .failure:
            die("unknown layout \"\(name)\"")
        }
    }

    /// Parse the value of ``workspace --focus VALUE``. VALUE is a relative
    /// keyword (`next` / `prev` / `recent`), an absolute 1-based index, or
    /// a workspace **name**. Returns the canonical control payload:
    /// `next|prev|recent`, the index as a string, or `name:NAME`
    /// (case preserved). Numeric values are always indices — name a
    /// workspace non-numerically to reference it by name (yabai-style).
    static func parseWorkspaceFocus(_ value: String) -> String {
        switch value.lowercased() {
        case "next", "prev", "recent":
            return value.lowercased()
        default:
            if let n = Int(value), n > 0 { return String(n) }   // index
            return "name:" + validateWorkspaceName(
                value, flag: "workspace --focus")               // name
        }
    }

    /// Parse the value of ``--move-to N`` (positive integer, 1-indexed).
    static func parseMoveToInt(_ value: String) -> Int {
        parsePositiveInt(value, flag: "--move-to")
    }

    /// Generic 1-indexed positive-integer parser. Reused by every
    /// ``--… N`` flag whose value names a workspace slot. Takes the
    /// already-extracted value token (the cursor consumed it).
    private static func parsePositiveInt(_ value: String,
                                         flag: String) -> Int {
        switch FacetCore.parseGeomInt(value, requirePositive: true) {
        case .success(let n):
            return n
        case .failure(.notAnInteger(let v)):
            die("\(flag) expects an integer (got \"\(v)\")")
        case .failure(.notPositive(let n)):
            die("\(flag) must be > 0 (1-indexed, got \(n))")
        case .failure:
            die("\(flag) parse error")
        }
    }

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

    /// Sub-command parser for ``facet workspace <flag>``. Subject-verb
    /// mirror of ``facet window``: one action per invocation, loud
    /// reject on zero / multiple / unknown. Verbs:
    ///   --focus TARGET   switch workspace (index | next | prev | recent | name)
    ///   --layout NAME    set the active workspace's layout mode
    ///   --remove TARGET  remove a workspace (`current` | index)
    ///   --retile         re-apply the active workspace's layout
    static func runWorkspaceCommand(_ args: [String]) -> Never {
        var focusArg: String?
        var layoutArg: String?
        var retileFlag = false
        var balanceFlag = false
        var rotateArg: Int?
        var mirrorArg: String?
        var addFlag = false
        var removeArg: String?      // "" = active (current), else 1-based index
        var renameArg: String?
        var moveArg: Int?
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--focus":
                focusArg = parseWorkspaceFocus(cursor.value(for: "workspace --focus"))
            case "--layout":
                layoutArg = canonicalLayoutMode(cursor.value(for: "workspace --layout"))
            case "--retile":
                retileFlag = true
            case "--balance":
                balanceFlag = true
            case "--rotate":
                rotateArg = parseRotateDegrees(cursor.value(for: "workspace --rotate"))
            case "--mirror":
                mirrorArg = parseMirrorAxis(cursor.value(for: "workspace --mirror"))
            case "--add":
                addFlag = true
            case "--remove":
                removeArg = parseWorkspaceRemoveTarget(cursor.value(for: "workspace --remove"))
            case "--rename":
                renameArg = validateWorkspaceName(
                    cursor.value(for: "workspace --rename"), flag: "workspace --rename")
            case "--move":
                moveArg = parsePositiveInt(
                    cursor.value(for: "workspace --move"), flag: "workspace --move")
            default:
                die("unknown `workspace` flag \"\(a)\" — "
                    + "see `facet --help`")
            }
        }
        let count = [focusArg != nil, layoutArg != nil, retileFlag,
                     balanceFlag, rotateArg != nil, mirrorArg != nil,
                     addFlag, removeArg != nil, renameArg != nil,
                     moveArg != nil].filter { $0 }.count
        guard count > 0 else {
            die("facet workspace: no action specified — "
                + "see `facet --help`")
        }
        guard count == 1 else {
            die("facet workspace: pick one action per invocation — "
                + "see `facet --help`")
        }
        requireGrouping(.workspace, subject: "workspace")
        requireServerAlive()
        if let f = focusArg  { postWorkspaceFocus(f) }
        if let l = layoutArg { postSetLayout(l) }
        if retileFlag        { postRetile() }
        if balanceFlag       { postControl("workspace-balance") }
        if let d = rotateArg { postControl("workspace-rotate:\(d)") }
        if let m = mirrorArg { postControl("workspace-mirror:" + m) }
        if addFlag           { postControl("workspace-add") }
        if let r = removeArg { postControl("workspace-remove:" + r) }
        if let n = renameArg { postControl("workspace-rename:" + n) }
        if let m = moveArg   { postControl("workspace-move:\(m)") }
        die("facet workspace: dispatch fell through (bug)")
    }

    /// Sub-command parser for ``facet lens <flag>`` (M11-3 tag mode).
    /// Subject-verb mirror of ``facet workspace``: one action per
    /// invocation, loud reject on zero / multiple / unknown. Verbs:
    ///   --only NAME    show exactly tag NAME
    ///   --toggle NAME  flip tag NAME in/out of the current lens union
    ///   --all          show every tag
    /// Tag-mode only — under `by = "workspace"` the server no-ops.
    static func runLensCommand(_ args: [String]) -> Never {
        var onlyArg: String?
        var toggleArg: String?
        var allFlag = false
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--only":
                onlyArg = cursor.value(for: "lens --only")
            case "--toggle":
                toggleArg = cursor.value(for: "lens --toggle")
            case "--all":
                allFlag = true
            default:
                die("unknown `lens` flag \"\(a)\" — see `facet --help`")
            }
        }
        let count = [onlyArg != nil, toggleArg != nil, allFlag]
            .filter { $0 }.count
        guard count > 0 else {
            die("facet lens: no action specified — see `facet --help`")
        }
        guard count == 1 else {
            die("facet lens: pick one action per invocation — "
                + "see `facet --help`")
        }
        // Reject an empty NAME (a shell var that expanded to nothing)
        // loudly rather than posting a no-such-tag the server ignores.
        if let n = onlyArg, n.isEmpty {
            die("facet lens --only: expected a non-empty tag name")
        }
        if let n = toggleArg, n.isEmpty {
            die("facet lens --toggle: expected a non-empty tag name")
        }
        requireGrouping(.tag, subject: "lens")
        requireServerAlive()
        if let n = onlyArg   { postLens("only:" + n) }
        if let n = toggleArg { postLens("toggle:" + n) }
        if allFlag           { postLens("all") }
        die("facet lens: dispatch fell through (bug)")
    }

    /// Sub-command parser for ``facet tag <flag>`` (M11-3 tag mode).
    /// Edits the session tag VOCABULARY (not a window — that's
    /// ``facet window --tag``). Subject-verb mirror of ``facet
    /// workspace``: one action per invocation, loud reject on zero /
    /// multiple / unknown. Verbs:
    ///   --add NAME        declare tag NAME (no window touched; idempotent)
    ///   --remove NAME     delete NAME — strips it from every window; its
    ///                     bit is freed for reuse
    ///   --rename OLD NEW  rename OLD to NEW in place (bit kept); rejects
    ///                     an unknown OLD or an already-defined NEW
    /// Tag-mode only — `requireGrouping(.tag)`.
    static func runTagCommand(_ args: [String]) -> Never {
        var addArg: String?
        var removeArg: String?
        var renameArg: (String, String)?
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--add":
                addArg = parseTagName(cursor.value(for: "tag --add"), flag: "tag --add")
            case "--remove":
                removeArg = parseTagName(cursor.value(for: "tag --remove"), flag: "tag --remove")
            case "--rename":
                // Positional-2: OLD then NEW (#227). Each value is consumed
                // unconditionally; a flag-looking NEW (e.g. `--add`) fails
                // the name policy → loud reject (never a silent mis-rename).
                let old = validateTagName(
                    cursor.value(for: "tag --rename OLD"), flag: "tag --rename OLD")
                let new = validateTagName(
                    cursor.value(for: "tag --rename NEW"), flag: "tag --rename NEW")
                renameArg = (old, new)
            default:
                die("unknown `tag` flag \"\(a)\" — see `facet --help`")
            }
        }
        let count = [addArg != nil, removeArg != nil, renameArg != nil]
            .filter { $0 }.count
        guard count > 0 else {
            die("facet tag: no action specified — see `facet --help`")
        }
        guard count == 1 else {
            die("facet tag: pick one action per invocation — "
                + "see `facet --help`")
        }
        requireGrouping(.tag, subject: "tag")
        requireServerAlive()
        if let n = addArg    { postControl("tag-add:" + n) }
        if let n = removeArg { postControl("tag-remove:" + n) }
        if let r = renameArg { postControl("tag-rename:\(r.0):\(r.1)") }
        die("facet tag: dispatch fell through (bug)")
    }

    /// Sub-command parser for ``facet window <flag>``. Subcommand
    /// shape keeps room for future window-scoped ops
    /// (``--close``, ``--float``, …) without polluting the flat
    /// flag namespace.
    static func runWindowCommand(_ args: [String]) -> Never {
        var moveToArg: Int?
        var follow = false
        var markArg: String?
        var focusMarkArg: String?
        var unmarkArg: String?
        var tagArg: String?
        var untagArg: String?
        var toggleTagArg: String?
        var retagArg: (String, String)?
        var toggleFloat = false
        var toggleSticky = false
        var toggleOrientation = false
        var cycleStackDir: String?
        var growMaster = false
        var shrinkMaster = false
        var incMaster = false
        var decMaster = false
        var focusDirArg: String?
        var moveDirArg: String?
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--move-to":
                moveToArg = parseMoveToInt(cursor.value(for: "window --move-to"))
            case "--follow":
                follow = true
            case "--mark":
                markArg = parseMarkName(cursor.value(for: "window --mark"),
                                        flag: "window --mark")
            case "--focus-mark":
                focusMarkArg = parseMarkName(cursor.value(for: "window --focus-mark"),
                                             flag: "window --focus-mark")
            case "--unmark":
                unmarkArg = parseMarkName(cursor.value(for: "window --unmark"),
                                          flag: "window --unmark")
            case "--tag":
                tagArg = parseTagName(cursor.value(for: "window --tag"),
                                      flag: "window --tag")
            case "--untag":
                untagArg = parseTagName(cursor.value(for: "window --untag"),
                                        flag: "window --untag")
            case "--toggle-tag":
                toggleTagArg = parseTagName(cursor.value(for: "window --toggle-tag"),
                                            flag: "window --toggle-tag")
            case "--retag":
                // Positional-2: OLD then NEW (#228, same shape as
                // `tag --rename`). Each value is consumed unconditionally
                // and validated; a flag-looking NEW fails the name policy
                // → loud reject (never a silent mis-retag).
                let old = validateTagName(
                    cursor.value(for: "window --retag OLD"), flag: "window --retag OLD")
                let new = validateTagName(
                    cursor.value(for: "window --retag NEW"), flag: "window --retag NEW")
                retagArg = (old, new)
            case "--toggle-float":
                toggleFloat = true
            case "--toggle-sticky":
                toggleSticky = true
            case "--toggle-orientation":
                toggleOrientation = true
            case "--cycle-stack":
                cycleStackDir = parseCycleStack(cursor.value(for: "window --cycle-stack"))
            case "--grow-master":
                growMaster = true
            case "--shrink-master":
                shrinkMaster = true
            case "--inc-master":
                incMaster = true
            case "--dec-master":
                decMaster = true
            case "--focus":
                focusDirArg = canonicalDirection(cursor.value(for: "window --focus"))
            case "--move":
                moveDirArg = canonicalDirection(cursor.value(for: "window --move"))
            default:
                die("unknown `window` flag \"\(a)\" — "
                    + "see `facet --help`")
            }
        }
        // Sequence-of-flags forms are out (a single `window`
        // subcommand drives one action); pick the first that
        // was set, in declaration order. Loud reject if zero or
        // multiple were specified to keep behaviour unambiguous.
        let count = (moveToArg != nil ? 1 : 0)
            + (markArg != nil ? 1 : 0)
            + (focusMarkArg != nil ? 1 : 0)
            + (unmarkArg != nil ? 1 : 0)
            + (tagArg != nil ? 1 : 0)
            + (untagArg != nil ? 1 : 0)
            + (toggleTagArg != nil ? 1 : 0)
            + (retagArg != nil ? 1 : 0)
            + (toggleFloat ? 1 : 0)
            + (toggleSticky ? 1 : 0)
            + (toggleOrientation ? 1 : 0)
            + (cycleStackDir != nil ? 1 : 0)
            + (growMaster ? 1 : 0)
            + (shrinkMaster ? 1 : 0)
            + (incMaster ? 1 : 0)
            + (decMaster ? 1 : 0)
            + (focusDirArg != nil ? 1 : 0)
            + (moveDirArg != nil ? 1 : 0)
        guard count > 0 else {
            die("facet window: no action specified — "
                + "see `facet --help`")
        }
        guard count == 1 else {
            die("facet window: pick one action per invocation — "
                + "see `facet --help`")
        }
        // `--follow` is a modifier on `--move-to`, not a standalone
        // action: move the window *and* switch to its new workspace.
        // Loud reject when used without a destination.
        if follow && moveToArg == nil {
            die("facet window: --follow only applies with --move-to N — "
                + "see `facet --help`")
        }
        // Tag verbs are tag-mode only (like `lens`); reject loudly in
        // workspace mode (exit 2) before touching the server.
        if tagArg != nil || untagArg != nil || toggleTagArg != nil
            || retagArg != nil {
            requireGrouping(.tag,
                            subject: "window --tag/--untag/--toggle-tag/--retag")
        }
        requireServerAlive()
        if let n = moveToArg { follow ? postWindowMoveFollow(n)
                                      : postWindowMove(n) }
        if let m = markArg { postControl("window-mark:" + m) }
        if let m = focusMarkArg { postControl("window-focus-mark:" + m) }
        if let m = unmarkArg { postControl("window-unmark:" + m) }
        if let n = tagArg { postControl("window-tag:" + n) }
        if let n = untagArg { postControl("window-untag:" + n) }
        if let n = toggleTagArg { postControl("window-toggle-tag:" + n) }
        if let r = retagArg { postControl("window-retag:\(r.0):\(r.1)") }
        if toggleFloat { postWindowToggleFloat() }
        if toggleSticky { postWindowToggleSticky() }
        if toggleOrientation { postWindowToggleOrientation() }
        if let d = cycleStackDir { postWindowCycleStack(d) }
        if growMaster { postWindowGrowMaster() }
        if shrinkMaster { postWindowShrinkMaster() }
        if incMaster { postWindowIncMaster() }
        if decMaster { postWindowDecMaster() }
        if let d = focusDirArg { postWindowFocusDir(d) }
        if let d = moveDirArg { postWindowMoveDir(d) }
        // Unreachable — `count == 1` guarantees one branch fired.
        die("facet window: dispatch fell through (bug)")
    }

    /// Sub-command parser for ``facet scratchpad <flag>``. A named
    /// hidden shelf: ``--stash NAME`` parks the focused window onto the
    /// shelf, ``--toggle NAME`` summons it onto the current workspace
    /// (or re-parks it if already visible there), ``--release NAME``
    /// drops it from the shelf as a normal tiled window. One action per
    /// invocation, same shape as ``runWindowCommand``.
    static func runScratchpadCommand(_ args: [String]) -> Never {
        var stashArg: String?
        var toggleArg: String?
        var releaseArg: String?
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--stash":
                stashArg = parseMarkName(cursor.value(for: "scratchpad --stash"),
                                         flag: "scratchpad --stash",
                                         noun: "scratchpad name")
            case "--toggle":
                toggleArg = parseMarkName(cursor.value(for: "scratchpad --toggle"),
                                          flag: "scratchpad --toggle",
                                          noun: "scratchpad name")
            case "--release":
                releaseArg = parseMarkName(cursor.value(for: "scratchpad --release"),
                                           flag: "scratchpad --release",
                                           noun: "scratchpad name")
            default:
                die("unknown `scratchpad` flag \"\(a)\" — "
                    + "see `facet --help`")
            }
        }
        let count = (stashArg != nil ? 1 : 0)
            + (toggleArg != nil ? 1 : 0)
            + (releaseArg != nil ? 1 : 0)
        guard count > 0 else {
            die("facet scratchpad: no action specified — "
                + "see `facet --help`")
        }
        guard count == 1 else {
            die("facet scratchpad: pick one action per invocation — "
                + "see `facet --help`")
        }
        requireServerAlive()
        if let n = stashArg   { postControl("scratchpad-stash:" + n) }
        if let n = toggleArg  { postControl("scratchpad-toggle:" + n) }
        if let n = releaseArg { postControl("scratchpad-release:" + n) }
        // Unreachable — `count == 1` guarantees one branch fired.
        die("facet scratchpad: dispatch fell through (bug)")
    }

    /// Validate a mark / scratchpad-shelf name (the already-extracted
    /// value token). Routed through the shared `CLIName.sanitized` so it
    /// obeys the same policy as tag names (#227): non-empty, no internal
    /// whitespace, no leading `-`, none of the `:` `=` `,` delimiters.
    /// Loud reject (exit 2) on a violation. `noun` tailors the message
    /// (`"mark name"` by default, `"scratchpad name"` for shelves).
    static func parseMarkName(_ value: String, flag: String,
                              noun: String = "mark name") -> String {
        guard let name = CLIName.sanitized(value) else {
            die("\(flag): invalid \(noun) — must be non-empty, must not "
                + "start with '-', and must not contain spaces or "
                + "'=' ',' ':'")
        }
        return name
    }

    /// Validate a tag name (the already-extracted value token of
    /// `window --tag` / `--untag` / `--toggle-tag`, `tag --add` /
    /// `--remove`). Delegates to `validateTagName`. Separate from
    /// `parseMarkName` because tag names carry the extra `_`-floor /
    /// `#`-strip rules.
    static func parseTagName(_ value: String, flag: String) -> String {
        validateTagName(value, flag: flag)
    }

    /// Shared tag-name validation (used by `parseTagName` and the
    /// `tag --rename OLD NEW` halves). Delegates the rule to the
    /// backend-neutral `TagName.sanitized` (strip a leading `#`, trim,
    /// reject empty / leading `_` / leading `-` / internal space /
    /// `=`,`,`,`:`; case-preserved) and loud-rejects (exit 2) on failure
    /// — the GUI tag input shares the same policy but normalizes spaces.
    /// `flag` tailors the message (e.g. `"window --tag"`,
    /// `"tag --rename OLD"`).
    static func validateTagName(_ s: String, flag: String) -> String {
        guard let name = TagName.sanitized(s) else {
            die("\(flag) \(s): invalid tag name — must be non-empty, must "
                + "not start with '_' (reserved) or '-', and must not "
                + "contain spaces or '=' ',' ':'")
        }
        return name
    }

    /// Validate a workspace name (the value of `workspace --rename` or the
    /// name form of `workspace --focus`). Uses the shared `CLIName` policy
    /// (no `#`-strip / `_`-floor — those are tag-specific). Loud reject
    /// (exit 2) on a violation.
    static func validateWorkspaceName(_ value: String, flag: String) -> String {
        guard let name = CLIName.sanitized(value) else {
            die("\(flag): invalid workspace name — must be non-empty, must "
                + "not start with '-', and must not contain spaces or "
                + "'=' ',' ':'")
        }
        return name
    }

    /// Parse the value of `workspace --remove TARGET` (#227). TARGET is
    /// `current` (the active workspace — the old optional-value bare
    /// `--remove`) or a 1-based index. Maps to the existing
    /// `workspace-remove:` wire form — empty string = active — so the
    /// server / catalog stay untouched (DNC byte-identical). Relative
    /// targets (next/prev/recent/name) would need server resolution and
    /// are out of scope for the grammar migration.
    static func parseWorkspaceRemoveTarget(_ value: String) -> String {
        if value.lowercased() == "current" { return "" }    // active WS
        if let n = Int(value), n > 0 { return String(n) }   // 1-based index
        die("workspace --remove: expected `current` or a workspace index "
            + "(1-based), got \"\(value)\"")
    }

    /// Parse the value of `workspace --rotate 90|180|270`. Loud reject on
    /// anything else (exit 2), matching the typo-fails-loudly rule.
    static func parseRotateDegrees(_ value: String) -> Int {
        guard let n = Int(value), [90, 180, 270].contains(n) else {
            die("workspace --rotate: expected 90 | 180 | 270, "
                + "got \"\(value)\"")
        }
        return n
    }

    /// Parse the value of `workspace --mirror horizontal|vertical`. Loud
    /// reject on anything else. horizontal = swap left↔right, vertical =
    /// top↔bottom.
    static func parseMirrorAxis(_ value: String) -> String {
        let lower = value.lowercased()
        guard ["horizontal", "vertical"].contains(lower) else {
            die("workspace --mirror: expected horizontal | vertical, "
                + "got \"\(value)\"")
        }
        return lower
    }

    /// Parse the value of `window --cycle-stack next|prev`. Loud reject on
    /// anything else (same pattern as `canonicalView` / `canonicalStyle`).
    static func parseCycleStack(_ value: String) -> String {
        let lower = value.lowercased()
        guard ["next", "prev"].contains(lower) else {
            die("window --cycle-stack: expected next | prev, got "
                + "\"\(value)\"")
        }
        return lower
    }

    /// Validate + canonicalise a view name. Loud reject on typo
    /// (``exit(2)``) so a fundamental error wins over later
    /// transient checks (e.g. server-not-running).
    static func canonicalView(_ name: String) -> String {
        switch canonicalize(name, allowed: canonicalViews) {
        case .success(let n): return n
        case .failure(.unknownValue(let v, let expected)):
            die("unknown view \"\(v)\" — expected one of: "
                + expected.joined(separator: ", "))
        case .failure:
            die("unknown view \"\(name)\"")
        }
    }

    /// The four edges a rail can dock against (`--edge`).
    static let canonicalEdges = ["top", "bottom", "left", "right"]

    /// Validate + canonicalise a rail edge. Loud reject on typo
    /// (``exit(2)``) — same contract as ``canonicalView``.
    static func canonicalEdge(_ name: String) -> String {
        switch canonicalize(name, allowed: canonicalEdges) {
        case .success(let n): return n
        case .failure(.unknownValue(let v, let expected)):
            die("unknown edge \"\(v)\" — expected one of: "
                + expected.joined(separator: ", "))
        case .failure:
            die("unknown edge \"\(name)\"")
        }
    }

    /// Parse a geometry integer flag value (``--pos-x 100``,
    /// ``--pos-y -1440`` etc). Negative coordinates are valid (strict
    /// consumption took the token verbatim); width / height pass
    /// `requirePositive`. Loud reject on non-integer / out-of-range so the
    /// user doesn't end up with a panel they can't see.
    static func parseGeomInt(_ value: String,
                             flag: String,
                             requirePositive: Bool = false) -> Int {
        switch FacetCore.parseGeomInt(value,
                                      requirePositive: requirePositive) {
        case .success(let n):
            return n
        case .failure(.notAnInteger(let v)):
            die("\(flag) expects an integer (got \"\(v)\")")
        case .failure(.notPositive(let n)):
            die("\(flag) must be > 0 (got \(n))")
        case .failure:
            die("\(flag) parse error")
        }
    }

    /// Validate + canonicalise a theme name.
    static func canonicalStyle(_ name: String) -> String {
        switch canonicalize(name, allowed: canonicalThemeNames) {
        case .success(let n): return n
        case .failure(.unknownValue(let v, let expected)):
            let hint = suggest(v).map { " — did you mean \"\($0)\"?" } ?? ""
            die("unknown theme \"\(v)\" — expected one of: "
                + expected.joined(separator: ", ") + hint)
        case .failure:
            die("unknown theme \"\(name)\"")
        }
    }
}
