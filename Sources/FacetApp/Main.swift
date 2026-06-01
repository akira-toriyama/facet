// facet entry point. Two modes:
//
//   1. **Client mode** — at least one recognised CLI flag was
//      passed. Post the matching control notification to the
//      running server instance, then ``exit(0)``. The server-side
//      observer (``Controller.installCLIControl``) routes it.
//
//   2. **Server mode** — no CLI flags. Wake the AppKit run loop,
//      load config, build the rift adapter + Controller, and
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
//               / --retile / --add / --remove[=N] / --rename=NAME / --move=N
//   Window    : facet window --move-to=N / --toggle-float /
//               --toggle-orientation / --cycle-stack=next|prev /
//               --grow-master / --shrink-master / --inc-master / --dec-master
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

    // MARK: - Help

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

          --loading[=MS] is a --view=tree modifier: paint a loading
          skeleton over the tree, cleared as soon as new content
          loads OR after MS milliseconds (default 500), whichever
          comes first — so MS is just a safety cap. Fire it just
          BEFORE a native-Space switch (bind it ahead of your switch
          hotkey) so the panel shows a placeholder during the switch
          instead of the previous desktop's tree. grid ignores it.
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
                                             (bsp | stack | tall |
                                             wide | centered | grid |
                                             spiral | float)
          facet workspace --retile           re-apply the layout
                                             (no-op when float)
          facet workspace --add              append a new workspace
          facet workspace --remove[=N]       remove workspace N (or the
                                             active one); its windows
                                             move to a neighbour
          facet workspace --rename=NAME      rename the active workspace
          facet workspace --move=N           move the active workspace to
                                             position N (reorder)

        WINDOW                               (focused window)
          facet window --move-to=N           move it to workspace N
          facet window --toggle-float        flip its float flag
          facet window --toggle-orientation  bsp: rotate parent split /
                                             tall⇄wide: swap layout
          facet window --cycle-stack=next    rotate stack to next member
          facet window --cycle-stack=prev    rotate stack to previous
                                             member (stack only)
          facet window --grow-master         widen the master area +0.05
          facet window --shrink-master       narrow the master area -0.05
          facet window --inc-master          one more window in master
          facet window --dec-master          one fewer window in master
                                             (tall / wide / centered only)

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

          facet --help                       this help

        EXIT CODES
          0   success (DNC posted, server started, or status printed)
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

    /// Post ``view:NAME[+active][+loading:MS][+geom:X,Y,W,H]``. Name
    /// must already be canonical. Geom + loading are optional and
    /// only meaningful for tree (grid silently ignores them, same
    /// pattern as +active).
    static func postView(_ name: String,
                         active: Bool,
                         loadingMs: Int?,
                         geom: (Int, Int, Int, Int)?) -> Never {
        var payload = "view:\(name)"
        if active { payload += "+active" }
        if let ms = loadingMs { payload += "+loading:\(ms)" }
        if let g = geom {
            payload += "+geom:\(g.0),\(g.1),\(g.2),\(g.3)"
        }
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

    /// Post ``set-layout:NAME``. NAME must be one of
    /// ``canonicalLayoutModes`` (validated by ``canonicalLayoutMode``
    /// at parse time). Targets the currently-active workspace.
    static func postSetLayout(_ name: String) -> Never {
        postControl("set-layout:" + name)
    }

    /// Post ``retile``. Re-apply the active WS's layout — only
    /// meaningful for backends with their own layout engine
    /// (NativeAdapter); rift no-ops.
    static func postRetile() -> Never {
        postControl("retile")
    }

    /// Post ``window-toggle-float`` / ``window-toggle-orientation``.
    /// Target is the focused window.
    static func postWindowToggleFloat() -> Never {
        postControl("window-toggle-float")
    }

    static func postWindowToggleOrientation() -> Never {
        postControl("window-toggle-orientation")
    }

    /// Post ``window-cycle-stack:next`` / ``:prev``. Direction
    /// already canonical by parse time (`parseCycleStack`).
    static func postWindowCycleStack(_ direction: String) -> Never {
        postControl("window-cycle-stack:" + direction)
    }

    /// Post master-knob nudges (tall / wide / centered). The active
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
        var toggleFloat = false
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
            case a == "--toggle-float":
                toggleFloat = true
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
            + (toggleFloat ? 1 : 0)
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
        requireServerAlive()
        if let n = moveToArg { postWindowMove(n) }
        if toggleFloat { postWindowToggleFloat() }
        if toggleOrientation { postWindowToggleOrientation() }
        if let d = cycleStackDir { postWindowCycleStack(d) }
        if growMaster { postWindowGrowMaster() }
        if shrinkMaster { postWindowShrinkMaster() }
        if incMaster { postWindowIncMaster() }
        if decMaster { postWindowDecMaster() }
        // Unreachable — `count == 1` guarantees one branch fired.
        die("facet window: dispatch fell through (bug)")
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

        // Help short-circuits everything else.
        if argv.contains("--help") { printHelp() }

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
            case a == "--view":
                if i + 1 < argv.count {
                    viewArg = canonicalView(argv[i + 1]); i += 1
                }
            case a.hasPrefix("--hide="):
                hideArg = canonicalView(String(a.dropFirst("--hide=".count)))
            case a.hasPrefix("--toggle="):
                toggleArg = canonicalView(String(a.dropFirst("--toggle=".count)))
            case a.hasPrefix("--theme="):
                styleArg = canonicalStyle(String(a.dropFirst("--theme=".count)))
            case a == "--theme":
                if i + 1 < argv.count {
                    styleArg = canonicalStyle(argv[i + 1]); i += 1
                }
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

        // ``--loading`` is a modifier on ``--view=tree`` (grid
        // ignores it, same as ``--active``).
        if loadingArg != nil && viewArg == nil {
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

        if let v = viewArg           { postView(v, active: activeFlag, loadingMs: loadingArg, geom: geom) }
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
