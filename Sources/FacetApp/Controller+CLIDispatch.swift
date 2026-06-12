// CLI ↔ GUI IPC + the symmetric view / workspace / window dispatch
// family — the DNC observer (``installCLIControl``) that receives
// `facet` client-mode commands, the `dispatch*` routing it fans out
// to, and runtime re-theming (``applyStyle``). Extracted unchanged
// from Controller.swift (#182 phase 3) — same-module extension, no
// logic change. Stored state stays on the primary declaration
// (Controller.swift).

import AppKit
import FacetCore
import FacetView
import FacetViewTree
import FacetViewRail

extension Controller {

    // MARK: - CLI ↔ GUI IPC + theme

    func installCLIControl() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            forName: .init(ctrlNotificationName),
            object: nil, queue: .main
        ) { [weak self] note in
            let cmd = (note.object as? String) ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.debug("dnc cmd=\(cmd)")
                switch cmd {
                case "quit":     NSApp.terminate(nil)
                case "reload":   self.reloadConfig()
                case let s where s.hasPrefix("style:"):
                    self.applyStyle(
                        String(s.dropFirst("style:".count)))

                // Symmetric view ops — canonical-only, no aliases.
                case let s where s.hasPrefix("view:"):
                    // Payload: NAME[+active][+loading:MS][+geom:X,Y,W,H][+edge:E]
                    let rest = String(s.dropFirst("view:".count))
                    let parts = rest.split(separator: "+")
                    let name = String(parts.first ?? "")
                    let mods = parts.dropFirst().map(String.init)
                    let active = mods.contains("active")
                    let geom: NSRect? = mods
                        .first(where: { $0.hasPrefix("geom:") })
                        .flatMap { Self.parseGeom($0) }
                    let loadingMs: Int? = mods
                        .first(where: { $0.hasPrefix("loading:") })
                        .flatMap { Int($0.dropFirst("loading:".count)) }
                    let edge: RailEdge? = mods
                        .first(where: { $0.hasPrefix("edge:") })
                        .flatMap { RailEdge(rawValue: String($0.dropFirst("edge:".count))) }
                    self.dispatchView(name, active: active,
                                      geom: geom, loadingMs: loadingMs, edge: edge)
                case let s where s.hasPrefix("hide:"):
                    self.dispatchHide(
                        String(s.dropFirst("hide:".count)))
                case let s where s.hasPrefix("toggle:"):
                    self.dispatchToggle(
                        String(s.dropFirst("toggle:".count)))

                case let s where s.hasPrefix("workspace:"):
                    self.dispatchWorkspaceTarget(
                        String(s.dropFirst("workspace:".count)))

                case let s where s.hasPrefix("lens:"):
                    self.dispatchLensTarget(
                        String(s.dropFirst("lens:".count)))

                case "workspace-add":
                    self.backend.addWorkspace()
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("workspace-remove:"):
                    let raw = String(s.dropFirst("workspace-remove:".count))
                    self.backend.removeWorkspace(
                        at: raw.isEmpty ? nil : Int(raw))
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("workspace-rename:"):
                    self.backend.renameWorkspace(
                        at: nil,
                        to: String(s.dropFirst("workspace-rename:".count)))
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("workspace-move:"):
                    self.backend.moveActiveWorkspace(
                        to: Int(s.dropFirst("workspace-move:".count)) ?? 0)
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("window-move:"):
                    let n = Int(s.dropFirst("window-move:".count)) ?? 0
                    self.dispatchWindowMove(n)

                case let s where s.hasPrefix("window-move-follow:"):
                    let n = Int(
                        s.dropFirst("window-move-follow:".count)) ?? 0
                    self.dispatchWindowMove(n, follow: true)

                case let s where s.hasPrefix("window-mark:"):
                    let name = String(s.dropFirst("window-mark:".count))
                    if !self.backend.markFocusedWindow(name) {
                        self.setError(
                            "window --mark=\(name): no focused window")
                    }
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("window-focus-mark:"):
                    let name = String(
                        s.dropFirst("window-focus-mark:".count))
                    if !self.backend.focusMark(name) {
                        self.setError(
                            "window --focus-mark=\(name): no such mark")
                    } else {
                        self.scheduleReconcile(after: 0.05)
                    }

                case let s where s.hasPrefix("window-unmark:"):
                    let name = String(s.dropFirst("window-unmark:".count))
                    if !self.backend.unmark(name) {
                        self.setError(
                            "window --unmark=\(name): no such mark")
                    }
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("scratchpad-stash:"):
                    let name = String(s.dropFirst("scratchpad-stash:".count))
                    if !self.backend.stashScratchpad(name) {
                        self.setError(
                            "scratchpad --stash=\(name): no focused window")
                    }
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("scratchpad-toggle:"):
                    let name = String(s.dropFirst("scratchpad-toggle:".count))
                    if !self.backend.toggleScratchpad(name) {
                        self.setError(
                            "scratchpad --toggle=\(name): no such shelf")
                    }
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("scratchpad-release:"):
                    let name = String(s.dropFirst("scratchpad-release:".count))
                    if !self.backend.releaseScratchpad(name) {
                        self.setError(
                            "scratchpad --release=\(name): no such shelf")
                    }
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("set-layout:"):
                    let name = String(s.dropFirst("set-layout:".count))
                    self.dispatchSetLayout(name)

                case "retile":
                    self.dispatchRetile()

                case "workspace-balance":
                    self.backend.balanceActiveWorkspace()
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("workspace-rotate:"):
                    let deg = Int(
                        s.dropFirst("workspace-rotate:".count)) ?? 0
                    self.backend.rotateActiveWorkspace(degrees: deg)
                    self.scheduleReconcile(after: 0.05)

                case let s where s.hasPrefix("workspace-mirror:"):
                    let axis: MirrorAxis =
                        s.dropFirst("workspace-mirror:".count) == "vertical"
                        ? .vertical : .horizontal
                    self.backend.mirrorActiveWorkspace(axis)
                    self.scheduleReconcile(after: 0.05)

                case "window-toggle-float":
                    self.dispatchWindowAction(.toggleFloat)

                case "window-toggle-sticky":
                    self.dispatchWindowAction(.toggleSticky)

                case "window-toggle-orientation":
                    self.dispatchWindowAction(.toggleOrientation)

                case let s where s.hasPrefix("window-cycle-stack:"):
                    let dir = String(
                        s.dropFirst("window-cycle-stack:".count))
                    self.dispatchWindowAction(
                        dir == "prev" ? .cycleStackPrev
                                      : .cycleStackNext)

                case "window-grow-master":
                    self.dispatchWindowAction(.growMaster)

                case "window-shrink-master":
                    self.dispatchWindowAction(.shrinkMaster)

                case "window-inc-master":
                    self.dispatchWindowAction(.incMaster)

                case "window-dec-master":
                    self.dispatchWindowAction(.decMaster)

                case let s where s.hasPrefix("window-focus-dir:"):
                    if let d = Direction(rawValue:
                        String(s.dropFirst("window-focus-dir:".count))) {
                        self.dispatchWindowAction(.focusDir(d))
                    }

                case let s where s.hasPrefix("window-move-dir:"):
                    if let d = Direction(rawValue:
                        String(s.dropFirst("window-move-dir:".count))) {
                        self.dispatchWindowAction(.moveDir(d))
                    }

                default:
                    Log.debug("dnc unknown cmd=\(cmd) — ignored")
                }
            }
        }
    }

    /// Parse a "geom:X,Y,W,H" payload modifier from the DNC. Returns
    /// nil on malformed input (silently — Main.swift already validated
    /// at parse time, this is a defensive check at the receiver).
    static func parseGeom(_ s: String) -> NSRect? {
        let body = s.dropFirst("geom:".count)
        let parts = body.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return NSRect(x: parts[0], y: parts[1],
                      width: parts[2], height: parts[3])
    }

    // MARK: - Symmetric view dispatch

    /// CLI `facet --view=tree --loading[=MS]`: paint the tree
    /// skeleton now and hold it for `durationMs`, then repaint real
    /// content. An external tool (e.g. chord) fires this just before
    /// triggering a mac-desktop switch, so the shared
    /// `.canJoinAllSpaces` panel never flashes the previous
    /// mac desktop's tree during the switch (macOS gives no pre-switch
    /// hook — memory facet-per-native-space-ws). No-op while the user
    /// has hidden the panel or the grid owns the screen.
    private func showLoading(durationMs: Int) {
        if userHidden || isGridVisible { return }
        let ms = max(0, durationMs)
        Log.debug("controller: showLoading \(ms)ms (skeleton)")
        sidebarView.frame.size.width = panelHost.userWidth
        sidebarView.showSkeleton()
        panelHost.layout(contentHeight: sidebarView.skeletonHeight,
                         searching: false)
        if !panelHost.isVisible { panelHost.show() }
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(
            withTimeInterval: Double(ms) / 1000.0, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sidebarView.isSkeleton else { return }
                // Upper-bound reached without new content — drop the
                // skeleton and repaint whatever we have. (When new
                // content arrives first, `update` clears the skeleton
                // early and this is a no-op.)
                self.sidebarView.clearSkeleton()
                self.apply(self.lastWorkspaces)
            }
        }
    }

    /// Open (or activate) ``name``. Idempotent — re-issuing the
    /// same view doesn't toggle it off; use ``dispatchToggle`` /
    /// ``dispatchHide`` for that.
    private func dispatchView(_ name: String, active: Bool, geom: NSRect?,
                              loadingMs: Int? = nil, edge: RailEdge? = nil) {
        // Views are mutually exclusive: requesting any non-grid view
        // drops the full-screen grid overlay first. This is also how
        // the grid closes on a mac-desktop switch — the chord ctrl+→
        // binding fires `--view=tree --loading` just *before* the
        // switch, so the grid is gone before the OS slide. (Keeping it
        // open across the slide only ever flickers: macOS composites
        // no app window during the ~0.7s mac-desktop animation, regardless
        // of level / collectionBehavior — proven by a 9-variant
        // sandbox A/B, memory facet-space-slide-overlay-flicker. A
        // clean close beats an involuntary blink-and-return.) Immediate
        // teardown also un-gates `showLoading` (which no-ops while the
        // grid is up) so the tree skeleton paints on the new mac desktop.
        if name != "grid" && isGridVisible { hideGrid(immediate: true) }
        // The grid is a full-screen takeover that would cover the
        // rail; tear the rail down so it's not stranded underneath.
        // (The rail otherwise coexists with the tree — different
        // screen regions, complementary surfaces.)
        if name == "grid" && isRailVisible { hideRail() }
        switch name {
        case "tree":
            // Apply explicit geom BEFORE showing so the panel
            // appears at the right place on the first paint.
            if let g = geom { panelHost.setExplicitFrame(g) }
            if let ms = loadingMs { showLoading(durationMs: ms); return }
            if active { enterActive() } else { setHidden(false) }
        case "grid":
            // ``+active`` is silently a no-op for grid — the
            // overlay is always key/active by nature. Geom is
            // likewise ignored (grid is always full-screen).
            showGrid()
        case "rail":
            // ``+active`` / geom are no-ops — the rail is a passive
            // overview bar (never key). ``+edge`` (CLI ``--edge=``)
            // picks which screen edge it docks against; nil falls back
            // to the ``[rail] edge`` config default.
            showRail(edge: edge ?? config.effectiveRailEdge)
        default:
            Log.debug("dispatchView unknown=\(name) — ignored")
        }
    }

    private func dispatchHide(_ name: String) {
        switch name {
        case "tree": setHidden(true)
        case "grid": hideGrid()
        case "rail": hideRail()
        default:     Log.debug("dispatchHide unknown=\(name) — ignored")
        }
    }

    /// Switch to the Nth workspace (1-indexed from the user; the
    /// backend takes 0-indexed). Out-of-range silently no-ops (with
    /// a debug log) — the DNC receiver shouldn't exit the server
    /// just because a stale hotkey points past the current WS count.
    /// Idempotent: switching to the current WS is a backend no-op.
    /// Route a `workspace:` control payload — either an absolute
    /// 1-based index (`"2"`) or a relative target (`next` / `prev` /
    /// `recent`).
    private func dispatchWorkspaceTarget(_ arg: String) {
        switch arg {
        case "next":   dispatchWorkspaceRelative(.next)
        case "prev":   dispatchWorkspaceRelative(.prev)
        case "recent": dispatchWorkspaceRelative(.recent)
        case let s where s.hasPrefix("name:"):
            // Focus by workspace name (stable across reorder). No
            // explicit window pick → auto-focus the destination's
            // last-touched window, same contract as the index path.
            backend.switchWorkspace(
                named: String(s.dropFirst("name:".count)), autoFocus: true)
            scheduleReconcile(after: 0.05)
        default:       dispatchWorkspace(Int(arg) ?? 0)
        }
    }

    /// Route a `lens:` payload (M11-3 tag mode). The payload is
    /// `only:NAME` / `toggle:NAME` / `all`. The backend resolves the
    /// tag name and surfaces an unknown-tag error itself, so this just
    /// dispatches and schedules a repaint.
    private func dispatchLensTarget(_ arg: String) {
        if arg == "all" {
            backend.setLens(.all)
        } else if arg.hasPrefix("only:") {
            let name = String(arg.dropFirst("only:".count))
            guard !name.isEmpty else {
                Log.debug("dispatchLensTarget empty only: name — ignored")
                return
            }
            backend.setLens(.only(name))
        } else if arg.hasPrefix("toggle:") {
            let name = String(arg.dropFirst("toggle:".count))
            guard !name.isEmpty else {
                Log.debug("dispatchLensTarget empty toggle: name — ignored")
                return
            }
            backend.setLens(.toggle(name))
        } else {
            Log.debug("dispatchLensTarget unknown=\(arg) — ignored")
            return
        }
        scheduleReconcile(after: 0.05)
    }

    private func dispatchWorkspaceRelative(_ target: RelativeWorkspace) {
        // Same focus contract as the absolute path: no explicit window
        // pick, so the backend auto-focuses the destination's
        // last-touched window (memory [[facet-ws-switch-focus-management]]).
        backend.switchWorkspaceRelative(target, autoFocus: true)
        scheduleReconcile(after: 0.05)
    }

    private func dispatchWorkspace(_ n: Int) {
        let count = backend.workspaces().count
        guard n >= 1, n <= count else {
            setError("workspace \(n) out of range "
                + "(\(rangeHint(count: count)))")
            return
        }
        // CLI `workspace --focus=N`: no explicit window pick, so let
        // the backend auto-focus the last-touched window of the
        // destination (or activate Finder if empty). See memory
        // [[facet-ws-switch-focus-management]].
        backend.switchWorkspace(toIndex: n - 1, autoFocus: true)
        scheduleReconcile(after: 0.05)
    }

    /// Move the currently-focused window to the Nth workspace
    /// (1-indexed from the user; backend takes 0-indexed). Silent
    /// no-op (debug log only) when no focused window or N is out
    /// of range — a stale hotkey on an empty mac desktop shouldn't
    /// take down the server.
    private func dispatchWindowMove(_ n: Int, follow: Bool = false) {
        let count = backend.workspaces().count
        guard n >= 1, n <= count else {
            setError("window --move-to=\(n) out of range "
                + "(\(rangeHint(count: count)))")
            return
        }
        guard let id = backend.focusedWindow() else {
            setError("window --move-to=\(n): no focused window")
            return
        }
        backend.moveWindow(id, toWorkspaceIndex: n - 1)
        // send-and-follow: switch the active workspace to the
        // destination so focus follows the window over. autoFocus
        // lands on the just-moved window (now the last-touched
        // member there). Without --follow the window departs and
        // the user stays put.
        if follow {
            backend.switchWorkspace(toIndex: n - 1, autoFocus: true)
        }
        scheduleReconcile(after: 0.05)
    }

    private func dispatchToggle(_ name: String) {
        switch name {
        case "tree": setHidden(!userHidden)
        case "grid": toggleGrid()
        case "rail": toggleRail()
        default:     Log.debug("dispatchToggle unknown=\(name) — ignored")
        }
    }

    /// Set the active workspace's layout mode. The CLI validates
    /// the name (`canonicalLayoutMode`); a stray name landing
    /// here would silently no-op via the backend's own mode
    /// gate, but logging the receiver-side rejection makes
    /// `FACET_DEBUG` traces clearer.
    private func dispatchSetLayout(_ name: String) {
        guard let active = lastWorkspaces.first(where: \.isActive)
        else {
            setError("set-layout=\(name): no active workspace")
            return
        }
        backend.setLayoutMode(workspaceIndex: active.index,
                              mode: name)
        scheduleReconcile(after: 0.05)
    }

    /// `facet workspace --retile`: ask the backend to re-apply the active
    /// workspace's layout. A backend that delegates tiling to the OS
    /// would treat this as a no-op.
    private func dispatchRetile() {
        backend.retileActiveWorkspace()
        scheduleReconcile(after: 0.05)
    }

    /// `facet window --toggle-float` / `--toggle-orientation`:
    /// thin wrapper around `backend.perform`. The "no focused
    /// window" guard lives in the backend (NativeAdapter exits
    /// early when `focusedWindow()` is nil); we just log the
    /// dispatch here for `FACET_DEBUG` tracing.
    private func dispatchWindowAction(_ action: WindowAction) {
        Log.debug("dispatchWindowAction \(action)")
        backend.perform(action)
        scheduleReconcile(after: 0.05)
    }

    /// Live re-theme from `facet --theme=...`. Runtime-only —
    /// the change does NOT persist across restarts. config.toml
    /// is the single source of truth for theme; to make a runtime
    /// pick stick, edit ``theme = "..."`` in the user's config.
    func applyStyle(_ name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Log.debug("applyStyle name=\(key)")
        currentThemeName = key
        pal = resolve(paletteFor(key))
        panelHost.applyTheme()
        sidebarView.needsDisplay = true
        updateThemeAnimator()
    }

    /// Human-readable range hint for out-of-range error messages.
    /// `(1..15)` for the normal case; `no workspaces available` when
    /// the backend returned an empty list (= backend not yet ready,
    /// startup race, etc.) — much clearer than the cryptic `(1..0)`.
    private func rangeHint(count: Int) -> String {
        count > 0 ? "1..\(count)" : "no workspaces available"
    }
}
