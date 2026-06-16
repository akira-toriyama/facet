// Client mode — the half of facet's CLI surface that runs when at
// least one recognised flag / subcommand was passed: post the
// matching control notification to the running server instance over
// the DNC, then exit. The server-side observer
// (``Controller.installCLIControl``) routes it. This file holds the
// low-level `post*` notification primitives + the canonical-name /
// parse helpers the argv loop in ``FacetApp.main()`` (Main.swift)
// reads; the read-only `facet query` projections live in
// ``FacetApp+ClientQuery`` and the `facet <subject> <verb>` subcommand
// runners in ``FacetApp+ClientCommands``. Originally extracted from
// Main.swift (#182 phase 1); split three ways (P8-3) — same-module
// extension, no logic change.

import AppKit
import FacetCore
import FacetView

extension ArgCursor {
    /// Consume the next token as `flag`'s required value, or loud-exit(2)
    /// with a "missing argument" usage error when the args are exhausted
    /// (#227). Strict consumption: the token is taken verbatim — even a
    /// `--`-looking one — and the per-flag validator decides whether it's
    /// acceptable, so a negative coordinate or a literal `0` reads fine
    /// while a dropped value surfaces as a loud usage error rather than a
    /// silent mis-parse.
    mutating func value(for flag: String) -> String {
        guard let v = next() else {
            FacetApp.die("\(flag): missing argument")
        }
        return v
    }
}

extension FacetApp {

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

    /// Post ``theme:NAME``. Name must already be canonical
    /// (validated by ``canonicalTheme`` at parse time).
    static func postTheme(_ name: String) -> Never {
        postControl("theme:" + name)
    }

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

    /// Post ``lens:TARGET`` (M11-3 tag mode) where TARGET is
    /// `only:CSV` / `add:CSV` / `remove:CSV` / `toggle:CSV` / `all`, with
    /// CSV a comma-joined tag list (#228). The server resolves the names
    /// STRICTLY — any unknown name leaves the lens unchanged and surfaces
    /// a "no such tag" error.
    static func postLens(_ target: String) -> Never {
        postControl("lens:" + target)
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

    /// Post ``window-focus-dir:DIR`` / ``window-move-dir:DIR`` (②).
    /// Direction already canonical by parse time (`canonicalDirection`).
    static func postWindowFocusDir(_ dir: String) -> Never {
        postControl("window-focus-dir:" + dir)
    }

    static func postWindowMoveDir(_ dir: String) -> Never {
        postControl("window-move-dir:" + dir)
    }

    /// Validate + canonicalise a direction (up|down|left|right). Loud
    /// reject on typo (``exit(2)``) — same pattern as `canonicalLayoutMode`.
    static let canonicalDirections = ["up", "down", "left", "right"]

    static func canonicalDirection(_ name: String) -> String {
        canonicalOrDie(name, allowed: canonicalDirections, kind: "direction")
    }

    /// Validate + canonicalise a layout-mode name. Loud reject on
    /// typo (`exit(2)`) — same pattern as `canonicalView` /
    /// `canonicalTheme`.
    static let canonicalLayoutModes = LayoutRegistry.allModeNames

    static func canonicalLayoutMode(_ name: String) -> String {
        canonicalOrDie(name, allowed: canonicalLayoutModes, kind: "layout")
    }

    /// Parse the value of ``workspace --focus VALUE``. VALUE is a relative
    /// keyword (`next` / `prev` / `recent`), an absolute 1-based index, or
    /// a workspace **name**. Returns the canonical control payload:
    /// `next|prev|recent`, the index as a string, or `name:NAME`
    /// (case preserved). Numeric values are always indices — name a
    /// workspace non-numerically to reference it by name (yabai-style).
    static func parseWorkspaceFocus(_ value: String) -> String {
        switch value.lowercased() {
        case "next", "prev", "recent":
            return value.lowercased()
        default:
            if let n = Int(value), n > 0 { return String(n) }   // index
            return "name:" + validateWorkspaceName(
                value, flag: "workspace --focus")               // name
        }
    }

    /// Parse the value of ``--move-to N`` (positive integer, 1-indexed).
    static func parseMoveToInt(_ value: String) -> Int {
        parsePositiveInt(value, flag: "--move-to")
    }

    /// Generic 1-indexed positive-integer parser. Reused by every
    /// ``--… N`` flag whose value names a workspace slot. Takes the
    /// already-extracted value token (the cursor consumed it).
    static func parsePositiveInt(_ value: String,
                                         flag: String) -> Int {
        parseIntFlag(value, flag: flag, requirePositive: true,
                     positiveHint: "1-indexed, ")
    }

}
