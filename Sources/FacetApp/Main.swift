// facet entry point. Two modes:
//
//   1. **Client mode** — at least one recognised CLI flag was
//      passed. Post the matching control notification to the
//      running server instance, then ``exit(0)``. The server-side
//      observer (``Controller.installCLIControl``) routes it.
//
//   2. **Server mode** — no CLI flags. Wake the AppKit run loop,
//      load config, build the native adapter + Controller, and
//      apply ``default-view`` from config (omitted → agent-only,
//      no panel until the CLI asks).
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
//   Views   : --view NAME [--active] / --hide NAME / --toggle NAME
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
//                 (tag mode only — [grouping] by="tag")
//   Scratchpad: facet scratchpad --stash NAME / --toggle NAME
//               / --release NAME
//   Lens      : facet lens --only/--add/--remove/--toggle A[,B,…] / --all
//               (tag mode only — [grouping] by="tag")
//   Tag       : facet tag --add NAME / --remove NAME / --rename OLD NEW
//               (tag mode only — edits the tag vocabulary)
//
// ``--active`` is a modifier; ``facet --active`` standalone is
// NOT supported (would be ambiguous about which view to activate).
// Same for ``--show`` / ``--hide`` / ``--toggle`` bare — every
// view op must specify NAME explicitly. Shell aliases handle
// shorthand if the user wants it.
//
// Same-module extension files (#182): the client-mode posting /
// subcommand runners / parse helpers live in FacetApp+Client.swift,
// ``--resign`` in FacetApp+Resign.swift. This file keeps help /
// version, server liveness, and the ``main()`` entry.

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
          facet --view NAME [--active]       open NAME (idempotent)
          facet --hide NAME                  close NAME
          facet --toggle NAME                toggle NAME

          In tag mode ([grouping] by="tag") the tree is the only view —
          grid / rail aren't available, so --view / --hide / --toggle
          with grid|rail exit 2.

          --active is a modifier — meaningful only with --view tree.
          A plain click on the tree only focuses/selects a row; it
          does NOT enter keyboard nav. Nav + search (s) + tag-manage
          (t) are entered via --active, or by right-clicking the
          "Desktop N" header (Search / Manage tags). --active takes
          key focus immediately so a hotkey can jump straight in
          (Spotlight-style). --view grid silently ignores; the
          overlay is always key/active.

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
            alias fa='facet --view tree --active'
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

        LENS                                 (tag mode: which tags show)
          facet lens --only A[,B,…]          show exactly these tags
                                             (replace the shown set)
          facet lens --add A[,B,…]           union these into the shown set
          facet lens --remove A[,B,…]        drop these from the shown set
          facet lens --toggle A[,B,…]        flip each tag in / out
          facet lens --all                   show every tag
                                             (multiple tags = comma-joined;
                                             one unknown name rejects the
                                             whole command; emptying the
                                             lens shows untagged windows;
                                             requires [grouping] by="tag";
                                             no-op under by="workspace")

        TAG                                  (tag mode: the tag vocabulary)
          facet tag --add NAME               declare tag NAME (no window
                                             touched; idempotent)
          facet tag --remove NAME            delete NAME — strips it from
                                             every window; its bit is freed
                                             for a later tag to reuse
          facet tag --rename OLD NEW         rename OLD to NEW in place
                                             (windows keep the tag); rejects
                                             an unknown OLD or an NEW that
                                             already exists
                                             (requires [grouping] by="tag")

        WINDOW                               (focused window)
          facet window --move-to N           move it to workspace N
          facet window --move-to N --follow  …and switch there too
          facet window --mark NAME           tag it with a mark (label;
                                             1:1 — one mark per window)
          facet window --focus-mark NAME     jump focus to the marked
                                             window (switches WS if needed)
          facet window --unmark NAME         remove a mark
          facet window --tag NAME            add tag NAME (tag mode;
                                             creates NAME if new; #-prefix
                                             ok, e.g. --tag #190)
          facet window --untag NAME          remove tag NAME (rejects an
                                             unknown tag)
          facet window --toggle-tag NAME     add / remove tag NAME
                                             (creates NAME if new)
                                             (requires [grouping] by="tag")
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
          facet query --tags                 print the defined tag
                                             vocabulary as a JSON array
                                             (declaration order); [] in
                                             workspace mode.
          facet query --lens                 print the current lens as
                                             JSON {"tags":[…],
                                             "showsAll":bool}; null in
                                             workspace mode. showsAll is
                                             true for a show-everything
                                             lens (floor-only or --all).

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
                                             (theme / preview-mode).
                                             default-view needs a real
                                             restart. The server also
                                             auto-reloads on file edits
                                             via FSEvents — this flag is
                                             the explicit trigger for
                                             scripts that want a
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

    /// Fail Fast (M11-3, design Q7): reject a subject that doesn't match
    /// the configured grouping mode. `lens` is tag-mode-only; the
    /// `workspace` switch / layout / management verbs are
    /// workspace-mode-only (tag mode has no workspaces — running them
    /// would scramble the catalog's park state). Reads the same config
    /// the server seeded from; a mismatch exits 2 (usage) rather than
    /// silently no-opping server-side.
    static func requireGrouping(_ want: Grouping, subject: String) {
        let have = FacetConfig.load().effectiveGrouping
        guard have == want else {
            die("facet \(subject) requires [grouping] by=\"\(want.rawValue)\""
                + " — current config is \(have.rawValue) mode")
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
        // is order-independent (``--view tree --active`` and
        // ``--active --view tree`` both work).
        var viewArg: String?
        var hideArg: String?
        var toggleArg: String?
        var styleArg: String?
        var activeFlag = false
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
        // `facet lens <flag>` — tag-mode visibility (only / toggle /
        // all). A new subject: the lens selects which tags are shown,
        // the tag-mode analog of `workspace --focus`.
        if argv.first == "lens" {
            runLensCommand(Array(argv.dropFirst()))
        }
        // `facet tag <flag>` — tag-vocabulary management (add / remove /
        // rename). A new subject: it edits the tag SET itself, the
        // tag-mode analog of `workspace --add/--remove/--rename`.
        // (`window --tag` attaches a tag to the focused window; `tag
        // --add` declares one with no window.)
        if argv.first == "tag" {
            runTagCommand(Array(argv.dropFirst()))
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
            case "--active":            activeFlag = true
            case "--loading":
                let raw = cursor.value(for: "--loading")
                guard let ms = Int(raw), ms >= 0 else {
                    die("--loading expects a non-negative integer "
                        + "(milliseconds; 0 = off) — got \"\(raw)\"")
                }
                loadingArg = ms
            case "--resign", "--emit-schema":
                break                                       // handled above
            case "--view":
                viewArg = canonicalView(cursor.value(for: "--view"))
            case "--hide":
                hideArg = canonicalView(cursor.value(for: "--hide"))
            case "--toggle":
                toggleArg = canonicalView(cursor.value(for: "--toggle"))
            case "--edge":
                edgeArg = canonicalEdge(cursor.value(for: "--edge"))
            case "--theme":
                styleArg = canonicalStyle(cursor.value(for: "--theme"))
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

        // ``--active`` is a modifier only — standalone is rejected
        // (would be ambiguous about which view to activate).
        if activeFlag && viewArg == nil {
            let msg = "facet: --active requires --view NAME — "
                + "see `facet --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
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
        // with --view tree (grid silently ignores, same as --active).
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

        // grid / rail are workspace-only surfaces — there is no grid or
        // rail under `[grouping] by="tag"` (tag mode shows the tree
        // only). Reject any view op that names them loudly (exit 2)
        // BEFORE the server-alive check, so the usage error wins over a
        // "server not running" (exit 3) — the op is wrong regardless of
        // server state. Symmetric across --view / --hide / --toggle
        // (clig.dev consistency): naming grid|rail is the same mistake
        // whichever verb wraps it.
        for (flag, value) in [("--view", viewArg), ("--hide", hideArg),
                              ("--toggle", toggleArg)] {
            if let v = value, v == "grid" || v == "rail" {
                requireGrouping(.workspace, subject: "\(flag) \(v)")
            }
        }

        // Any client-mode action is about to fire — make sure a
        // server is actually listening, otherwise the DNC post
        // would silently broadcast to nobody and exit 0,
        // leaving a dead-hotkey mystery. Server mode (no client
        // flag at all) is unaffected; this process is the one
        // about to become the server.
        let anyClientAction = styleArg != nil || quitFlag || reloadFlag
            || viewArg != nil || hideArg != nil || toggleArg != nil
        if anyClientAction { requireServerAlive() }

        // Dispatch. Each ``post*`` returns ``Never`` (calls
        // ``exit``), so the FIRST matched branch wins — the rest
        // is unreachable. Precedence below mirrors usual
        // expectation: ``--theme`` / ``--quit`` are tried first,
        // then view ops. To combine (e.g. theme + view in one
        // call), the user issues two separate invocations.
        if let s = styleArg          { postStyle(s) }
        if quitFlag                  { postControl("quit") }
        if reloadFlag                { postControl("reload") }

        if let v = viewArg           { postView(v, active: activeFlag, loadingMs: loadingArg, geom: geom, edge: edgeArg) }
        if let h = hideArg           { postHide(h) }
        if let t = toggleArg         { postToggle(t) }

        // Server mode. Reached only when no client flag matched.

        // Refresh the taplo schema sidecar next to the user config so
        // editor completion/validation just works (idempotent; writes
        // only on change, and the watcher tracks config.toml not this
        // sibling, so no reload churn). Best-effort — never blocks start.
        FacetConfig.installSchema()

        let cfg = FacetConfig.load()
        // Fail Fast (M11-3): refuse to start on an incoherent config
        // — `[grouping] by = "tag"` with no `[[tag]]`, or with a
        // workspace-only default layout (`bsp`/`stack`), or a `by` typo.
        // Loud `exit 2` (usage error) rather than silently running the
        // default grouping. No-op in the (default) workspace mode.
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

        // Apply config's default-view. nil → agent-only mode (no
        // panel, no overlay); facet stays running and waits for a
        // ``facet --view tree`` / ``facet --view grid`` to bring
        // something on screen. See memory config-default-behavior.
        switch cfg.effectiveDefaultView {
        case "grid":
            controller.showGrid()
        case "tree":
            controller.setHidden(false)
        default:
            controller.setHidden(true)
        }

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
    /// equivalents fire) once `--active` flips the app to `.regular` +
    /// activates it (Controller.enterActive) — which is exactly when the
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
