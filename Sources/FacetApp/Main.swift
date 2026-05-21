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

          --active is a modifier — meaningful only with --view=tree
          (enters keyboard-nav mode). With --view=grid it's silently
          ignored; the overlay is always key/active by construction.

          NAME is required for every view op (no implicit "tree").
          Shell aliases handle shorthand if you want it:
            alias fa='facet --view=tree --active'
            alias fg='facet --view=grid'

        SERVER CONTROLS
          facet --theme=NAME                 terminal | cute | system
                                             (session only; edit
                                             config.toml to persist)
          facet --quit                       terminate the server
          facet --debug                      verbose log to stderr +
                                             /tmp/facet.log (server
                                             startup only)

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

    /// Post ``view:NAME`` (or ``view:NAME+active``). Name must
    /// already be canonical.
    static func postView(_ name: String, active: Bool) -> Never {
        postControl(active ? "view:\(name)+active" : "view:\(name)")
    }

    static func postHide(_ name: String) -> Never {
        postControl("hide:\(name)")
    }

    static func postToggle(_ name: String) -> Never {
        postControl("toggle:\(name)")
    }

    /// Validate + canonicalise a view name. Loud reject on typo
    /// (``exit(2)``) so a fundamental error wins over later
    /// transient checks (e.g. server-not-running).
    static func canonicalView(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard canonicalViews.contains(n) else {
            let msg = "facet: unknown view \"\(n)\" — expected one of: "
                + canonicalViews.joined(separator: ", ") + "\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        return n
    }

    /// Validate + canonicalise a theme name.
    static func canonicalStyle(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard canonicalStyles.contains(n) else {
            let msg = "facet: unknown theme \"\(n)\" — expected one of: "
                + canonicalStyles.joined(separator: ", ") + "\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        return n
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
        var activeFlag = false
        var quitFlag = false

        var i = 0
        while i < argv.count {
            defer { i += 1 }
            let a = argv[i]
            switch true {
            case a == "--quit":              quitFlag = true
            case a == "--active":            activeFlag = true
            case a == "--debug":             break          // handled above
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

        // Any client-mode action is about to fire — make sure a
        // server is actually listening, otherwise the DNC post
        // would silently broadcast to nobody and exit 0,
        // leaving a dead-hotkey mystery. Server mode (no client
        // flag at all) is unaffected; this process is the one
        // about to become the server.
        let anyClientAction = styleArg != nil || quitFlag
            || viewArg != nil || hideArg != nil || toggleArg != nil
        if anyClientAction { requireServerAlive() }

        // Dispatch (each branch ``postControl``s, which exits).
        // ``--theme`` and ``--quit`` are independent — applied
        // first so they compose with the view dispatch below if
        // both happen to be passed together.
        if let s = styleArg          { postStyle(s) }
        if quitFlag                  { postControl("quit") }

        if let v = viewArg           { postView(v, active: activeFlag) }
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
