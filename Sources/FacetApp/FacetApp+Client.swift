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

    /// Default skeleton duration (ms) for a bare ``--loading``.
    static let defaultLoadingMs = 500

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

    /// Parse ``workspace --focus=VALUE``. VALUE is a relative keyword
    /// (`next` / `prev` / `recent`), an absolute 1-based index, or a
    /// workspace **name**. Returns the canonical control payload:
    /// `next|prev|recent`, the index as a string, or `name:NAME`
    /// (case preserved). Numeric values are always indices — name a
    /// workspace non-numerically to reference it by name (yabai-style).
    static func parseWorkspaceFocus(_ arg: String) -> String {
        let raw = String(arg.dropFirst("--focus=".count))
        switch raw.lowercased() {
        case "next", "prev", "recent":
            return raw.lowercased()
        default:
            if let n = Int(raw), n > 0 { return String(n) }   // index
            guard !raw.isEmpty else {
                die("workspace --focus expects an index, name, or "
                    + "next/prev/recent")
            }
            return "name:" + raw                              // name
        }
    }

    /// Parse ``--move-to=N`` (positive integer, 1-indexed).
    /// Same shape as ``parseWorkspaceInt``; both target a workspace
    /// index from the user's 1-based perspective.
    static func parseMoveToInt(_ arg: String) -> Int {
        parsePositiveInt(arg, prefix: "--move-to=", flag: "--move-to")
    }

    /// Generic 1-indexed positive-integer parser. Reused by every
    /// ``--…=N`` flag whose value names a workspace slot.
    private static func parsePositiveInt(_ arg: String,
                                         prefix: String,
                                         flag: String) -> Int {
        let raw = String(arg.dropFirst(prefix.count))
        switch FacetCore.parseGeomInt(raw, requirePositive: true) {
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

    /// `facet status` — print the server's current view of the
    /// world: backend identity, hide method, workspaces with
    /// active marker + window counts, last error (if any),
    /// snapshot timestamp.
    ///
    /// Reads `/tmp/facet-status.json` written atomically by the
    /// running server (Controller.writeStatus). Three exit codes:
    ///
    ///   0 — printed
    ///   3 — file missing (server not running, or never reconciled)
    ///   4 — file present but malformed (server bug — restart)
    static func runStatus() -> Never {
        do {
            let snap = try StatusSnapshot.read()
            print(snap.render())
            exit(0)
        } catch let CocoaError as CocoaError
            where CocoaError.code == .fileReadNoSuchFile
        {
            let msg = "facet: no status file at "
                + "\(StatusSnapshot.defaultPath) — server not running?\n"
                + "       start with `./run.sh` (or `facet` for server mode)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(3)
        } catch {
            let msg = "facet: status file malformed — \(error)\n"
                + "       restart the server with `./stop.sh && ./run.sh`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(4)
        }
    }

    /// Sub-command parser for ``facet workspace <flag>``. Subject-verb
    /// mirror of ``facet window``: one action per invocation, loud
    /// reject on zero / multiple / unknown. Verbs:
    ///   --focus=N|next|prev|recent  switch workspace (absolute or relative)
    ///   --layout=NAME               set the active workspace's layout mode
    ///   --retile                    re-apply the active workspace's layout
    static func runWorkspaceCommand(_ args: [String]) -> Never {
        var focusArg: String?
        var layoutArg: String?
        var retileFlag = false
        var balanceFlag = false
        var rotateArg: Int?
        var mirrorArg: String?
        var addFlag = false
        var removeArg: String?      // "" = active, else 1-based index
        var renameArg: String?
        var moveArg: Int?
        var i = 0
        while i < args.count {
            defer { i += 1 }
            let a = args[i]
            switch true {
            case a.hasPrefix("--focus="):
                focusArg = parseWorkspaceFocus(a)
            case a.hasPrefix("--layout="):
                layoutArg = canonicalLayoutMode(
                    String(a.dropFirst("--layout=".count)))
            case a == "--retile":
                retileFlag = true
            case a == "--balance":
                balanceFlag = true
            case a.hasPrefix("--rotate="):
                rotateArg = parseRotateDegrees(a)
            case a.hasPrefix("--mirror="):
                mirrorArg = parseMirrorAxis(a)
            case a == "--add":
                addFlag = true
            case a == "--remove":
                removeArg = ""                       // active workspace
            case a.hasPrefix("--remove="):
                removeArg = String(parsePositiveInt(
                    a, prefix: "--remove=", flag: "workspace --remove"))
            case a.hasPrefix("--rename="):
                renameArg = String(a.dropFirst("--rename=".count))
            case a.hasPrefix("--move="):
                moveArg = parsePositiveInt(
                    a, prefix: "--move=", flag: "workspace --move")
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
    ///   --only=NAME    show exactly tag NAME
    ///   --toggle=NAME  flip tag NAME in/out of the current lens union
    ///   --all          show every tag
    /// Tag-mode only — under `by = "workspace"` the server no-ops.
    static func runLensCommand(_ args: [String]) -> Never {
        var onlyArg: String?
        var toggleArg: String?
        var allFlag = false
        var i = 0
        while i < args.count {
            defer { i += 1 }
            let a = args[i]
            switch true {
            case a.hasPrefix("--only="):
                onlyArg = String(a.dropFirst("--only=".count))
            case a.hasPrefix("--toggle="):
                toggleArg = String(a.dropFirst("--toggle=".count))
            case a == "--all":
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
            die("facet lens --only=NAME: expected a non-empty tag name")
        }
        if let n = toggleArg, n.isEmpty {
            die("facet lens --toggle=NAME: expected a non-empty tag name")
        }
        requireGrouping(.tag, subject: "lens")
        requireServerAlive()
        if let n = onlyArg   { postLens("only:" + n) }
        if let n = toggleArg { postLens("toggle:" + n) }
        if allFlag           { postLens("all") }
        die("facet lens: dispatch fell through (bug)")
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
        var i = 0
        while i < args.count {
            defer { i += 1 }
            let a = args[i]
            switch true {
            case a.hasPrefix("--move-to="):
                moveToArg = parseMoveToInt(a)
            case a == "--follow":
                follow = true
            case a.hasPrefix("--mark="):
                markArg = parseMarkName(a, prefix: "--mark=")
            case a.hasPrefix("--focus-mark="):
                focusMarkArg = parseMarkName(a, prefix: "--focus-mark=")
            case a.hasPrefix("--unmark="):
                unmarkArg = parseMarkName(a, prefix: "--unmark=")
            case a.hasPrefix("--tag="):
                tagArg = parseTagName(a, prefix: "--tag=")
            case a.hasPrefix("--untag="):
                untagArg = parseTagName(a, prefix: "--untag=")
            case a.hasPrefix("--toggle-tag="):
                toggleTagArg = parseTagName(a, prefix: "--toggle-tag=")
            case a == "--toggle-float":
                toggleFloat = true
            case a == "--toggle-sticky":
                toggleSticky = true
            case a == "--toggle-orientation":
                toggleOrientation = true
            case a.hasPrefix("--cycle-stack="):
                cycleStackDir = parseCycleStack(a)
            case a == "--grow-master":
                growMaster = true
            case a == "--shrink-master":
                shrinkMaster = true
            case a == "--inc-master":
                incMaster = true
            case a == "--dec-master":
                decMaster = true
            case a.hasPrefix("--focus="):
                focusDirArg = canonicalDirection(
                    String(a.dropFirst("--focus=".count)))
            case a.hasPrefix("--move="):
                moveDirArg = canonicalDirection(
                    String(a.dropFirst("--move=".count)))
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
            die("facet window: --follow only applies with --move-to=N — "
                + "see `facet --help`")
        }
        // Tag verbs are tag-mode only (like `lens`); reject loudly in
        // workspace mode (exit 2) before touching the server.
        if tagArg != nil || untagArg != nil || toggleTagArg != nil {
            requireGrouping(.tag, subject: "window --tag/--untag/--toggle-tag")
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
    /// hidden shelf: ``--stash=NAME`` parks the focused window onto the
    /// shelf, ``--toggle=NAME`` summons it onto the current workspace
    /// (or re-parks it if already visible there), ``--release=NAME``
    /// drops it from the shelf as a normal tiled window. One action per
    /// invocation, same shape as ``runWindowCommand``.
    static func runScratchpadCommand(_ args: [String]) -> Never {
        var stashArg: String?
        var toggleArg: String?
        var releaseArg: String?
        var i = 0
        while i < args.count {
            defer { i += 1 }
            let a = args[i]
            switch true {
            case a.hasPrefix("--stash="):
                stashArg = parseMarkName(a, prefix: "--stash=",
                                         noun: "scratchpad name")
            case a.hasPrefix("--toggle="):
                toggleArg = parseMarkName(a, prefix: "--toggle=",
                                          noun: "scratchpad name")
            case a.hasPrefix("--release="):
                releaseArg = parseMarkName(a, prefix: "--release=",
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

    /// Parse a name from a `--flag=NAME` argument (marks, scratchpad
    /// shelves). Any non-empty string is accepted (single letter for
    /// hotkeys or a memorable word); an empty name is a loud reject
    /// (exit 2). `noun` tailors the message (`"mark name"` by default,
    /// `"scratchpad name"` for shelves).
    static func parseMarkName(_ arg: String, prefix: String,
                              noun: String = "mark name") -> String {
        let raw = String(arg.dropFirst(prefix.count))
        guard !raw.isEmpty else {
            die("\(prefix.dropLast()): expected a non-empty \(noun)")
        }
        return raw
    }

    /// Parse a tag name from a `--flag=NAME` argument
    /// (`window --tag=` / `--untag=` / `--toggle-tag=`). Strips a
    /// leading `#` (`#190` → `190`; the display form re-adds it). Loud
    /// reject (exit 2) on: empty, a leading `_` (reserved for the
    /// `_default` floor), or any of `=` `,` `:` (the CLI / DNC
    /// delimiters). Case-preserved. Separate from `parseMarkName`
    /// because tag names carry stricter rules than mark labels.
    static func parseTagName(_ arg: String, prefix: String) -> String {
        var raw = String(arg.dropFirst(prefix.count))
        if raw.hasPrefix("#") { raw = String(raw.dropFirst()) }
        let flag = String(prefix.dropLast())   // "--tag" etc. (drop the `=`)
        guard !raw.isEmpty else {
            die("\(flag)=NAME: expected a non-empty tag name")
        }
        guard !raw.hasPrefix("_") else {
            die("\(flag)=\(raw): tag names cannot start with '_' (reserved)")
        }
        guard !raw.contains(where: { "=,:".contains($0) }) else {
            die("\(flag)=\(raw): tag names cannot contain '=', ',' or ':'")
        }
        return raw
    }

    /// Parse `--rotate=90|180|270`. Loud reject on anything else
    /// (exit 2), matching the typo-fails-loudly rule.
    static func parseRotateDegrees(_ arg: String) -> Int {
        let raw = String(arg.dropFirst("--rotate=".count))
        guard let n = Int(raw), [90, 180, 270].contains(n) else {
            die("--rotate: expected 90 | 180 | 270, got \"\(raw)\"")
        }
        return n
    }

    /// Parse `--mirror=horizontal|vertical`. Loud reject on anything
    /// else (exit 2). horizontal = swap left↔right, vertical = top↔bottom.
    static func parseMirrorAxis(_ arg: String) -> String {
        let raw = String(arg.dropFirst("--mirror=".count))
        let lower = raw.lowercased()
        guard ["horizontal", "vertical"].contains(lower) else {
            die("--mirror: expected horizontal | vertical, got \"\(raw)\"")
        }
        return lower
    }

    /// Parse `--cycle-stack=next|prev`. Loud reject on anything
    /// else (same pattern as `canonicalView` / `canonicalStyle`).
    static func parseCycleStack(_ arg: String) -> String {
        let raw = String(arg.dropFirst("--cycle-stack=".count))
        let lower = raw.lowercased()
        guard ["next", "prev"].contains(lower) else {
            die("--cycle-stack: expected next | prev, got "
                + "\"\(raw)\"")
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

    /// The four edges a rail can dock against (`--edge=`).
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

    /// Parse a geometry integer flag (``--pos-x=100`` etc). Loud
    /// reject on non-integer / out-of-range so the user doesn't
    /// end up with a panel they can't see.
    static func parseGeomInt(_ arg: String,
                             _ prefix: String,
                             requirePositive: Bool = false) -> Int {
        let raw = String(arg.dropFirst(prefix.count))
        let flag = String(prefix.dropLast())   // "--pos-x"
        switch FacetCore.parseGeomInt(raw,
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
