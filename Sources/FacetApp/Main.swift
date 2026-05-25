// facet entry point. Two modes:
//
//   1. **Client mode** — at least one recognised CLI flag was
//      passed. Post the matching control notification to the
//      running server instance, then ``exit(0)``. The server-side
//      observer (``Controller.installCLIControl``) routes it.
//
//   2. **Server mode** — no CLI flags. Wake the AppKit run loop,
//      load config, build the rift adapter + Controller, and
//      apply ``default_view`` from config (omitted → agent-only,
//      no panel until the CLI asks).
//
// ``@main enum FacetApp`` (NOT top-level code in main.swift) so
// XCTest can ``@testable import FacetApp`` once tests land without
// the act of importing the executable spawning a panel. Same trap
// CLAUDE.md flags for ws-tabs — don't reintroduce main.swift.
//
// CLI surface (case D, canonical-only — no aliases):
//
//   facet --view=NAME [--active]    open NAME, optionally active
//   facet --hide=NAME               close NAME
//   facet --toggle=NAME             toggle NAME
//   facet --theme=NAME              live re-theme
//   facet --quit                    terminate server
//   facet --debug                   verbose logging (server-mode)
//   facet --help                    this help
//
// ``--active`` is a modifier; ``facet --active`` standalone is
// NOT supported (would be ambiguous about which view to activate).
// Same for ``--show`` / ``--hide`` / ``--toggle`` bare — every
// view op must specify NAME explicitly. Shell aliases handle
// shorthand if the user wants it.

import AppKit
import FacetCore
import FacetAdapterRift
import FacetView
import FacetViewTree
import FacetViewGrid

@main
enum FacetApp {

    // MARK: - Canonical names

    /// Views the user can address with ``--view=`` / ``--hide=`` /
    /// ``--toggle=``. Adding a new view (dock, palette, …) only
    /// requires extending this list + the server-side
    /// ``Controller.dispatchView/Hide/Toggle`` switches.
    static let canonicalViews = ["tree", "grid"]

    // MARK: - Help

    static func printHelp() -> Never {
        let help = """
        facet — Swift workspace + window manager for macOS.

        USAGE
          facet [COMMAND]                    client mode (post to server)
          facet                              server mode (start the app)

        VIEW OPERATIONS                      NAME ∈ tree | grid
          facet --view=NAME [--active]       open NAME (idempotent)
          facet --hide=NAME                  close NAME
          facet --toggle=NAME                toggle NAME

          --active is a modifier — meaningful only with --view=tree.
          Tree alone enables keyboard nav as soon as you click the
          panel; --active just takes focus immediately so a hotkey
          can jump straight in (Spotlight-style). --view=grid
          silently ignores; the overlay is always key/active.

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

        WORKSPACE
          facet --workspace=N                switch to workspace N
                                             (1-indexed; idempotent —
                                             no-op if already there)

          facet doesn't bind keyboard shortcuts. Wire one up with
          your shortcut tool of choice (skhd, Karabiner-Elements,
          hammerspoon, …):
            # ~/.config/skhd/skhdrc
            ctrl + alt - 1 : facet --workspace=1
            ctrl + alt - 2 : facet --workspace=2

        SERVER CONTROLS
          facet --theme=NAME                 terminal | cute | system
                                             (session only; edit
                                             config.toml to persist)
          facet --quit                       terminate the server
          facet --debug                      verbose log to stderr +
                                             /tmp/facet.log (server
                                             startup only)
          facet --resign                     re-sign Facet.app with the
                                             persistent "facet Local
                                             Signing" identity + restart
                                             (run once after `brew install`
                                             / upgrade — Homebrew sandbox
                                             can't set up the cert itself)

          facet --help                       this help

        EXIT CODES
          0   success (DNC posted or server started)
          2   unknown flag / view / theme name (stderr lists expected
              values)
          3   no server running for the requested client-mode action
              (start one with ./run.sh)

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

    /// Post ``view:NAME[+active][+geom:X,Y,W,H]``. Name must
    /// already be canonical. Geom is optional and only meaningful
    /// for tree (grid silently ignores it, same pattern as +active).
    static func postView(_ name: String,
                         active: Bool,
                         geom: (Int, Int, Int, Int)?) -> Never {
        var payload = "view:\(name)"
        if active { payload += "+active" }
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

    /// Post ``workspace:N`` (1-indexed). Switches to the Nth
    /// workspace via the backend. Idempotent — if you're already
    /// on N the backend treats it as a no-op.
    static func postWorkspace(_ index: Int) -> Never {
        postControl("workspace:\(index)")
    }

    /// Parse ``--workspace=N`` (positive integer, 1-indexed). Loud
    /// reject on non-integer / non-positive so a typo can't pick
    /// the wrong workspace silently.
    static func parseWorkspaceInt(_ arg: String) -> Int {
        let raw = String(arg.dropFirst("--workspace=".count))
        switch FacetCore.parseGeomInt(raw, requirePositive: true) {
        case .success(let n):
            return n
        case .failure(.notAnInteger(let v)):
            die("--workspace expects an integer (got \"\(v)\")")
        case .failure(.notPositive(let n)):
            die("--workspace must be > 0 (1-indexed, got \(n))")
        case .failure:
            die("--workspace parse error")
        }
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
        for label in ["homebrew.mxcl.facet", "com.facet.app"] {
            let kick = runProcess(
                "/bin/launchctl",
                args: ["kickstart", "-k", "gui/\(getuid())/\(label)"],
                captureOutput: true)
            if kick == 0 {
                print("facet: restarted via `launchctl kickstart \(label)`")
                exit(0)
            }
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
            for v in versions.sorted(by: >) {
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
        // ``Log.debug``. Bare flag, no value.
        if argv.contains("--debug") { debugMode = true }

        // Two-pass: collect all flags first so the dispatch below
        // is order-independent (``--view=tree --active`` and
        // ``--active --view=tree`` both work).
        var viewArg: String?
        var hideArg: String?
        var toggleArg: String?
        var styleArg: String?
        var workspaceArg: Int?
        var activeFlag = false
        var quitFlag = false
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

        var i = 0
        while i < argv.count {
            defer { i += 1 }
            let a = argv[i]
            switch true {
            case a == "--quit":              quitFlag = true
            case a == "--active":            activeFlag = true
            case a == "--debug":             break          // handled above
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
            case a.hasPrefix("--workspace="):
                workspaceArg = parseWorkspaceInt(a)
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
        let anyClientAction = styleArg != nil || quitFlag
            || viewArg != nil || hideArg != nil || toggleArg != nil
            || workspaceArg != nil
        if anyClientAction { requireServerAlive() }

        // Dispatch. Each ``post*`` returns ``Never`` (calls
        // ``exit``), so the FIRST matched branch wins — the rest
        // is unreachable. Precedence below mirrors usual
        // expectation: ``--theme`` / ``--quit`` are tried first,
        // then view ops. To combine (e.g. theme + view in one
        // call), the user issues two separate invocations.
        if let s = styleArg          { postStyle(s) }
        if quitFlag                  { postControl("quit") }

        if let v = viewArg           { postView(v, active: activeFlag, geom: geom) }
        if let h = hideArg           { postHide(h) }
        if let t = toggleArg         { postToggle(t) }
        if let w = workspaceArg      { postWorkspace(w) }

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

        let backend = RiftAdapter()
        let controller = Controller(backend: backend, config: cfg)
        controller.start()

        // Apply config's default_view. nil → agent-only mode (no
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
