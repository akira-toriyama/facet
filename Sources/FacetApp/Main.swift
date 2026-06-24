// facet entry point. Two modes:
//
//   1. **Client mode** — at least one recognised CLI flag was
//      passed. Post the matching control notification to the
//      running server instance, then ``exit(0)``. The server-side
//      observer (``Controller.installCLIControl``) routes it.
//
//   2. **Server mode** — no CLI flags. Wake the AppKit run loop,
//      load config, build the native adapter + Controller, and
//      boot in agent-only mode (no panel until the CLI asks for a
//      view).
//
// ``@main enum FacetApp`` (NOT top-level code in main.swift) so
// XCTest can ``@testable import FacetApp`` once tests land without
// the act of importing the executable spawning a panel. **Don't
// reintroduce main.swift.**
//
// CLI surface (canonical-only — no aliases). Grammar is yabai-style
// space-separated values: `--flag VALUE`, never `--flag=VALUE` (#227).
// See `printHelp()` for the user-facing reference; the categories
// below are the quick orientation:
//
//   Views   : --view NAME / --hide NAME / --toggle NAME
//   Theme   : --theme NAME
//   Server  : --quit / --reload / --resign / --help
//   Query   : facet query (read-only, no `--`)
//   Workspace : facet workspace --focus N|NAME|next|prev|recent / --layout NAME
//               / --retile / --balance / --rotate 90|180|270
//               / --mirror horizontal|vertical / --add / --remove TARGET
//               / --rename NAME / --move N
//   Window    : facet window --move-to N [--follow] / --mark NAME
//               / --focus-mark NAME / --unmark NAME / --toggle-float /
//               --toggle-sticky / --toggle-orientation /
//               --cycle-stack next|prev / --grow-master / --shrink-master
//               / --inc-master / --dec-master
//               / --focus up|down|left|right / --move up|down|left|right
//               / --tag NAME / --untag NAME / --toggle-tag NAME
//               / --retag OLD NEW
//   Scratchpad: facet scratchpad --stash NAME / --toggle NAME
//               / --release NAME
//   Lens      : facet lens NAME (activate a type="lens" section) / --clear
//   Section   : facet section --focus N|LABEL (index|label, workspace or lens)
//
// ``--show`` / ``--hide`` / ``--toggle`` bare are NOT supported —
// every view op must specify NAME explicitly. Shell aliases handle
// shorthand if the user wants it. (The tree opens directly in
// keyboard-nav mode; there is no ``--active`` modifier — it was
// folded into ``--view tree`` itself.)
//
// Same-module extension files (#182, split further in P8-3): the
// client-mode `post*` primitives + canonical / parse helpers live in
// FacetApp+Client.swift, the read-only `facet query` projections in
// FacetApp+ClientQuery.swift, the `facet <subject> <verb>` subcommand
// runners in FacetApp+ClientCommands.swift, and ``--resign`` in
// FacetApp+Resign.swift. This file keeps help / version, server
// liveness, and the ``main()`` entry.

import AppKit
import FacetCore
import FacetAccessibility
import FacetAdapterNative
import FacetView
import FacetViewTree
import FacetViewGrid
import FacetViewRail

@main
enum FacetApp {

    // MARK: - Canonical names

    /// Views the user can address with ``--view`` / ``--hide`` /
    /// ``--toggle``. Adding a new view (dock, palette, …) only
    /// requires extending this list + the server-side
    /// ``Controller.dispatchView/Hide/Toggle`` switches.
    static let canonicalViews = ["tree", "grid", "rail"]

    // MARK: - Help / version

    /// Print the marketing version (`CFBundleShortVersionString`, stamped
    /// from the git tag by package.sh) and exit. A binary run outside the
    /// .app bundle (e.g. a raw `.build/...` dev build) has no Info.plist,
    /// so it reports a development build instead of a stale number.
    static func printVersion() -> Never {
        let v = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        print("facet \(v ?? "(development build)")")
        exit(0)
    }

