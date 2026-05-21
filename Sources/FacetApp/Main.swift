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
// CLI surface (case D in the conversation that settled on it):
//
//   facet --view=NAME [--active]    open NAME, optionally active
//   facet --hide=NAME               close NAME
//   facet --toggle=NAME             toggle NAME
//   facet --theme=NAME              live re-theme
//   facet --quit                    terminate server
//   facet --debug                   verbose logging (server-mode)
//
// Aliases (compat / shorthand for the common "tree" view):
//   --show     ↔ --view=tree
//   --hide     ↔ --hide=tree
//   --toggle   ↔ --toggle=tree
//   --active   ↔ --view=tree --active

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
        var bareShow = false
        var bareHide = false
        var bareToggle = false
        var bareQuit = false

        var i = 0
        while i < argv.count {
            defer { i += 1 }
            let a = argv[i]
            switch true {
            case a == "--show":              bareShow = true
            case a == "--hide":              bareHide = true
            case a == "--toggle":            bareToggle = true
            case a == "--quit":              bareQuit = true
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
            case a.hasPrefix("--style="):                    // legacy alias
                styleArg = String(a.dropFirst("--style=".count))
            case a == "--theme", a == "--style":
                if i + 1 < argv.count { styleArg = argv[i + 1]; i += 1 }
            default:                         break
            }
        }

        // Dispatch (each branch ``postControl``s, which exits).
        // Precedence: explicit ``--view/--hide/--toggle`` > bare
        // aliases > standalone ``--active``. ``--theme`` and
        // ``--quit`` are independent and applied first.
        if let s = styleArg          { postStyle(s) }
        if bareQuit                  { postControl("quit") }

        if let v = viewArg           { postView(v, active: activeFlag) }
        if let h = hideArg           { postHide(h) }
        if let t = toggleArg         { postToggle(t) }

        if bareShow                  { postView("tree", active: activeFlag) }
        if bareHide                  { postHide("tree") }
        if bareToggle                { postToggle("tree") }
        if activeFlag                { postView("tree", active: true) }

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
