// Client mode — the `facet <subject> <verb>` subcommand runners
// (workspace / section / window / scratchpad): parse the argv,
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
        requireExactlyOneAction(count, subject: "workspace")
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

    /// Sub-command parser for ``facet section <flag>`` — address a section
    /// (a workspace, or an isolate desktop's synthesized section) by its
    /// 1-based tree-order index or its label. Verbs:
    ///   --focus N|LABEL    activate the section (numeric = index, else label)
    ///   --rename N LABEL   rename the Nth section (session-only display label)
    ///   --match N PREDICATE  set the Nth section's lens match (session-only;
    ///                        lens-only; empty PREDICATE reverts to config)
    /// One action per invocation, loud reject on zero / multiple / unknown.
    static func runSectionCommand(_ args: [String]) -> Never {
        var focusArg: String?           // payload: "index:N" or "label:LABEL"
        var renameArg: (Int, String)?   // (1-based index, new display label)
        var matchArg: (Int, String)?    // (1-based index, new lens predicate)
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--focus":
                focusArg = parseSectionFocus(cursor.value(for: "section --focus"))
            case "--rename":
                // Positional-2: INDEX then LABEL (same shape as
                // `workspace --rename` / `window --retag`). The index must be a
                // positive integer; the LABEL is loose (display string, spaces /
                // ':' OK — kept verbatim). Each value is consumed
                // unconditionally and validated; a missing one is a loud reject.
                let n = parsePositiveInt(
                    cursor.value(for: "section --rename INDEX"),
                    flag: "section --rename INDEX")
                let label = validateSectionLabelArg(
                    cursor.value(for: "section --rename LABEL"),
                    flag: "section --rename LABEL")
                renameArg = (n, label)
            case "--match":
                // Positional-2: INDEX then PREDICATE (t-0020). The index must be
                // a positive integer; the PREDICATE is a `facet filter`
                // WHERE-clause, parsed client-side so a typo fails fast with the
                // caret (an EMPTY predicate is the revert-to-config gesture).
                let n = parsePositiveInt(
                    cursor.value(for: "section --match INDEX"),
                    flag: "section --match INDEX")
                let predicate = parseSectionMatchArg(
                    cursor.value(for: "section --match PREDICATE"),
                    flag: "section --match PREDICATE")
                matchArg = (n, predicate)
            default:
                die("unknown `section` flag \"\(a)\" — see `facet --help`")
            }
        }
        let count = [focusArg != nil, renameArg != nil, matchArg != nil]
            .filter { $0 }.count
        requireExactlyOneAction(count, subject: "section")
        requireServerAlive()
        if let f = focusArg  { postControl("section-focus:" + f) }
        if let r = renameArg { postControl(encodeSectionRename(index: r.0, label: r.1)) }
        if let m = matchArg  { postControl(encodeSectionMatch(index: m.0, predicate: m.1)) }
        die("facet section: dispatch fell through (bug)")
    }

    /// FacetApp wrapper over the pure `validateSectionLabel` (FacetCore): loud-
    /// exit(2) on the all-whitespace / leading-dash reject, else return the
    /// label VERBATIM (loose — spaces / `:` / punctuation are fine for a display
    /// label). Mirrors `parseSectionFocusLabel`'s leading-dash flag-guard; the
    /// one intended difference is that a TRULY EMPTY `""` is allowed here (the
    /// `--rename` revert gesture), which `parseSectionFocusLabel` rejects.
    static func validateSectionLabelArg(_ value: String, flag: String) -> String {
        switch validateSectionLabel(value) {
        case .success(let label):
            return label
        case .failure:
            die("\(flag): expected a non-empty section label, got \"\(value)\"")
        }
    }

    /// t-0020: validate the PREDICATE of `facet section --match N PREDICATE` — a
    /// `facet filter` WHERE-clause. An EMPTY `""` is allowed (the revert-to-config
    /// gesture, mirrors `--rename`'s empty label); a leading `-` is rejected (an
    /// unrecognised flag that landed in the value slot). Otherwise it is CLASSIFIED
    /// client-side so a typo fails FAST (exit 2) before it reaches the server —
    /// defence in depth (the server re-classifies the same way):
    ///   • malformed SYNTAX → the caret.
    ///   • an unknown FIELD → rejected too. Runtime `--match` is STRICT (a typo'd
    ///     field always matches nothing — no legitimate use), unlike a config lens
    ///     `match` (which stays soft / degrade-don't-crash). This keeps the CLI and
    ///     the GUI "Edit match" editor consistent (loud typo rejection).
    /// Returned VERBATIM on `.ok`: the isolate desktop compiles the exact string at projection
    /// time (`"   "` is a valid match-all, kept as authored; only `""` is revert).
    static func parseSectionMatchArg(_ value: String, flag: String) -> String {
        if value.isEmpty { return value }            // revert-to-config gesture
        guard !value.hasPrefix("-") else {
            die("\(flag): expected a `facet filter` predicate, got \"\(value)\" "
                + "(looks like a flag — quote it or check the value)")
        }
        switch classifyMatchPredicate(value) {
        case .ok:
            return value
        case .unknownField(let fields):
            die("\(flag): unknown field: \(fields.joined(separator: ", ")) "
                + "— no such filter field (matches nothing)")
        case .malformed(let error):
            die("\(flag): " + error.caret(in: value))
        }
    }

    /// Parse the value of ``facet section --focus VALUE``. A positive integer
    /// is a 1-based tree-order index (`index:N`); anything else is a section
    /// label (`label:LABEL`, kept VERBATIM — section labels are config strings
    /// that allow spaces / punctuation). Numeric values are always indices —
    /// label a section non-numerically to reference it by name (yabai-style,
    /// mirrors `workspace --focus`).
    static func parseSectionFocus(_ value: String) -> String {
        if let n = Int(value), n > 0 { return "index:\(n)" }
        return "label:" + parseSectionFocusLabel(value, flag: "section --focus")
    }

    /// Validate the LABEL form of `facet section --focus N|LABEL` — the display
    /// label of a section (a workspace, or an isolate desktop's synthesized
    /// section). Section labels are config-authored TOML strings,
    /// so the policy is loose (spaces and most punctuation are fine, kept
    /// VERBATIM for the server's exact-label match): reject only an empty /
    /// all-whitespace value or a leading `-` (an unrecognised flag, caught
    /// earlier — kept here for defence). Existence is the server's call. Loud
    /// reject (exit 2). Sibling of `validateSectionLabelArg` (`--rename`'s
    /// LABEL), which allows a truly empty `""` as its revert gesture —
    /// `--focus` has nothing to revert to.
    static func parseSectionFocusLabel(_ value: String, flag: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            die("\(flag): expected a non-empty section label, got \"\(value)\"")
        }
        return value
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
        requireExactlyOneAction(count, subject: "window")
        // `--follow` is a modifier on `--move-to`, not a standalone
        // action: move the window *and* switch to its new workspace.
        // Loud reject when used without a destination.
        if follow && moveToArg == nil {
            die("facet window: --follow only applies with --move-to N — "
                + "see `facet --help`")
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
        requireExactlyOneAction(count, subject: "scratchpad")
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