    static func printHelp() -> Never {
        let help = """
        facet — Swift workspace + window manager for macOS.

        USAGE
          facet [COMMAND]                    client mode (post to server)
          facet                              server mode (start the app)

        VIEW OPERATIONS                      NAME ∈ tree | grid | rail
          facet --view NAME                  open NAME (idempotent)
          facet --hide NAME                  close NAME
          facet --toggle NAME                toggle NAME

          --view tree opens directly in keyboard nav: facet takes key
          focus immediately (Spotlight-style) so the arrow keys,
          Enter and search (s) work the moment it appears. Acting on a
          window — click a row or Enter a selection — hands key back
          first, so same-app focus still works. (Right-clicking the
          "Desktop N" header also opens Search.)

          --edge top|bottom|left|right is a --view rail modifier:
          dock the rail's workspace strip against that screen edge
          (default bottom, or [rail] edge in config). Top/bottom
          browse with ←/→, left/right with ↑/↓. Example:
            facet --view rail --edge left

          --loading MS is a --view tree modifier: paint a loading
          skeleton over the tree, cleared as soon as new content
          loads OR after MS milliseconds (0 = off), whichever comes
          first — so MS is just a safety cap. Fire it just BEFORE a
          mac-desktop switch (bind it ahead of your switch hotkey) so
          the panel shows a placeholder during the switch instead of
          the previous mac desktop's tree. Only valid with
          --view tree; grid / rail exit 2.
          Example:
            facet --view tree --loading 2000

          GEOMETRY MODIFIERS (--view tree only; grid ignores)
            --pos-x N --pos-y N --width N --height N
              Place the tree panel at exact screen coords with explicit
              size. TOP-LEFT origin: (0,0) = top-left of the main
              screen, x right, y DOWN. Coords may be negative (an off-
              main screen). All four are required together (none / all).
              Use case: screenshot automation, deterministic UI tests.
              (Persist via `[tree]` config.)
              Example (8 px in from the top-left):
                facet --view tree --pos-x 8 --pos-y 8 \\
                       --width 400 --height 600

          NAME is required for every view op (no implicit "tree").
          Shell aliases handle shorthand if you want it:
            alias fa='facet --view tree'
            alias fg='facet --view grid'

        WORKSPACE                            (active / target workspace)
          facet workspace --focus N          switch to workspace N
                                             (1-indexed; idempotent)
          facet workspace --focus NAME       switch by name (stable
                                             across reorder)
          facet workspace --focus next       step to next / previous
          facet workspace --focus prev       workspace (wraps)
          facet workspace --focus recent     return to the previous one
          facet workspace --layout NAME      set the workspace's layout
                                             (bsp | stack | master-left |
                                             master-right | master-top |
                                             master-bottom | master-center |
                                             grid | spiral | float)
          facet workspace --retile           re-apply the layout
                                             (no-op when float)
          facet workspace --balance          reset master ratio / count
                                             to the even baseline
          facet workspace --rotate 90|180|270  rotate the bsp tree
                                             clockwise (bsp only)
          facet workspace --mirror horizontal|vertical  flip the bsp
                                             tree left↔right / top↔bottom
          facet workspace --add              append a new workspace
          facet workspace --remove TARGET    remove a workspace — TARGET is
                                             `current` (the active one) or a
                                             1-based index; its windows move
                                             to a neighbour
          facet workspace --rename NAME      rename the active workspace
          facet workspace --move N           move the active workspace to
                                             position N (reorder)

        LENS                                 (the active visibility filter;
                                             exclusive section model)
          facet lens NAME                    activate the `type="lens"` section
                                             labelled NAME — its cross-workspace
                                             union is gathered into view and the
                                             out-of-lens windows are anchor-parked
                                             (an unknown label is rejected)
          facet lens --clear                 deactivate the active lens →
                                             back to the active workspace
          facet section --focus N            focus the Nth section in tree
                                             order (1-based; workspace or lens)
          facet section --focus LABEL        focus the section labelled LABEL
                                             (numeric = index; else label)

        WINDOW                               (focused window)
          facet window --move-to N           move it to workspace N
          facet window --move-to N --follow  …and switch there too
          facet window --mark NAME           tag it with a mark (label;
                                             1:1 — one mark per window)
          facet window --focus-mark NAME     jump focus to the marked
                                             window (switches WS if needed)
          facet window --unmark NAME         remove a mark
          facet window --tag NAME            add tag NAME (creates NAME if
                                             new; #-prefix ok, e.g. --tag
                                             #190). Tags are a free-form
                                             window attribute used by lens
                                             `match='tag~=NAME'`.
          facet window --untag NAME          remove tag NAME (rejects an
                                             unknown tag)
          facet window --toggle-tag NAME     add / remove tag NAME
                                             (creates NAME if new)
          facet window --retag OLD NEW       replace tag OLD with NEW in
                                             one step (OLD must exist;
                                             creates NEW; OLD==NEW is a
                                             no-op)
          facet window --toggle-float        flip its float flag
          facet window --toggle-sticky       pin it across every workspace
                                             (PiP / timer / chat); flip off
                                             to drop it as a tiled window
          facet window --focus DIR           move focus to the tiled
                                             neighbour up|down|left|right
                                             (no-op at an edge)
          facet window --move DIR            swap the focused window with
                                             that neighbour (up|down|
                                             left|right)
          facet window --toggle-orientation  bsp: rotate the focused
                                             window's parent split
          facet window --cycle-stack next    rotate stack to next member
          facet window --cycle-stack prev    rotate stack to previous
                                             member (stack only)
          facet window --grow-master         widen the master area +0.05
          facet window --shrink-master       narrow the master area -0.05
          facet window --inc-master          one more window in master
          facet window --dec-master          one fewer window in master
                                             (master-* engines only)

        SCRATCHPAD                           (named hidden shelves)
          facet scratchpad --stash NAME      park the focused window onto
                                             a named shelf (hides it)
          facet scratchpad --toggle NAME     summon it onto the current
                                             workspace, or re-park it if
                                             already visible here
          facet scratchpad --release NAME    drop it off the shelf as a
                                             tiled window of this workspace

          facet doesn't bind keyboard shortcuts. Wire one up with
          your shortcut tool of choice (skhd, Karabiner-Elements,
          hammerspoon, …):
            # ~/.config/skhd/skhdrc
            ctrl + alt - 1 : facet workspace --focus 1
            ctrl + alt - 2 : facet workspace --focus 2
            ctrl + shift + alt - 1 : facet window --move-to 1

        QUERY
          facet query                        print server's view of the
                                             world: backend, theme,
                                             workspaces (active marker +
                                             window counts), last error,
                                             snapshot timestamp. Reads
                                             /tmp/facet-status.json
                                             (server writes atomically).
                                             Greppable line format.
          facet query --windows              print EVERY window as a flat
                                             JSON array — raw props +
                                             per-window facet state (or
                                             null when unmanaged), across
                                             all mac desktops. Pipe to jq:
                                               facet query --windows \\
                                                 | jq '.[]
                                                   | select(.facet.tags[]?
                                                            == "190")'
          facet query --windows --filter EXPR
                                             post-filter that array with a
                                             facet filter expression (a
                                             WHERE clause): field op value
                                             atoms (= ~= ^= $= *= |=), bare
                                             presence (tag / floating / …),
                                             joined by and / or / not / ().
                                             Case-insensitive (trailing ` s`
                                             = sensitive). LOUD-but-non-fatal
                                             — a bad expression prints a
                                             caret to stderr and shows all
                                             windows (exit 0). Examples:
                                               facet query --windows \\
                                                 --filter 'app=Safari'
                                               facet query --windows \\
                                                 --filter 'tag~=web and not floating'
          facet query --tags                 print the defined tag
                                             vocabulary as a JSON array
                                             (declaration order); [] when
                                             no tags are defined.

        SERVER CONTROLS
          facet --theme NAME                 13 themes: terminal, chomp,
                                             rainbow, cobalt2,
                                             shades-of-purple, tokyo-hack,
                                             github-dark, dracula,
                                             catppuccin-mocha, gruvbox,
                                             github-light, catppuccin-latte,
                                             system (+ "random"). session
                                             only; edit config.toml
          facet --quit                       terminate the server
          facet --reload                     re-read config.toml + apply
                                             (theme / preview-mode). The
                                             server also auto-reloads on
                                             file edits via FSEvents — this
                                             flag is the explicit trigger
                                             for scripts that want a
                                             deterministic moment.
          facet --resign                     re-sign Facet.app with the
                                             persistent "facet Local
                                             Signing" identity + restart
                                             (run once after `brew install`
                                             / upgrade — Homebrew sandbox
                                             can't set up the cert itself)

          facet --version                    print the version + exit
          facet --help                       this help

        EXIT CODES
          0   success (DNC posted, server started, or query printed)
          1   `--resign` codesign failed (see stderr)
          2   unknown flag / view / theme name, a bad value, a missing
              argument, or a dropped legacy `--flag=VALUE` form (stderr
              lists what was expected)
          3   no server running for the requested client-mode action
              (start one with ./run.sh); also: `facet query` when
              the data file is missing
          4   query data present but malformed (server bug —
              `./stop.sh && ./run.sh`)

        CONFIG
          ~/.config/facet/config.toml is the single source of truth.
          Install template:
          https://github.com/akira-toriyama/facet/blob/main/config.toml

        DOCS
          https://github.com/akira-toriyama/facet
        """
        print(help)
        exit(0)
    }

