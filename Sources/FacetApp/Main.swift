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
          2   unknown view / theme name (stderr lists expected values)

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

    /// Validate + post a ``style:NAME`` notification.
    static func postStyle(_ name: String) -> Never {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard canonicalStyles.contains(n.lowercased()) else {
            let msg = "facet: unknown theme \"\(n)\" — expected one of: "
                + canonicalStyles.joined(separator: ", ") + "\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        postControl("style:" + n)
    }

    /// Validate + post ``view:NAME`` (or ``view:NAME+active``).
    static func postView(_ name: String, active: Bool) -> Never {
        let n = canonicalView(name)
        postControl(active ? "view:\(n)+active" : "view:\(n)")
    }

    static func postHide(_ name: String) -> Never {
        let n = canonicalView(name)
        postControl("hide:\(n)")
    }

    static func postToggle(_ name: String) -> Never {
        let n = canonicalView(name)
        postControl("toggle:\(n)")
    }

    /// Loudly reject typos rather than silently fall through (same
    /// principle as ``postStyle``). Returns the canonical name on
    /// success; ``exit(2)`` with stderr message on failure.
    private static func canonicalView(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard canonicalViews.contains(n) else {
            let msg = "facet: unknown view \"\(n)\" — expected one of: "
                + canonicalViews.joined(separator: ", ") + "\n"
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
            case a.hasPrefix("--view="):
                viewArg = String(a.dropFirst("--view=".count))
            case a == "--view":
                if i + 1 < argv.count { viewArg = argv[i + 1]; i += 1 }
            case a.hasPrefix("--hide="):
                hideArg = String(a.dropFirst("--hide=".count))
            case a.hasPrefix("--toggle="):
                toggleArg = String(a.dropFirst("--toggle=".count))
            case a.hasPrefix("--theme="):
                styleArg = String(a.dropFirst("--theme=".count))
            case a == "--theme":
                if i + 1 < argv.count { styleArg = argv[i + 1]; i += 1 }
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
