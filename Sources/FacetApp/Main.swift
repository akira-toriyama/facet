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
// CLI surface (canonical-only — no aliases). See `printHelp()`
// for the user-facing reference; the categories below are the
// quick orientation:
//
//   Views   : --view=NAME [--active] / --hide=NAME / --toggle=NAME
//   Theme   : --theme=NAME
//   Server  : --quit / --reload / --resign / --help
//   Status  : facet status (read-only, no `--`)
//   Workspace : facet workspace --focus=N|NAME|next|prev|recent / --layout=NAME
//               / --retile / --balance / --rotate=90|180|270
//               / --mirror=horizontal|vertical / --add / --remove[=N]
//               / --rename=NAME / --move=N
//   Window    : facet window --move-to=N[ --follow] / --mark=NAME
//               / --focus-mark=NAME / --unmark=NAME / --toggle-float /
//               --toggle-sticky / --toggle-orientation /
//               --cycle-stack=next|prev / --grow-master / --shrink-master
//               / --inc-master / --dec-master
//   Scratchpad: facet scratchpad --stash=NAME / --toggle=NAME
//               / --release=NAME
//
// ``--active`` is a modifier; ``facet --active`` standalone is
// NOT supported (would be ambiguous about which view to activate).
// Same for ``--show`` / ``--hide`` / ``--toggle`` bare — every
// view op must specify NAME explicitly. Shell aliases handle
// shorthand if the user wants it.

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

    /// Views the user can address with ``--view=`` / ``--hide=`` /
    /// ``--toggle=``. Adding a new view (dock, palette, …) only
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
          facet --view=NAME [--active]       open NAME (idempotent)
          facet --hide=NAME                  close NAME
          facet --toggle=NAME                toggle NAME

          --active is a modifier — meaningful only with --view=tree.
          Tree alone enables keyboard nav as soon as you click the
          panel; --active just takes focus immediately so a hotkey
          can jump straight in (Spotlight-style). --view=grid
          silently ignores; the overlay is always key/active.

          --edge=top|bottom|left|right is a --view=rail modifier:
          dock the rail's workspace strip against that screen edge
          (default bottom, or [rail] edge in config). Top/bottom
          browse with ←/→, left/right with ↑/↓. Example:
            facet --view=rail --edge=left

          --loading[=MS] is a --view=tree modifier: paint a loading
          skeleton over the tree, cleared as soon as new content
          loads OR after MS milliseconds (default 500), whichever
          comes first — so MS is just a safety cap. Fire it just
          BEFORE a mac-desktop switch (bind it ahead of your switch
          hotkey) so the panel shows a placeholder during the switch
          instead of the previous mac desktop's tree. Only valid with
          --view=tree; grid / rail exit 2.
          Example:
            facet --view=tree --loading=2000

          GEOMETRY MODIFIERS (--view=tree only; grid ignores)
            --pos-x=N --pos-y=N --width=N --height=N
              Place the tree panel at exact screen coords (AppKit
              bottom-left origin) with explicit size. All four are
              required together (none / all). Use case: screenshot
              automation, deterministic UI tests.
              Example:
                facet --view=tree --pos-x=100 --pos-y=200 \\
                       --width=400 --height=600

          NAME is required for every view op (no implicit "tree").
          Shell aliases handle shorthand if you want it:
            alias fa='facet --view=tree --active'
            alias fg='facet --view=grid'

        WORKSPACE                            (active / target workspace)
          facet workspace --focus=N          switch to workspace N
                                             (1-indexed; idempotent)
          facet workspace --focus=NAME       switch by name (stable
                                             across reorder)
          facet workspace --focus=next       step to next / previous
          facet workspace --focus=prev       workspace (wraps)
          facet workspace --focus=recent     return to the previous one
          facet workspace --layout=NAME      set the workspace's layout
                                             (bsp | stack | master-left |
                                             master-right | master-top |
                                             master-bottom | master-center |
                                             grid | spiral | float)
          facet workspace --retile           re-apply the layout
                                             (no-op when float)
          facet workspace --balance          reset master ratio / count
                                             to the even baseline
          facet workspace --rotate=90|180|270  rotate the bsp tree
                                             clockwise (bsp only)
          facet workspace --mirror=horizontal|vertical  flip the bsp
                                             tree left↔right / top↔bottom
          facet workspace --add              append a new workspace
          facet workspace --remove[=N]       remove workspace N (or the
                                             active one); its windows
                                             move to a neighbour
          facet workspace --rename=NAME      rename the active workspace
          facet workspace --move=N           move the active workspace to
                                             position N (reorder)

        WINDOW                               (focused window)
          facet window --move-to=N           move it to workspace N
          facet window --move-to=N --follow  …and switch there too
          facet window --mark=NAME           tag it with a mark (label;
                                             1:1 — one mark per window)
          facet window --focus-mark=NAME     jump focus to the marked
                                             window (switches WS if needed)
          facet window --unmark=NAME         remove a mark
          facet window --toggle-float        flip its float flag
          facet window --toggle-sticky       pin it across every workspace
                                             (PiP / timer / chat); flip off
                                             to drop it as a tiled window
          facet window --toggle-orientation  bsp: rotate the focused
                                             window's parent split
          facet window --cycle-stack=next    rotate stack to next member
          facet window --cycle-stack=prev    rotate stack to previous
                                             member (stack only)
          facet window --grow-master         widen the master area +0.05
          facet window --shrink-master       narrow the master area -0.05
          facet window --inc-master          one more window in master
          facet window --dec-master          one fewer window in master
                                             (master-* engines only)

        SCRATCHPAD                           (named hidden shelves)
          facet scratchpad --stash=NAME      park the focused window onto
                                             a named shelf (hides it)
          facet scratchpad --toggle=NAME     summon it onto the current
                                             workspace, or re-park it if
                                             already visible here
          facet scratchpad --release=NAME    drop it off the shelf as a
                                             tiled window of this workspace

          facet doesn't bind keyboard shortcuts. Wire one up with
          your shortcut tool of choice (skhd, Karabiner-Elements,
          hammerspoon, …):
            # ~/.config/skhd/skhdrc
            ctrl + alt - 1 : facet workspace --focus=1
            ctrl + alt - 2 : facet workspace --focus=2
            ctrl + shift + alt - 1 : facet window --move-to=1

        STATUS
          facet status                       print server's view of the
                                             world: backend, theme,
                                             workspaces (active marker +
                                             window counts), last error,
                                             snapshot timestamp. Reads
                                             /tmp/facet-status.json
                                             (server writes atomically).
                                             Greppable line format.

        SERVER CONTROLS
          facet --theme=NAME                 terminal | cute | system
                                             (session only; edit
                                             config.toml to persist)
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
          0   success (DNC posted, server started, or status printed)
          1   `--resign` codesign failed (see stderr)
          2   unknown flag / view / theme name (stderr lists expected
              values)
          3   no server running for the requested client-mode action
              (start one with ./run.sh); also: `facet status` when
              the status file is missing
          4   status file present but malformed (server bug —
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
        var toggleFloat = false
        var toggleSticky = false
        var toggleOrientation = false
        var cycleStackDir: String?
        var growMaster = false
        var shrinkMaster = false
        var incMaster = false
        var decMaster = false
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
            + (toggleFloat ? 1 : 0)
            + (toggleSticky ? 1 : 0)
            + (toggleOrientation ? 1 : 0)
            + (cycleStackDir != nil ? 1 : 0)
            + (growMaster ? 1 : 0)
            + (shrinkMaster ? 1 : 0)
            + (incMaster ? 1 : 0)
            + (decMaster ? 1 : 0)
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
        requireServerAlive()
        if let n = moveToArg { follow ? postWindowMoveFollow(n)
                                      : postWindowMove(n) }
        if let m = markArg { postControl("window-mark:" + m) }
        if let m = focusMarkArg { postControl("window-focus-mark:" + m) }
        if let m = unmarkArg { postControl("window-unmark:" + m) }
        if toggleFloat { postWindowToggleFloat() }
        if toggleSticky { postWindowToggleSticky() }
        if toggleOrientation { postWindowToggleOrientation() }
        if let d = cycleStackDir { postWindowCycleStack(d) }
        if growMaster { postWindowGrowMaster() }
        if shrinkMaster { postWindowShrinkMaster() }
        if incMaster { postWindowIncMaster() }
        if decMaster { postWindowDecMaster() }
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
        switch canonicalize(name, allowed: canonicalStyles) {
        case .success(let n): return n
        case .failure(.unknownValue(let v, let expected)):
            die("unknown theme \"\(v)\" — expected one of: "
                + expected.joined(separator: ", "))
        case .failure:
            die("unknown theme \"\(name)\"")
        }
    }

    /// stderr message + exit(2). Always prefixes with ``facet:``.
    static func die(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("facet: \(msg)\n".utf8))
        exit(2)
    }

    // MARK: - --resign

    /// `facet --resign` re-signs the installed Facet.app with the
    /// persistent ``facet Local Signing`` self-signed identity and
    /// restarts the daemon. Necessary after every `brew install` /
    /// `brew upgrade facet` — Homebrew's build sandbox blocks the
    /// in-formula ``setup-signing-cert.sh`` from touching the user's
    /// login keychain, so installs fall back to ad-hoc signing and
    /// TCC re-prompts for Accessibility on every upgrade.
    ///
    /// Same pattern as chord 0.3.3 / stroke 2.3.0; mirror updates
    /// across the three repos when this changes.
    ///
    /// Exit codes:
    ///   0 — re-signed (restart attempted, best-effort)
    ///   1 — codesign failed
    ///   2 — no Facet.app found in any expected location
    ///   3 — signing identity missing (run setup-signing-cert.sh first)
    static func runResign() -> Never {
        guard let appPath = findFacetApp() else {
            let msg = "facet: no Facet.app found at "
                + "/opt/homebrew/Cellar/facet/*/, /Applications, or "
                + "~/Applications.\n"
                + "       install via "
                + "`brew install akira-toriyama/tap/facet` first.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        print("facet: detected Facet.app at \(appPath)")

        let identity = "facet Local Signing"
        guard hasSigningIdentity(identity) else {
            let setupHint = setupCertHint()
            let msg = "facet: no '\(identity)' identity in your "
                + "login keychain.\n"
                + "       run once:\n"
                + "         \(setupHint)\n"
                + "         facet --resign\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(3)
        }

        print("facet: signing with identity '\(identity)'")
        let codesignExit = runProcess(
            "/usr/bin/codesign",
            args: ["--force", "--sign", identity, appPath])
        guard codesignExit == 0 else {
            FileHandle.standardError.write(Data(
                "facet: codesign failed (exit \(codesignExit))\n".utf8))
            exit(1)
        }

        print("facet: restarting daemon")
        let brewExit = runProcess(
            "/opt/homebrew/bin/brew",
            args: ["services", "restart", "facet"],
            captureOutput: true)
        if brewExit == 0 {
            print("facet: restarted via `brew services restart facet`")
            exit(0)
        }
        // Only `homebrew.mxcl.facet` — facet doesn't ship an
        // in-repo LaunchAgent template, so `com.facet.app` (the
        // bundle id) wouldn't match any registered Label key.
        // Adding it as a kickstart fallback was dead code.
        let label = "homebrew.mxcl.facet"
        let kick = runProcess(
            "/bin/launchctl",
            args: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
            captureOutput: true)
        if kick == 0 {
            print("facet: restarted via `launchctl kickstart \(label)`")
            exit(0)
        }
        FileHandle.standardError.write(Data((
            "facet: re-signed, but couldn't restart the daemon — "
            + "start it manually.\n"
        ).utf8))
        exit(0)
    }

    /// Pick the first existing Facet.app from the canonical install
    /// locations. The brew Cellar is preferred over manual copies.
    static func findFacetApp() -> String? {
        let cellar = "/opt/homebrew/Cellar/facet"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: cellar) {
            // `.numeric` makes "1.10.0" > "1.2.0" — a plain string
            // sort would silently pick the older 1.2.0 as "latest"
            // once a 1.10 series ships.
            let sorted = versions.sorted { a, b in
                a.compare(b, options: .numeric) == .orderedDescending
            }
            for v in sorted {
                let p = "\(cellar)/\(v)/Facet.app"
                if FileManager.default.fileExists(atPath: p) { return p }
            }
        }
        for candidate in [
            "/Applications/Facet.app",
            "\(NSHomeDirectory())/Applications/Facet.app",
        ] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Untrusted self-signed certs don't appear in `find-identity`
    /// (that filter lists trusted identities only). Use
    /// `find-certificate` which surfaces untrusted entries too.
    static func hasSigningIdentity(_ name: String) -> Bool {
        runProcess(
            "/usr/bin/security",
            args: ["find-certificate", "-c", name,
                   "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"],
            captureOutput: true
        ) == 0
    }

    /// Best-effort guess at where `setup-signing-cert.sh` lives on
    /// the user's machine. brew installs ship it under
    /// `share/facet/`, dev installs have it at the repo root.
    static func setupCertHint() -> String {
        let brewShared = "/opt/homebrew/share/facet/setup-signing-cert.sh"
        if FileManager.default.fileExists(atPath: brewShared) {
            return brewShared
        }
        return "./setup-signing-cert.sh"
    }

    /// Spawn + wait. Returns the child's exit code on completion,
    /// or `-1` when `Process.run()` itself failed (executable not
    /// found, permission denied, etc.) — the catch path also emits
    /// a stderr line so the caller's generic "exit -1" message
    /// isn't the only signal.
    @discardableResult
    static func runProcess(_ executable: String,
                           args: [String],
                           captureOutput: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if captureOutput {
            p.standardOutput = FileHandle.nullDevice
            p.standardError  = FileHandle.nullDevice
        }
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            FileHandle.standardError.write(Data(
                "facet: couldn't launch \(executable): \(error)\n".utf8))
            return -1
        }
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
        // is order-independent (``--view=tree --active`` and
        // ``--active --view=tree`` both work).
        var viewArg: String?
        var hideArg: String?
        var toggleArg: String?
        var styleArg: String?
        var activeFlag = false
        var edgeArg: String?            // rail dock edge (--edge=); nil = config default
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
        // Read-only query sub-command. Plain noun (no `--`)
        // because it returns data rather than triggering a verb.
        if argv == ["status"] {
            runStatus()
        }

        var i = 0
        while i < argv.count {
            defer { i += 1 }
            let a = argv[i]
            switch true {
            case a == "--quit":              quitFlag = true
            case a == "--reload":            reloadFlag = true
            case a == "--active":            activeFlag = true
            case a == "--loading":           loadingArg = defaultLoadingMs
            case a.hasPrefix("--loading="):
                let raw = String(a.dropFirst("--loading=".count))
                guard let ms = Int(raw), ms >= 0 else {
                    die("--loading=MS needs a non-negative integer "
                        + "(milliseconds) — got \"\(raw)\"")
                }
                loadingArg = ms
            case a == "--resign":            break          // handled above
            // Names are canonicalised + validated at parse time
            // (not at post time) so typos exit 2 BEFORE the server-
            // alive check runs — a fundamental error should win
            // over a transient one.
            case a.hasPrefix("--view="):
                viewArg = canonicalView(String(a.dropFirst("--view=".count)))
            case a.hasPrefix("--hide="):
                hideArg = canonicalView(String(a.dropFirst("--hide=".count)))
            case a.hasPrefix("--toggle="):
                toggleArg = canonicalView(String(a.dropFirst("--toggle=".count)))
            case a.hasPrefix("--edge="):
                edgeArg = canonicalEdge(String(a.dropFirst("--edge=".count)))
            case a.hasPrefix("--theme="):
                styleArg = canonicalStyle(String(a.dropFirst("--theme=".count)))
            case a.hasPrefix("--pos-x="):
                posX = parseGeomInt(a, "--pos-x=")
            case a.hasPrefix("--pos-y="):
                posY = parseGeomInt(a, "--pos-y=")
            case a.hasPrefix("--width="):
                width = parseGeomInt(a, "--width=", requirePositive: true)
            case a.hasPrefix("--height="):
                height = parseGeomInt(a, "--height=", requirePositive: true)
            default:
                // Loud reject — typos / dropped legacy flags
                // (``--show`` / ``--hide`` / ``--toggle`` /
                // ``--style=...``) hit here. Server mode falling
                // through silently would launch a second instance
                // by accident.
                let msg = "facet: unknown flag \"\(a)\" — see "
                    + "`facet --help`\n"
                FileHandle.standardError.write(Data(msg.utf8))
                exit(2)
            }
        }

        // ``--active`` is a modifier only — standalone is rejected
        // (would be ambiguous about which view to activate).
        if activeFlag && viewArg == nil {
            let msg = "facet: --active requires --view=NAME — "
                + "see `facet --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }

        // ``--edge`` only means something for the rail (it picks the
        // strip's screen edge); requiring ``--view=rail`` keeps a stray
        // ``--edge`` from silently doing nothing on tree / grid. A
        // ``--toggle=rail`` gets a clearer hint — the rail was targeted,
        // but ``--edge`` rides the show (``--view=rail``), not toggle.
        if edgeArg != nil && viewArg != "rail" {
            let hint = toggleArg == "rail"
                ? "--edge applies to --view=rail (show), not --toggle=rail"
                : "--edge requires --view=rail"
            let msg = "facet: \(hint) — see `facet --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }

        // ``--loading`` is a modifier on ``--view=tree`` only — the
        // skeleton lives in ``SidebarView``; grid / rail can't paint
        // it, so a stray ``--loading`` on another view exits 2 rather
        // than silently doing nothing.
        if loadingArg != nil && viewArg != "tree" {
            let msg = "facet: --loading requires --view=tree — "
                + "see `facet --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }

        // Geom flags are all-or-nothing modifiers; only meaningful
        // with --view=tree (grid silently ignores, same as --active).
        // Partial sets (e.g. only --width) are rejected loudly so
        // the user doesn't end up with a half-applied frame.
        var geom: (Int, Int, Int, Int)? = nil
        switch validateGeom(posX: posX, posY: posY,
                            width: width, height: height) {
        case .none:
            break
        case .complete(let x, let y, let w, let h):
            if viewArg == nil {
                die("geometry flags require --view=NAME — "
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

        let cfg = FacetConfig.load()
        // config.toml is the single source of truth for theme.
        // Runtime `--theme=...` overrides this for the current
        // session only (no UserDefaults persist); to make a theme
        // stick, edit config.toml.
        pal = paletteFor(cfg.effectiveTheme)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
        // ``facet --view=tree`` / ``facet --view=grid`` to bring
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
}
