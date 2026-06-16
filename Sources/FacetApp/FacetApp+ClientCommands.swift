// Client mode — the `facet <subject> <verb>` subcommand runners
// (workspace / lens / tag / window / scratchpad): parse the argv,
// validate, then post the control notification to the running server
// (or loud-exit on a usage error). Includes the subcommand-specific
// parse / validate / canonical-name helpers. Split out of FacetApp+Client.swift (P8-3).
import AppKit
import FacetCore
import FacetView

extension FacetApp {
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

    /// Sub-command parser for ``facet lens <flag>`` (M11-3 tag mode;
    /// #228 multi-tag). Subject-verb mirror of ``facet workspace``: one
    /// action per invocation, loud reject on zero / multiple / unknown.
    /// Each value-bearing verb takes one OR MORE comma-joined tag names
    /// (`A[,B,…]`). Verbs:
    ///   --only A[,B,…]    show exactly these tags (replace the set)
    ///   --add A[,B,…]     union these into the shown set
    ///   --remove A[,B,…]  drop these from the shown set
    ///   --toggle A[,B,…]  flip each tag in / out of the shown set
    ///   --all             show every tag
    /// Names are validated for SHAPE here (`parseTagList`); the server
    /// resolves them strictly (one unknown name → unchanged + error).
    /// Tag-mode only — under `by = "workspace"` the server no-ops.
    static func runLensCommand(_ args: [String]) -> Never {
        var onlyArg: String?
        var addArg: String?
        var removeArg: String?
        var toggleArg: String?
        var allFlag = false
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--only":
                onlyArg = parseTagList(cursor.value(for: "lens --only"),
                                       flag: "lens --only")
            case "--add":
                addArg = parseTagList(cursor.value(for: "lens --add"),
                                      flag: "lens --add")
            case "--remove":
                removeArg = parseTagList(cursor.value(for: "lens --remove"),
                                         flag: "lens --remove")
            case "--toggle":
                toggleArg = parseTagList(cursor.value(for: "lens --toggle"),
                                         flag: "lens --toggle")
            case "--all":
                allFlag = true
            default:
                die("unknown `lens` flag \"\(a)\" — see `facet --help`")
            }
        }
        let count = [onlyArg != nil, addArg != nil, removeArg != nil,
                     toggleArg != nil, allFlag].filter { $0 }.count
        guard count > 0 else {
            die("facet lens: no action specified — see `facet --help`")
        }
        guard count == 1 else {
            die("facet lens: pick one action per invocation — "
                + "see `facet --help`")
        }
        requireGrouping(.tag, subject: "lens")
        requireServerAlive()
        if let n = onlyArg   { postLens("only:" + n) }
        if let n = addArg    { postLens("add:" + n) }
        if let n = removeArg { postLens("remove:" + n) }
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

    /// Parse a comma-joined tag list for the `lens` verbs (#228:
    /// `--only/--add/--remove/--toggle web,code`). Splits on ',',
    /// validates each piece with `validateTagName` (an empty element, a
    /// leading '-', or a stray space / `=` / `:` loud-exits), and returns
    /// the canonical comma-joined form for the DNC payload. A single name
    /// is the degenerate arity-1 case (no comma needed); the empty string
    /// is rejected. Comma-join (not space-variadic) keeps the parser's
    /// per-flag arity at 1 and `,`/`:` out of names makes the wire form
    /// unambiguous (#227 grammar).
    static func parseTagList(_ value: String, flag: String) -> String {
        let pieces = value
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        guard !pieces.contains(where: { $0.isEmpty }) else {
            die("\(flag): empty tag name in \"\(value)\" — comma-separate "
                + "non-empty names (e.g. web,code)")
        }
        return pieces.map { validateTagName($0, flag: flag) }
            .joined(separator: ",")
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
    /// anything else (same pattern as `canonicalView` / `canonicalTheme`).
    static func parseCycleStack(_ value: String) -> String {
        let lower = value.lowercased()
        guard ["next", "prev"].contains(lower) else {
            die("window --cycle-stack: expected next | prev, got "
                + "\"\(value)\"")
        }
        return lower
    }

    /// Validate + canonicalise `name` against `allowed`, or loudly reject
    /// a typo with ``exit(2)`` so a fundamental error wins over later
    /// transient checks (e.g. server-not-running). `kind` names the value
    /// class in the error ("view" / "edge" / …); `suggest` adds an
    /// optional "did you mean" hint (only `theme` uses it today).
    static func canonicalOrDie(_ name: String, allowed: [String],
                               kind: String,
                               suggest: ((String) -> String?)? = nil) -> String {
        switch canonicalize(name, allowed: allowed) {
        case .success(let n): return n
        case .failure(.unknownValue(let v, let expected)):
            let hint = suggest?(v).map { " — did you mean \"\($0)\"?" } ?? ""
            die("unknown \(kind) \"\(v)\" — expected one of: "
                + expected.joined(separator: ", ") + hint)
        case .failure:
            die("unknown \(kind) \"\(name)\"")
        }
    }

    /// Validate + canonicalise a view name.
    static func canonicalView(_ name: String) -> String {
        canonicalOrDie(name, allowed: canonicalViews, kind: "view")
    }

    /// The four edges a rail can dock against (`--edge`).
    static let canonicalEdges = ["top", "bottom", "left", "right"]

    /// Validate + canonicalise a rail edge.
    static func canonicalEdge(_ name: String) -> String {
        canonicalOrDie(name, allowed: canonicalEdges, kind: "edge")
    }

    /// Shared integer-flag parser over `FacetCore.parseGeomInt`. Loud
    /// reject on non-integer / out-of-range. `positiveHint` is spliced into
    /// the ">0" message (e.g. `"1-indexed, "` for slot flags); empty for
    /// geometry flags. Wrapped by ``parseGeomInt`` / ``parsePositiveInt``
    /// which fix the two distinct UX wordings.
    static func parseIntFlag(_ value: String, flag: String,
                             requirePositive: Bool = false,
                             positiveHint: String = "") -> Int {
        switch FacetCore.parseGeomInt(value, requirePositive: requirePositive) {
        case .success(let n):
            return n
        case .failure(.notAnInteger(let v)):
            die("\(flag) expects an integer (got \"\(v)\")")
        case .failure(.notPositive(let n)):
            die("\(flag) must be > 0 (\(positiveHint)got \(n))")
        case .failure:
            die("\(flag) parse error")
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
        parseIntFlag(value, flag: flag, requirePositive: requirePositive)
    }

    /// Validate + canonicalise a theme name (with a "did you mean" hint).
    static func canonicalTheme(_ name: String) -> String {
        canonicalOrDie(name, allowed: canonicalThemeNames, kind: "theme",
                       suggest: suggest)
    }
}