    // MARK: - Server liveness

    /// True when a facet server process (bundle or raw SwiftPM
    /// binary) is currently running. Uses ``pgrep`` (part of
    /// macOS — no Homebrew dependency). Self-aware: this process's
    /// own PID is excluded so a CLI invocation doesn't mis-detect
    /// itself as the server.
    static func isServerRunning() -> Bool {
        let myPid = ProcessInfo.processInfo.processIdentifier
        // Covers both .app bundles (Facet.app / Facet-dev.app)
        // and raw SwiftPM builds (.build/debug/facet etc.).
        let patterns = ["/Contents/MacOS/facet", "\\.build/.*/facet"]
        for pattern in patterns {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", pattern]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                // pgrep itself unavailable → can't tell; assume
                // alive so we don't false-positive a missing
                // server message on broken systems.
                return true
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8)
            else { continue }
            let pids = text.split(separator: "\n")
                .compactMap { Int32($0) }
            if pids.contains(where: { $0 != myPid }) { return true }
        }
        return false
    }

    /// Exit (3) with a helpful stderr message when no server is
    /// running. Called before every client-mode post so silent
    /// DNC broadcasts to nobody don't leave the user wondering
    /// why their hotkey did nothing.
    static func requireServerAlive() {
        if isServerRunning() { return }
        let msg = "facet: server not running — start it with "
            + "`./run.sh` (or `facet` alone for server mode)\n"
        FileHandle.standardError.write(Data(msg.utf8))
        exit(3)
    }

    /// Enforce exactly-one-action for a subject-verb subcommand. `count`
    /// = number of set action flags; loud-rejects (exit 2) on zero or
    /// multiple, byte-identically to the per-runner guards it replaces.
    static func requireExactlyOneAction(_ count: Int, subject: String) {
        guard count > 0 else {
            die("facet \(subject): no action specified — see `facet --help`")
        }
        guard count == 1 else {
            die("facet \(subject): pick one action per invocation — "
                + "see `facet --help`")
        }
    }

    /// stderr message + exit(2). Always prefixes with ``facet:``.
    static func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("facet: \(msg)\n".utf8))
        exit(2)
    }

    // MARK: - Entry

    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())

        // Help / version short-circuit everything else.
        if argv.contains("--help") { printHelp() }
        if argv.contains("--version") { printVersion() }

        // Set debug mode first so any subsequent code path (incl.
        // the validators that fire from client mode) can use
        // ``Log.debug``. Read from the ``FACET_DEBUG`` env var (set
        // by run.sh) — there is no CLI flag, so a brew / raw
        // ``open Facet.app`` launch stays quiet by default.
        if ProcessInfo.processInfo.environment["FACET_DEBUG"] != nil {
            debugMode = true
        }

        // Two-pass: collect all flags first so the dispatch below
        // is order-independent (e.g. ``--view tree --theme dracula``
        // and ``--theme dracula --view tree`` both work).
        var viewArg: String?
        var hideArg: String?
        var toggleArg: String?
        var themeArg: String?
        var edgeArg: String?            // rail dock edge (--edge ); nil = config default
        var loadingArg: Int?            // nil = not requested; ms otherwise
        var quitFlag = false
        var reloadFlag = false
        var posX: Int?, posY: Int?, width: Int?, height: Int?

        // `--resign` is a one-shot maintenance subcommand. Handle it
        // up-front (before the per-flag dispatcher) so a typo in
        // another arg doesn't shadow the re-sign with the loud-reject
        // path. Same workflow as chord 0.3.3 / stroke 2.3.0:
        // Homebrew's build sandbox can't write to the user's login
        // keychain, so brew installs ad-hoc-sign and TCC re-prompts
        // on every upgrade; `facet --resign` swaps the ad-hoc
        // signature for the persistent "facet Local Signing"
        // identity and restarts the daemon, in one step.
        if argv.contains("--resign") { runResign() }

        // `--emit-schema` is a one-shot: print the `config.toml` JSON
        // Schema (Draft-07) to stdout and exit. Generated from the same
        // declarative `configSpec` that decodes the config, so the two
        // can't drift. The repo regenerates `config.schema.json` with
        // `facet --emit-schema > config.schema.json`.
        // Intentionally absent from `facet --help`: it's a repo/dev
        // regeneration tool, not user surface (the sidecar is auto-written
        // next to the user config at launch by `installSchema()`).
        if argv.contains("--emit-schema") {
            print(FacetConfig.jsonSchema, terminator: "")
            exit(0)
        }

        // Sub-command dispatch: `facet window <flag>` opens a
        // window-scoped flag namespace so window ops don't share
        // surface area with workspace / view flags. Keeps the door
        // open for `--close` / `--float` / etc. later.
        if argv.first == "window" {
            runWindowCommand(Array(argv.dropFirst()))
        }
        // `facet workspace <flag>` — workspace-scoped verbs (focus /
        // layout / retile). Subject-verb mirror of `facet window`.
        if argv.first == "workspace" {
            runWorkspaceCommand(Array(argv.dropFirst()))
        }
        // `facet scratchpad <flag>` — named hidden shelves (stash /
        // toggle / release). A new subject (not a `window` verb) because
        // it operates on a named slot, not the focused window alone.
        if argv.first == "scratchpad" {
            runScratchpadCommand(Array(argv.dropFirst()))
        }
        // `facet lens <flag>` — the active visibility filter (exclusive
        // section model): `facet lens NAME` activates the `type="lens"`
        // section labelled NAME, `facet lens --clear` deactivates it.
        if argv.first == "lens" {
            runLensCommand(Array(argv.dropFirst()))
        }
        // `facet section <flag>` — address a section (workspace OR lens) by its
        // 1-based tree-order index or its label: `facet section --focus N|LABEL`.
        // The unified handle over `workspace --focus` / `lens NAME`.
        if argv.first == "section" {
            runSectionCommand(Array(argv.dropFirst()))
        }
        // Read-only query sub-command. Plain noun (no `--`) because it
        // returns data rather than triggering a verb. (#227: renamed
        // from `status`; the former verb is gone — a bare `facet status`
        // now falls through to the loud unknown-flag reject below.)
        // Bare `facet query` prints the human-readable status snapshot;
        // `facet query --windows` prints the full per-window JSON (#223).
        if argv.first == "query" {
            runQuery(Array(argv.dropFirst()))
        }

        // Space-separated grammar (#227): each value-bearing flag
        // consumes its next token via the cursor (strict consumption —
        // a negative coord / a `0` reads fine). Names are canonicalised
        // + validated at parse time (not post time) so typos exit 2
        // BEFORE the server-alive check — a fundamental error should
        // win over a transient one.
        var cursor = ArgCursor(argv)
        while let a = cursor.next() {
            switch a {
            case "--quit":              quitFlag = true
            case "--reload":            reloadFlag = true
            case "--loading":
                let raw = cursor.value(for: "--loading")
                guard let ms = Int(raw), ms >= 0 else {
                    die("--loading expects a non-negative integer "
                        + "(milliseconds; 0 = off) — got \"\(raw)\"")
                }
                loadingArg = ms
            case "--view":
                viewArg = canonicalView(cursor.value(for: "--view"))
            case "--hide":
                hideArg = canonicalView(cursor.value(for: "--hide"))
            case "--toggle":
                toggleArg = canonicalView(cursor.value(for: "--toggle"))
            case "--edge":
                edgeArg = canonicalEdge(cursor.value(for: "--edge"))
            case "--theme":
                themeArg = canonicalTheme(cursor.value(for: "--theme"))
            case "--pos-x":
                posX = parseGeomInt(cursor.value(for: "--pos-x"), flag: "--pos-x")
            case "--pos-y":
                posY = parseGeomInt(cursor.value(for: "--pos-y"), flag: "--pos-y")
            case "--width":
                width = parseGeomInt(cursor.value(for: "--width"), flag: "--width",
                                     requirePositive: true)
            case "--height":
                height = parseGeomInt(cursor.value(for: "--height"), flag: "--height",
                                      requirePositive: true)
            default:
                // Loud reject — typos / dropped legacy spellings
                // (``--show``, the old `--flag=VALUE` form, a bare
                // `status`) hit here. Server mode falling through
                // silently would launch a second instance by accident.
                let msg = "facet: unknown flag \"\(a)\" — see "
                    + "`facet --help`\n"
                FileHandle.standardError.write(Data(msg.utf8))
                exit(2)
            }
        }

        // ``--edge`` only means something for the rail (it picks the
        // strip's screen edge); requiring ``--view rail`` keeps a stray
        // ``--edge`` from silently doing nothing on tree / grid. A
        // ``--toggle rail`` gets a clearer hint — the rail was targeted,
        // but ``--edge`` rides the show (``--view rail``), not toggle.
        if edgeArg != nil && viewArg != "rail" {
            let hint = toggleArg == "rail"
                ? "--edge applies to --view rail (show), not --toggle rail"
                : "--edge requires --view rail"
            let msg = "facet: \(hint) — see `facet --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }

        // ``--loading`` is a modifier on ``--view tree`` only — the
        // skeleton lives in ``SidebarView``; grid / rail can't paint
        // it, so a stray ``--loading`` on another view exits 2 rather
        // than silently doing nothing.
        if loadingArg != nil && viewArg != "tree" {
            let msg = "facet: --loading requires --view tree — "
                + "see `facet --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }

        // Geom flags are all-or-nothing modifiers; only meaningful
        // with --view tree (grid silently ignores them).
        // Partial sets (e.g. only --width) are rejected loudly so
        // the user doesn't end up with a half-applied frame.
        var geom: (Int, Int, Int, Int)? = nil
        switch validateGeom(posX: posX, posY: posY,
                            width: width, height: height) {
        case .none:
            break
        case .complete(let x, let y, let w, let h):
            if viewArg == nil {
                die("geometry flags require --view NAME — "
                    + "see `facet --help`")
            }
            geom = (x, y, w, h)
        case .partial(let count):
            die("geometry flags are all-or-nothing — specify "
                + "--pos-x, --pos-y, --width, --height together "
                + "(got \(count)/4)")
        }

        // Any client-mode action is about to fire — make sure a
        // server is actually listening, otherwise the DNC post
        // would silently broadcast to nobody and exit 0,
        // leaving a dead-hotkey mystery. Server mode (no client
        // flag at all) is unaffected; this process is the one
        // about to become the server.
        let anyClientAction = themeArg != nil || quitFlag || reloadFlag
            || viewArg != nil || hideArg != nil || toggleArg != nil
        if anyClientAction { requireServerAlive() }

        // Dispatch. Each ``post*`` returns ``Never`` (calls
        // ``exit``), so the FIRST matched branch wins — the rest
        // is unreachable. Precedence below mirrors usual
        // expectation: ``--theme`` / ``--quit`` are tried first,
        // then view ops. To combine (e.g. theme + view in one
        // call), the user issues two separate invocations.
        if let s = themeArg          { postTheme(s) }
        if quitFlag                  { postControl("quit") }
        if reloadFlag                { postControl("reload") }

        if let v = viewArg           { postView(v, loadingMs: loadingArg, geom: geom, edge: edgeArg) }
        if let h = hideArg           { postHide(h) }
        if let t = toggleArg         { postToggle(t) }

        // Server mode. Reached only when no client flag matched.

        // Refresh the taplo schema sidecar next to the user config so
        // editor completion/validation just works (idempotent; writes
        // only on change, and the watcher tracks config.toml not this
        // sibling, so no reload churn). Best-effort — never blocks start.
        FacetConfig.installSchema()

        let cfg = FacetConfig.load()
        // Fail Fast (Rule of Repair): refuse to start on an incoherent
        // config with a loud `exit 2` (usage error) rather than silently
        // running a degraded default. No fatal checks remain today, but
        // the seam is kept so a future check lands without re-wiring the
        // entry point.
        let configErrors = cfg.fatalConfigErrors()
        if !configErrors.isEmpty {
            for e in configErrors {
                FileHandle.standardError.write(Data("facet: \(e)\n".utf8))
            }
            exit(2)
        }
        // config.toml is the single source of truth for theme. Runtime
        // `--theme ...` overrides it for the session only (no UserDefaults
        // persist); to make a theme stick, edit config.toml. PR-B: the
        // theme is resolved PER SURFACE into the Controller's palette
        // boxes (`[tree]/[grid]/[rail].theme`), not the legacy module-level
        // `pal`, so there is no global seed here anymore.

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        installMainMenu()
        AX.ensureTrusted()

        // Single backend since Phase ε (v2.0.0). `WindowBackend`
        // remains as a unit-test stub seam (BackendTests), but
        // ships with one implementation.
        //
        // `FACET_BACKEND` was the env switch during the
        // multi-PR α→ε rollout; we still read it once for a
        // friendly migration hint to users who carried the env
        // var over from v1.x and would otherwise wonder why
        // their shell setting "did nothing".
        if let legacy = ProcessInfo.processInfo
            .environment["FACET_BACKEND"], !legacy.isEmpty
        {
            Log.line("FACET_BACKEND=\(legacy) is no longer used "
                + "(v2.0 retired the rift adapter; native is "
                + "the only backend) — safe to unset")
        }
        let backend: any WindowBackend = NativeAdapter(config: cfg)
        let controller = Controller(backend: backend, config: cfg)
        controller.start()

        // facet always boots in agent-only mode: no panel, no overlay,
        // running and waiting for a ``facet --view tree|grid|rail`` (or a
        // chord summon) to bring something on screen. There is no
        // auto-open-at-launch config — a panel only ever appears via an
        // explicit summon, which always enters keyboard nav, so "the tree
        // is showing but the keyboard is dead" is now unrepresentable.
        // (The old `default-view` key opened a panel at launch but could
        // only do so PASSIVELY — facet must not steal focus the instant
        // it starts — which made it keyboard-dead; removing it dissolves
        // that whole class of bug. See memory config-default-behavior.)
        controller.setHidden(true)

        app.run()
    }

    /// Install a minimal main menu (App + Edit) at startup.
    ///
    /// facet runs `.accessory` (LSUIElement), so with no main menu the
    /// standard editing key equivalents (⌘A/C/V/X/Z, ⇧⌘Z) are never
    /// dispatched to a text field's field editor — that's why the tree
    /// `s` search box couldn't select-all / copy / paste / undo. The
    /// Edit menu's items target the first responder (action sent to
    /// `nil`), so when the field editor is focused they drive its
    /// `selectAll:`/`copy:`/`paste:`/`cut:`/`undo:`/`redo:`. The menu
    /// bar is hidden in `.accessory`; it only appears (and these key
    /// equivalents fire) once the tree enters keyboard nav (`.regular` +
    /// activate, Controller.enterActive) — which is exactly when the
    /// search box is usable, so the shortcuts work where they're needed.
    @MainActor
    private static func installMainMenu() {
        let mainMenu = NSMenu()

        // App menu (the bold first slot) — conventional + carries ⌘Q.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit facet",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu — the reason this whole menu exists (see above).
        // These are the standard first-responder editing actions;
        // targeting nil routes them through the responder chain to
        // whatever field editor is focused. `undo:`/`redo:` aren't
        // declared @objc on any nameable class, so they stay string
        // selectors (the field editor handles them via its undo manager).
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo",
                                    action: Selector(("redo:")),
                                    keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
