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

import AppKit
import FacetCore
import FacetAdapterRift
import FacetView
import FacetViewTree
import FacetViewGrid

@main
enum FacetApp {

    // MARK: - Client mode helpers

    /// Forward a command string to the running instance, then exit.
    /// Never returns.
    static func postControl(_ object: String) -> Never {
        DistributedNotificationCenter.default().postNotificationName(
            .init(ctrlNotificationName),
            object: object,
            userInfo: nil,
            deliverImmediately: true)
        exit(0)
    }

    /// Reject typos loudly instead of silently falling back to the
    /// default theme. Same principle as ``postView``.
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

    /// Canonical ``--view=NAME`` names. ``grid`` matches ws-tabs;
    /// ``tree`` symmetry deferred (a future M3 enhancement) — for
    /// M2 use ``--show`` to surface the tree panel.
    static let canonicalViews = ["grid"]

    static func postView(_ name: String) -> Never {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard canonicalViews.contains(n) else {
            let msg = "facet: unknown view \"\(n)\" — expected one of: "
                + canonicalViews.joined(separator: ", ") + "\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        postControl("view:" + n)
    }

    // MARK: - Entry

    static func main() {
        // Drop the config.toml.example next to the (eventual)
        // config.toml on EVERY invocation — including client mode
        // calls like `facet --show` before any server has run.
        // Onboarding is "first time the user types `facet ...`,
        // they get the example file to copy + edit" regardless of
        // which CLI flag they happen to try first. Idempotent: no-
        // op when the example or the real config already exists.
        FacetConfig.writeExampleIfMissing()

        let argv = Array(CommandLine.arguments.dropFirst())
        for (i, a) in argv.enumerated() {
            switch true {
            case a == "--show", a == "--hide", a == "--toggle",
                 a == "--active", a == "--quit":
                postControl(String(a.dropFirst(2)))
            case a.hasPrefix("--theme="):
                postStyle(String(a.dropFirst("--theme=".count)))
            case a.hasPrefix("--style="):                  // legacy alias
                postStyle(String(a.dropFirst("--style=".count)))
            case a == "--theme", a == "--style":
                postStyle(i + 1 < argv.count ? argv[i + 1] : "")
            case a.hasPrefix("--view="):
                postView(String(a.dropFirst("--view=".count)))
            case a == "--view":
                postView(i + 1 < argv.count ? argv[i + 1] : "")
            default:
                break
            }
        }

        // Server mode. Anything below runs only when no client flag
        // matched above.

        let cfg = FacetConfig.load()
        // UserDefaults "style" (set by a runtime --theme=) wins
        // over the config TOML default — runtime change persists
        // until explicitly overridden again.
        let themeName = UserDefaults.standard.string(forKey: "style")
            ?? cfg.effectiveTheme
        pal = paletteFor(themeName)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AX.ensureTrusted()

        let backend = RiftAdapter()
        let controller = Controller(backend: backend, config: cfg)
        controller.start()

        // Apply config's default_view. nil → agent-only mode (no
        // panel, no overlay); facet stays running and waits for a
        // ``facet --show`` / ``facet --view=grid`` to bring
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
