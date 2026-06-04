// Top-level orchestrator. Wires:
//   - a ``WindowBackend`` (``FacetAdapterNative``, sole backend since v2.0.0)
//   - the tree view (``SidebarView``) + its panel chrome
//     (``PanelHost``)
//   - the grid view + its overlay lifecycle
//   - the event stream (``backend.events`` → AsyncStream Task →
//     debounced refresh) and a periodic poll fallback for backends
//     that don't emit
//   - ``AXTitles`` resolve to fill in titles the backend left blank
//   - the focus retry state machine (``Focus.withRetry`` /
//     ``Focus.assert``)
//   - keyboard-nav (``--active``) + search
//   - distributed-notification CLI IPC
//
// Conforms to ``TreeController`` so ``SidebarView`` can talk to it
// without knowing about any of the above.

import AppKit
import FacetCore
import FacetAccessibility
import FacetView
import FacetViewTree
import FacetViewGrid
import FacetViewRail

@MainActor
final class Controller: NSObject {

    // MARK: - Wiring

    let backend: any WindowBackend
    /// Mutable so `reloadConfig()` can swap in fresh values when
    /// the user edits config.toml (file watcher) or sends
    /// `facet --reload`. Always read through `effective*`
    /// accessors so clamping survives a typo'd reload.
    private var config: FacetConfig
    private let configPath: String
    private var configWatcher: ConfigWatcher?
    private let panelHost: PanelHost
    private let sidebarView: SidebarView

    /// Phase δ: panel-side response to display reconfigure
    /// (resolution / hot-plug / lid / sleep wake). Lives here
    /// — not on the backend — because the panel is a view-layer
    /// concern; the backend has its OWN `DisplayChangeObserver`
    /// for the tile / anchor-rescue side. Two observers, each
    /// scoped to its layer.
    private var displayObserver: DisplayChangeObserver?

    // MARK: - State

    /// Latest workspaces snapshot — held so the grid view can render
    /// immediately on first show without round-tripping the backend.
    private(set) var lastWorkspaces: [Workspace] = []
    /// Active-WS index at the previous ``apply`` — lets the
    /// event-driven preview refresh spot a workspace switch (the
    /// snapshot frame is switch-stable by design, so an index change is
    /// the only reliable signal that windows were parked / unparked).
    private var prevActiveWSIndex: Int?
    private var userHidden = false

    /// Last surfaced operational error (e.g. out-of-range workspace
    /// switch, no-focused-window window move). Held in-memory and
    /// folded into the next `writeStatus()` snapshot so `facet
    /// status` can surface it to the user. Single-slot — newest
    /// overwrites — keeps the status output bounded.
    private var lastError: String?
    /// Pauses refresh/apply while the user is mid-grip-drag, so a
    /// layout pass can't stomp the panel height the next mouseDragged
    /// is about to read (memory: grid-branch-grip-intermittent).
    private var refreshPending = false

    // MARK: - Preview (hover overlay + grid thumbnails)

    private let previewPool = PreviewOverlayPool()
    /// Held as ``Any`` so the class compiles on macOS 13 (the
    /// ``WindowPreview`` type is gated on macOS 14+). Cast at use
    /// site.
    private var winPreview: Any?
    private var previewTimer: Timer?
    private var thumbnailTimer: Timer?
    private var thumbnailTimerInterval: TimeInterval?

    // MARK: - Real-window DnD (枠C)

    /// Global mouse monitor that turns a drag of a tiled window onto
    /// another into a swap / insert. Installed once at start, lives the
    /// whole session. See `installRealWindowDrag` (RealWindowDrag.swift).
    var realWindowDrag: RealWindowDragMonitor?
    /// Live prediction overlay shown during a real-window drag (PR-3).
    let dndOverlay = DndPredictionOverlay()
    /// One prediction round-trip at a time — throttles the per-move
    /// `predictedDropFrames` requests to the backend's response rate.
    var dndPredictionInFlight = false

    /// Live real-window RESIZE follow (枠C 機能2). The gesture shares the
    /// DnD monitor; these track the resize half. `liveGestureIsResize`
    /// latches once a tick classifies the drag as a resize, so the move
    /// drop-overlay stays hidden for the rest of the gesture;
    /// `liveResizeLastFrame` feeds the per-tick dead-zone; the in-flight
    /// flag + timestamp throttle the neighbour AX writes to ~30fps. See
    /// `liveDragTick` / `resolveLiveDragEnd` (RealWindowDrag.swift).
    var liveGestureIsResize = false
    var liveResizeLastFrame: CGRect?
    var liveResizeInFlight = false
    var liveResizeLastAt = Date.distantPast
    /// Was the PREVIOUS tick classified as a resize? A drag is only
    /// latched to resize once TWO consecutive ticks see the size changed,
    /// so a single-frame OS size blip during a title-bar move (display
    /// clamp / app self-resize) can't latch resize or write a stray ratio.
    /// The in-flight gate serialises ticks, so this reads consistently.
    var liveResizePrevResized = false

    // MARK: - Grid overview

    private var gridOverlay: GridOverlay?
    private var gridView: GridView?
    private var gridBackdrop: NSView?
    private var gridKbMonitor: Any?
    /// Remembered while the grid is up so we can restore exactly the
    /// pre-show visibility state on dismiss.
    private var treeWasHidden = false
    var isGridVisible: Bool { gridOverlay != nil }

    // MARK: - Workspace rail (bottom overview bar)

    private var railOverlay: RailOverlay?
    private var railView: RailView?
    /// Local key monitor for the rail's Escape-to-dismiss while it's up.
    private var railKbMonitor: Any?
    /// Local scroll-wheel monitor (⑦) — rotates the carousel while the
    /// rail is up. A monitor (not an NSView override) so it fires for the
    /// nonactivating panel, exactly like `railKbMonitor`.
    private var railScrollMonitor: Any?
    var isRailVisible: Bool { railOverlay != nil }

    // MARK: - Active mode (kb-nav)

    private var kbMonitor: Any?
    /// Frontmost app at the moment ``enterActive`` was called, so
    /// ``exitActive(restore: true)`` can hand focus back.
    private var prevApp: NSRunningApplication?
    private let searchDelegate = SearchFieldDelegate()

    // MARK: - Subscription / polling

    private var eventTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var pollTimer: Timer?
    /// Catches backends that don't emit events for some changes
    /// (workspace renames, layout-mode switches via external CLI).
    private let pollInterval: TimeInterval = 2.0
    /// Debounce window for event-driven refreshes — coalesces a
    /// burst of events into a single backend query.
    private let refreshDebounce: TimeInterval = 0.05

    // MARK: - Init

    init(backend: any WindowBackend,
         config: FacetConfig,
         configPath: String = FacetConfig.defaultPath)
    {
        self.backend = backend
        self.config = config
        self.configPath = configPath
        let view = SidebarView(
            frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: 400),
            backend: backend)
        self.sidebarView = view
        self.panelHost = PanelHost(view: view)
        super.init()
        view.controller = self
        if #available(macOS 14.0, *) { winPreview = WindowPreview() }
        searchDelegate.onChange = { [weak self] q in
            MainActor.assumeIsolated {
                self?.sidebarView.setQuery(q)
            }
        }
        panelHost.searchBar.field.delegate = searchDelegate
        // Keep kbNav in sync with the panel's key status. The panel
        // only becomes key via explicit kb-nav entry (`--active` →
        // makeKey); a plain tree-row click no longer grabs key (that
        // would break same-app focus — see KeyablePanel). So this now
        // fires on the --active enter/exit, not on every click.
        panelHost.onKeyChanged = { [weak self] isKey in
            self?.handlePanelKeyChange(isKey: isKey)
        }
        applyBorderFromConfig()
        seedTreeGeometry()
    }

    /// Seed the tree panel's geometry from `[tree]` config (pos-x /
    /// pos-y / width / height — all four required). Called at startup +
    /// on hot-reload; when set it re-pins the panel (config is
    /// authoritative). Runtime drags / CLI geom are session-only, so a
    /// reload snaps back to the config geometry. No `[tree]` geometry →
    /// no-op (the built-in default, or the current session position,
    /// stands).
    private func seedTreeGeometry() {
        if let g = config.effectiveTreeGeometry {
            panelHost.setExplicitFrame(g)
        }
    }

    /// Push the config's `[border]` effect onto the panel. Called at
    /// startup + on hot-reload. "off" falls back to the theme-accent
    /// border; a named effect paints its steady neon color + glow.
    private func applyBorderFromConfig() {
        let e = config.effectiveBorderEffect
        let g = config.effectiveBorderGlow
        let w = config.effectiveBorderWidth
        let cs = config.effectiveBorderCycleSeconds
        let mn = config.effectiveBorderMinWidth
        let mx = config.effectiveBorderMaxWidth
        panelHost.applyBorder(effectName: e, glow: g, width: w,
                              cycleSeconds: cs, minWidth: mn, maxWidth: mx)
        // The grid + rail borders (when their overlay is up) —
        // reconfigure on a hot-reload too.
        gridView?.applyBorder(effectName: e, glow: g, width: w,
                              cycleSeconds: cs, minWidth: mn, maxWidth: mx)
        railView?.applyBorder(effectName: e, glow: g, width: w,
                              cycleSeconds: cs, minWidth: mn, maxWidth: mx)
    }

    private func handlePanelKeyChange(isKey: Bool) {
        if isKey {
            if !sidebarView.kbNav { sidebarView.enterKbNav() }
        } else {
            // Drop kbNav. If we got here via --active's
            // _exitActiveImpl path, exitKbNav has already run and
            // this is a harmless idempotent call.
            if sidebarView.kbNav { sidebarView.exitKbNav() }
        }
    }

    // MARK: - Lifecycle

    /// Start the controller: subscribe to backend events, schedule
    /// the fallback poll, run an initial refresh. Idempotent only
    /// in the sense that calling it twice will leak the previous
    /// event task — don't.
    func start() {
        Log.debug("controller start")
        logConfigWarnings()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.backend.events {
                await MainActor.run { self.requestRefresh() }
            }
        }
        // Adapter error stream → lastError slot in facet status.
        // De-dupe against the *Controller's current* lastError so:
        //  - a long stream of identical recurring-fault messages
        //    still collapses (they all match the live slot, skip).
        //  - but if another path (e.g. dispatch setError) has
        //    overwritten the slot in the meantime, a subsequent
        //    identical adapter message gets through and restores
        //    the recurring fault as the visible one.
        //
        // Previous version used a local `var last` here, which
        // kept dedupe-state out of sync with the real lastError
        // — once a dispatch error overwrote the slot, the
        // backend's still-recurring error stayed silenced forever.
        errorTask = Task { [weak self] in
            guard let self else { return }
            for await msg in self.backend.errors {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let cur = self.lastError,
                       cur.hasPrefix(msg) { return }
                    self.setError(msg)
                }
            }
        }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        rescheduleThumbnailTimer()
        installCLIControl()
        writeStatus([])     // touch the file so `facet status` works
                            // even before the first backend reply
        installConfigWatcher()
        installDisplayObserver()
        installRealWindowDrag()
        refresh()
    }

    /// Spin up the FS watcher on ~/.config/facet/config.toml so
    /// edits land without requiring `facet --reload`. Both the
    /// watcher (A path) and the DNC `reload` command (B path)
    /// converge on `reloadConfig()`.
    private func installConfigWatcher() {
        configWatcher = ConfigWatcher(path: configPath) {
            [weak self] in
            MainActor.assumeIsolated { self?.reloadConfig() }
        }
        configWatcher?.start()
    }

    /// Phase δ: panel-side reconfigure handler. Fires once
    /// 0.5 s after the OS settles on a new display layout;
    /// `PanelHost.handleDisplayReconfigure` validates the
    /// persisted panel rect against the new screen state and
    /// snaps if needed.
    private func installDisplayObserver() {
        let obs = DisplayChangeObserver { [weak self] in
            self?.panelHost.handleDisplayReconfigure()
        }
        displayObserver = obs
        obs.start()
    }

    /// Re-read config.toml and apply whatever changed. Idempotent:
    /// calling it when nothing has changed is harmless (the
    /// effective-accessor values are equal, the conditional
    /// applyStyle / writeStatus calls become no-ops).
    ///
    /// Reload-on (memory facet-cli-surface N11):
    ///   - theme           → applyStyle live
    ///   - preview-mode    → next hover-preview reads the new value
    ///   - [workspaces]    → reflected in writeStatus (the live
    ///                       data-model overlay onto facet
    ///                       workspaces lands at Phase α impl)
    /// Reload-off (intentionally — restart required):
    ///   - default-view
    func reloadConfig() {
        let fresh = FacetConfig.load(path: configPath)
        let oldTheme = config.effectiveTheme
        let oldPrev = config.effectiveTreePreviewMode
        config = fresh
        logConfigWarnings()
        applyBorderFromConfig()
        seedTreeGeometry()
        let newTheme = config.effectiveTheme
        let newPrev = config.effectiveTreePreviewMode
        Log.debug("reloadConfig: theme=\(oldTheme)→\(newTheme) "
            + "preview-mode=\(oldPrev)→\(newPrev)")
        if newTheme != oldTheme {
            applyStyle(newTheme)
        }
        // Always refresh the snapshot — [workspaces] changes need
        // to surface in `facet status` without waiting for the
        // next backend event.
        writeStatus(lastWorkspaces)
    }

    /// Surface any named-enum config value that silently clamped to a
    /// default (e.g. a layout name carried across a breaking rename:
    /// `tall` → `master-left` now degrades to `float`). `Log.line` —
    /// always on, so brew / plain `open Facet.app` users see it too,
    /// not just `FACET_DEBUG` runs. Fired once per load (startup +
    /// hot-reload), never from the per-tick `effective*` accessors.
    private func logConfigWarnings() {
        for warning in config.unknownValueWarnings() { Log.line(warning) }
    }

    // MARK: - CLI ↔ GUI IPC + theme

    private func installCLIControl() {
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

    /// Open (or activate) ``name``. Idempotent — re-issuing the
    /// same view doesn't toggle it off; use ``dispatchToggle`` /
    /// ``dispatchHide`` for that.
    private var loadingTimer: Timer?

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
        pal = paletteFor(key)
        panelHost.applyTheme()
        sidebarView.needsDisplay = true
    }

    // MARK: - Refresh / apply

    private func requestRefresh() {
        if refreshPending { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + refreshDebounce
        ) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    private func refresh() {
        // Don't re-query (and thus re-tile) while the user is dragging a
        // tiled window — the per-refresh re-tile in the adapter would
        // snap the window back to its slot mid-drag. The drop commit (or
        // the next refresh after release) re-tiles to the final layout.
        if realWindowDrag?.inProgress == true {
            Log.debug("refresh skipped (real-window drag in progress)")
            return
        }
        Log.debug("refresh dispatch")
        let bk = backend
        cliQueue.async {
            let wss = bk.workspaces()
            // Fill in titles the backend left blank (AX, off-main).
            let titles = AXTitles.resolve(wss)
            Log.debug("refresh fetched wss=\(wss.count) titles=\(titles.count)")
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.apply(wss, titles)
                }
            }
        }
    }

    private func apply(_ wss: [Workspace],
                       _ titles: [WindowID: String] = [:]) {
        // First non-empty snapshot? Warm the thumbnail cache one-shot
        // so the very first `--view=grid` (especially right after
        // launch) shows screenshots instead of falling back to app
        // icons. The background timer's first tick is `interval` s
        // away — too late if the user opens the grid immediately.
        let firstRealApply = lastWorkspaces.isEmpty && !wss.isEmpty
        // Snapshot the OLD active workspace's live frames before the new
        // snapshot replaces them — the event-driven preview diff below
        // compares against these to spot in-place moves / retiles. Only
        // the active WS reports a live frame (inactive WSs report a
        // would-be tile slot that doesn't track real pixels), so we
        // capture only the active set, and only when a preview surface
        // exists (skipped entirely on macOS 13).
        // Also remember which WS each window lived in, to spot a
        // cross-workspace move (trigger 3 below).
        var prevActiveFrames: [WindowID: CGRect] = [:]
        var prevWSofWindow: [WindowID: Int] = [:]
        var prevOnscreen: [WindowID: Bool] = [:]
        if #available(macOS 14.0, *), winPreview != nil {
            let oldActiveIdx = lastWorkspaces.first(where: { $0.isActive })?.index
            for ws in lastWorkspaces {
                let active = ws.index == oldActiveIdx
                for w in ws.windows {
                    prevWSofWindow[w.id] = ws.index
                    // Capture for ALL windows (any WS): a hide-reclaim
                    // reveal can land on an inactive WS too (trigger 4).
                    prevOnscreen[w.id] = w.isOnscreen
                    if active, let f = w.frame { prevActiveFrames[w.id] = f }
                }
            }
        }
        let prevActive = prevActiveWSIndex
        // Keep the snapshot fresh even when hidden so the grid can
        // render immediately without a backend round-trip.
        lastWorkspaces = wss
        prevActiveWSIndex = wss.first(where: { $0.isActive })?.index
        // Neon border flash on a real workspace switch (no-op when
        // `[border] effect` is off). Fires on whichever view is up — the
        // tree panel, the grid overlay, or the rail (`gridView` /
        // `railView` != nil iff open). `prevActive == nil` = the first
        // apply (startup): skip so the steady border just appears.
        if let prev = prevActive, prevActiveWSIndex != prev {
            if panelHost.isVisible { panelHost.flashBorder() }
            gridView?.flashBorder()
            railView?.flashBorder()
        }
        if let g = gridView {
            g.workspaces = wss
            g.activeIndex = wss.first(where: { $0.isActive })?.index
            g.layoutCells()       // refresh open grid on backend events
        }
        // The rail is a *persistent* bar (unlike the snapshot-on-show
        // grid), so keep it live with every reconcile — the active-WS
        // highlight + window counts track switches and add/close.
        if let rv = railView {
            let oldActive = rv.activeIndex
            let newActive = wss.first(where: { $0.isActive })?.index
            rv.workspaces = wss
            rv.activeIndex = newActive
            // 2-b carousel: an EXTERNAL switch (CLI / another view) while
            // the rail is open re-centres the strip on the new active —
            // but only when the user isn't mid-browse (selected == the
            // old active), so a manual rotation isn't yanked back.
            if rv.selectedWS == oldActive, let na = newActive {
                rv.selectedWS = na
            }
            rv.layoutCells()      // refresh open rail on backend events
        }
        if firstRealApply, #available(macOS 14.0, *) {
            refreshThumbnailCache()
        }
        // Event-driven preview refresh — the geometry / visibility half
        // that the ~4 s background timer (content freshness) can't react
        // to promptly. Four triggers feed one stale-id set:
        //   (1) WS switch — the snapshot frame is switch-stable by
        //       design and parking keeps a window on a 1×41 on-screen
        //       sliver, so neither a frame nor an isOnscreen delta
        //       fires; the active-WS index changing is the only
        //       reliable signal. Re-warm the now-active mac desktop.
        //   (2) In-place move / resize on the ACTIVE WS (retile, live
        //       drag-resize, external move) — its windows report a live
        //       frame, so an epsilon-gated delta is the real signal.
        //   (3) Cross-WS move — a window whose workspace membership
        //       changed (CLI --move-to without --follow, keyboard
        //       file-into-WS, grid / rail drop). A window that lands on
        //       an INACTIVE WS reports a would-be frame that (2) can't
        //       trust, but the membership change itself is unambiguous.
        //       (A tree DnD lands in (1)+(3): it moves AND switches.)
        //   (4) Reveal — a window whose `isOnscreen` flipped false→true
        //       (hide-reclaim restore: Cmd+H unhide / Cmd+M deminiaturize
        //       / tree-click reveal). It couldn't be captured while
        //       hidden, so its cached thumbnail is stale / blank —
        //       re-capture now. (トミー's hide-reclaim PR2 requirement.)
        // Invalidate drops the stale cache for every surface (tree
        // re-captures lazily on the next hover); the open grid / rail
        // then gets a fresh capture pushed via `pushFreshThumbnails`.
        if #available(macOS 14.0, *), let wp = winPreview as? WindowPreview {
            let newActive = wss.first(where: { $0.isActive })
            var stale: [WindowID] = []
            if newActive?.index != prevActive {                  // (1) switch
                stale.append(contentsOf: newActive?.windows.map(\.id) ?? [])
            }
            if let active = newActive {                          // (2) in-place
                for w in active.windows {
                    guard let nf = w.frame, let of = prevActiveFrames[w.id]
                    else { continue }
                    // 2 pt epsilon: ignore sub-pixel / mid-animation
                    // jitter, catch real moves (tens of points).
                    if abs(of.minX - nf.minX) > 2 || abs(of.minY - nf.minY) > 2
                        || abs(of.width - nf.width) > 2
                        || abs(of.height - nf.height) > 2 {
                        stale.append(w.id)
                    }
                }
            }
            for ws in wss {                                      // (3) cross-WS move
                for w in ws.windows where prevWSofWindow[w.id].map({
                    $0 != ws.index
                }) == true {
                    stale.append(w.id)
                }
            }
            for ws in wss {                                      // (4) reveal
                for w in ws.windows
                    where prevOnscreen[w.id] == false && w.isOnscreen {
                    stale.append(w.id)
                }
            }
            if !stale.isEmpty {
                let ids = Array(Set(stale))
                for id in ids { wp.invalidate(id) }   // all surfaces; tree = lazy
                pushFreshThumbnails(ids, wp)          // no-op if no overview open
                Log.debug("preview-refresh: \(ids.count) window(s) "
                    + "(switch=\(newActive?.index != prevActive))")
            }
        }
        if userHidden { return }
        guard !wss.isEmpty, NSScreen.main != nil else {
            panelHost.hide(); return
        }
        sidebarView.frame.size.width = panelHost.userWidth
        sidebarView.forceRedraw()
        // Mac desktop ordinal (read-only SkyLight) for the tree's top
        // handle band. 0 = SkyLight unavailable → no name.
        let activeMacDesktopID = MacDesktops.activeID()
        let macDesktopOrdinal = activeMacDesktopID == 0
            ? nil : MacDesktops.ordinal(for: activeMacDesktopID)
        let contentH = sidebarView.update(wss, titles: titles,
                                          macDesktop: macDesktopOrdinal)
        panelHost.layout(contentHeight: contentH,
                         searching: sidebarView.searching)
        if !panelHost.isVisible { panelHost.show() }
        writeStatus(wss)
    }

    /// Snapshot the current workspace state to
    /// `/tmp/facet-status.json` so `facet status` (client mode)
    /// has something to read. Atomic write — partial-file races
    /// are impossible.
    ///
    /// Called from `apply()` (every reconcile) and once during
    /// `start()` so the file exists even before the first backend
    /// event lands. Errors are swallowed: the status file is a
    /// debugging convenience, not a correctness path.
    private func writeStatus(_ wss: [Workspace]) {
        let entries = wss.map { w in
            WorkspaceStatusEntry(
                index: w.index + 1,     // 1-indexed for the CLI surface
                name: w.name,
                active: w.isActive,
                windowCount: w.windows.count,
                stickyCount: w.windows.filter(\.isSticky).count)
        }
        let snap = StatusSnapshot(
            backend: backend.name,
            theme: config.effectiveTheme,
            defaultView: config.effectiveDefaultView,
            workspaces: entries,
            stashed: backend.stashedScratchpads(),
            lastError: lastError,
            timestamp: ISO8601DateFormatter().string(from: Date()))
        do { try snap.write() } catch {
            Log.debug("writeStatus failed: \(error)")
        }
    }

    /// Record an operational error so the next `writeStatus()` —
    /// and therefore `facet status` — surfaces it. Single-slot
    /// (newest overwrites): the status file shows the most recent
    /// thing that went wrong, not a history. Re-snapshots
    /// immediately so the file reflects the new error without
    /// waiting for the next reconcile.
    ///
    /// Call sites are intentionally narrow today (dispatch
    /// out-of-range only). Broaden later — AX focus failure,
    /// backend command failure, etc. — as the seam proves out.
    private func setError(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        lastError = "\(message) at \(ts)"
        Log.line("error: \(lastError ?? "")")
        writeStatus(lastWorkspaces)
    }

    /// Human-readable range hint for out-of-range error messages.
    /// `(1..15)` for the normal case; `no workspaces available` when
    /// the backend returned an empty list (= backend not yet ready,
    /// startup race, etc.) — much clearer than the cryptic `(1..0)`.
    private func rangeHint(count: Int) -> String {
        count > 0 ? "1..\(count)" : "no workspaces available"
    }

    // MARK: - Preview / thumbnail timer

    /// Tear down + recreate the thumbnail timer so the interval
    /// reflects the current config. ``nil`` interval = disabled (no
    /// background capture; cells fall back to icons momentarily on
    /// each grid open).
    private func rescheduleThumbnailTimer() {
        guard #available(macOS 14.0, *) else { return }
        let want = config.effectiveThumbnailRefreshInterval
        if thumbnailTimerInterval == want { return }
        thumbnailTimer?.invalidate()
        thumbnailTimer = nil
        thumbnailTimerInterval = want
        guard let interval = want else { return }
        thumbnailTimer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshThumbnailCache() }
        }
    }

    /// Touch the WindowPreview cache for every known window so
    /// captures stay fresh in the background. Cheap when within
    /// TTL (one dict lookup per window, no capture work).
    @available(macOS 14.0, *)
    private func refreshThumbnailCache() {
        guard let wp = winPreview as? WindowPreview else { return }
        for ws in lastWorkspaces {
            for win in ws.windows {
                wp.request(win.id) { _, _, _ in /* warm only */ }
            }
        }
    }

    /// Force a re-capture for every window in the listed workspace
    /// indices. Called after a DnD or workspace-swap so the cached
    /// thumbnails (which may be old size / old crop after a BSP /
    /// stack reflow) refresh instead of waiting for the 5 s TTL.
    func refreshGridThumbnails(forWSIndices indices: [Int],
                               in wss: [Workspace]) {
        guard #available(macOS 14.0, *),
              let wp = winPreview as? WindowPreview,
              gridView != nil
        else { return }
        let want = Set(indices)
        let ids: [WindowID] = wss
            .filter { want.contains($0.index) }
            .flatMap { $0.windows.map(\.id) }
        // Invalidate first so any refresh tick firing before the
        // delay below can't paint with the stale cache.
        for id in ids { wp.invalidate(id) }
        // 50 ms is the empirical floor where the WM's reflow has
        // committed but the user still feels the refresh as "right
        // after" the drop. Under 30 ms tends to grab the pre-move
        // frame on BSP layouts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            [weak self] in
            guard self != nil else { return }
            for id in ids {
                wp.request(id) { [weak self] img, _, gotID in
                    MainActor.assumeIsolated {
                        self?.gridView?.setThumbnail(img, for: gotID)
                    }
                }
            }
        }
    }

    /// Re-capture the windows of the listed workspaces and feed them to
    /// the rail. After a move/swap the affected windows' frames change,
    /// so the snapshot-on-show cache is stale. Same shape as
    /// ``refreshGridThumbnails`` (rail uses the shared ``winPreview``).
    func refreshRailThumbnails(forWSIndices indices: [Int],
                               in wss: [Workspace]) {
        guard #available(macOS 14.0, *),
              let wp = winPreview as? WindowPreview,
              railView != nil
        else { return }
        let want = Set(indices)
        let ids: [WindowID] = wss
            .filter { want.contains($0.index) }
            .flatMap { $0.windows.map(\.id) }
        for id in ids { wp.invalidate(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard self != nil else { return }
            for id in ids {
                wp.request(id) { [weak self] img, _, gotID in
                    MainActor.assumeIsolated {
                        self?.railView?.setThumbnail(img, for: gotID)
                    }
                }
            }
        }
    }

    /// Re-capture the given windows and push the fresh image into
    /// whichever overview is open. Unlike ``refreshGridThumbnails`` /
    /// ``refreshRailThumbnails`` (single-shot DnD/swap call sites), this
    /// does NOT pre-invalidate — the event-driven caller already dropped
    /// the truly-stale entries, so ``request``'s 5 s TTL / inflight
    /// guards can short-circuit a burst of reconcile passes into one
    /// capture per window. No-op when neither overview is on screen (the
    /// tree refreshes lazily on the next hover off the invalidated
    /// cache, so it needs no push).
    @available(macOS 14.0, *)
    private func pushFreshThumbnails(_ ids: [WindowID], _ wp: WindowPreview) {
        guard gridView != nil || railView != nil, !ids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard self != nil else { return }
            for id in ids {
                wp.request(id) { [weak self] img, _, gotID in
                    MainActor.assumeIsolated {
                        self?.gridView?.setThumbnail(img, for: gotID)
                        self?.railView?.setThumbnail(img, for: gotID)
                    }
                }
            }
        }
    }

    // MARK: - Hover preview reconcile

    /// Debounced reconciliation of `PreviewOverlay`s with whatever
    /// the sidebar's hover / kb-selection currently points at.
    func _previewTargetChangedImpl() {
        previewTimer?.invalidate()
        guard #available(macOS 14.0, *),
              let wp = winPreview as? WindowPreview
        else { return }
        let targets = sidebarView.previewTargets()
        let ids = Set(targets.map(\.window))
        if ids.isEmpty {
            wp.bump(); previewPool.hideAll(); return
        }
        if ids == previewPool.inUseWindows { return }  // exact set already up
        // Drop now-irrelevant overlays immediately (don't wait for
        // the dwell) so e.g. WS-wide previews vanish the instant the
        // cursor moves into one window row. Overlays that survive
        // into the new set are kept → no flicker for still-relevant
        // targets.
        previewPool.setActiveWindows(ids)
        wp.bump()
        previewTimer = Timer.scheduledTimer(
            withTimeInterval: 0.18, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Re-resolve after the dwell (target may have moved).
                let now = self.sidebarView.previewTargets()
                let nowIDs = Set(now.map(\.window))
                guard nowIDs == ids else { return }
                let mode = self.config.effectiveTreePreviewMode
                for t in now {
                    wp.request(t.window) { [weak self] img, _, gotID in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            let cur = self.sidebarView.previewTargets()
                            guard let nt = cur.first(where: {
                                $0.window == gotID
                            }) else { return }
                            let frame: NSRect
                            if mode == "mirror", let wf = nt.windowFrame {
                                frame = Self.cgFrameToAppKit(wf)
                            } else {
                                // Stack index = position in the current
                                // ordered list (WS-header hover yields
                                // several targets sharing one anchor).
                                let pos = cur.firstIndex(where: {
                                    $0.window == gotID
                                }) ?? 0
                                frame = Self.popoverFrame(
                                    anchor: nt.rowAnchor,
                                    image: img, stackIndex: pos)
                            }
                            self.previewPool.show(
                                gotID, img: img, screenFrame: frame)
                        }
                    }
                }
            }
        }
    }

    /// Mirror-mode: convert a Quartz (top-left origin) backend
    /// window frame to an AppKit (bottom-left, primary-screen
    /// origin) screen rect. Multi-display arrangements where the
    /// secondary screen sits above the primary aren't handled
    /// here — the conversion uses the primary screen's height
    /// only. (Same behaviour as the pre-popover code; if it
    /// matters, `tree.preview-mode = "popover"` sidesteps it.)
    static func cgFrameToAppKit(_ r: CGRect) -> NSRect {
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }?
            .frame.height) ?? NSScreen.main?.frame.height ?? r.maxY
        return NSRect(x: r.minX, y: primaryH - r.maxY,
                      width: r.width, height: r.height)
    }

    /// Place the preview popover next to a sidebar row.
    ///
    /// - Sizes the panel to the image aspect, capped at
    ///   `popoverMaxSize` so a 4K window doesn't fill the screen.
    /// - Prefers the right side of the row; auto-flips left if
    ///   that overflows the screen (e.g. sidebar parked on the
    ///   right edge).
    /// - For workspace-header hover the caller passes the same
    ///   anchor for every window of the WS and varies `stackIndex`
    ///   — popovers stack downward with a small gap.
    /// - Clamps to the anchor screen's `visibleFrame` (menu bar +
    ///   Dock excluded).
    static func popoverFrame(
        anchor: NSRect, image: NSImage?, stackIndex: Int
    ) -> NSRect {
        let maxSize = NSSize(width: 320, height: 220)
        let gap: CGFloat = 8
        let stackGap: CGFloat = 4

        let imgSize = image?.size ?? NSSize(width: 16, height: 10)
        let aspect = imgSize.width / max(imgSize.height, 1)
        var w = maxSize.width
        var h = w / aspect
        if h > maxSize.height {
            h = maxSize.height; w = h * aspect
        }

        var x = anchor.maxX + gap
        let stackDrop = CGFloat(stackIndex) * (h + stackGap)
        // AppKit screen coords: maxY = top of anchor. Place popover
        // top-aligned with the row's top, then push down for stack.
        var y = anchor.maxY - h - stackDrop

        let mid = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(mid) }
            ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            if x + w > vis.maxX {
                x = anchor.minX - gap - w     // flip to left
            }
            x = max(vis.minX, min(vis.maxX - w, x))
            y = max(vis.minY, min(vis.maxY - h, y))
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Grid lifecycle

    func toggleGrid() {
        if isGridVisible { hideGrid() } else { showGrid() }
    }

    func showGrid() {
        Log.debug("showGrid request (isVisible=\(isGridVisible))")
        if isGridVisible { return }
        guard let scr = NSScreen.main else { return }
        // No snapshot yet (cold start, never queried): trigger an
        // async fetch and re-enter once it lands. Keeps the UX
        // consistent — pressing --view=grid always either shows or
        // no-ops, never shows an empty grid.
        if lastWorkspaces.isEmpty {
            let bk = backend
            cliQueue.async {
                let wss = bk.workspaces()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.lastWorkspaces = wss
                        self?.showGrid()
                    }
                }
            }
            return
        }

        // -- Build overlay --
        let overlay = GridOverlay(
            contentRect: scr.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        overlay.isFloatingPanel = true
        overlay.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 2)   // above tree
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .fullScreenAuxiliary]

        // Solid near-black backdrop (no vibrancy). The slight
        // transparency keeps a hint of desktop visible during the
        // fade so it reads as "overlay opening" not "screen blanked."
        let host = NSView(frame: NSRect(origin: .zero,
                                        size: scr.frame.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(gridBackdropAlpha).cgColor

        let gv = GridView(frame: host.bounds)
        gv.autoresizingMask = [.width, .height]
        gv.workspaces = lastWorkspaces
        gv.activeIndex = lastWorkspaces.first(where: {
            $0.isActive
        })?.index
        gv.screenFrame = scr.frame
        gv.config = GridConfig(
            cols: config.effectiveGridCols,
            labelPosition: config.effectiveGridLabelPosition)
        gv.onDismiss = { [weak self] in self?.hideGrid() }
        gv.onDrop = { [weak self, bk = backend] src, dst, _, id in
            guard src != dst else { return }
            cliQueue.async {
                bk.moveWindow(id, toWorkspaceIndex: dst)
                let wss = bk.workspaces()
                let titles = AXTitles.resolve(wss)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(wss, titles)
                        self?.refreshGridThumbnails(
                            forWSIndices: [src, dst], in: wss)
                    }
                }
            }
        }
        gv.onSwap = { [weak self, bk = backend] src, dst, srcIDs, dstIDs in
            // Workspace-swap: trade contents of src ↔ dst. WM's
            // workspace index is left alone so each cell's grid
            // position (= user's bound hotkey) stays put — only
            // windows move. N+M moveWindow calls in sequence
            // off-main, then a single apply at the end so the grid
            // re-lays out in one pass.
            guard src != dst else { return }
            cliQueue.async {
                for id in srcIDs {
                    bk.moveWindow(id, toWorkspaceIndex: dst)
                }
                for id in dstIDs {
                    bk.moveWindow(id, toWorkspaceIndex: src)
                }
                let wss = bk.workspaces()
                let titles = AXTitles.resolve(wss)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(wss, titles)
                        self?.refreshGridThumbnails(
                            forWSIndices: [src, dst], in: wss)
                    }
                }
            }
        }
        gv.onPick = { [weak self, bk = backend] pick in
            // Dispatch the WM action off-main and dismiss in
            // parallel so the overlay clears immediately — the
            // workspace-switch animation lands as the overlay fades
            // out.
            switch pick {
            case .workspace(let ws):
                // Grid cell click without a specific window — let
                // the backend auto-focus the destination's
                // last-touched window (or activate Finder if empty).
                cliQueue.async {
                    bk.switchWorkspace(toIndex: ws, autoFocus: true)
                }
            case .window(let ws, let pid, let id):
                cliQueue.async {
                    bk.switchWorkspace(toIndex: ws)
                    // Re-assert until the WM's post-switch default
                    // focus settles on our pick. Title is empty —
                    // the grid doesn't surface titles, so focus
                    // falls back to serverID match.
                    let win = Window(
                        id: id, pid: pid, appName: "",
                        title: "", isFocused: false,
                        isFloating: false, frame: nil)
                    Focus.assert(win, backend: bk)
                }
            }
            self?.hideGrid()
        }
        host.addSubview(gv)
        overlay.contentView = host

        // -- Hide tree panel, remember pre-show state --
        treeWasHidden = userHidden
        if panelHost.isVisible { panelHost.hide() }

        // -- Present + fade in --
        overlay.alphaValue = 0
        overlay.makeKeyAndOrderFront(nil)
        gv.layoutCells()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = gridFadeIn
            overlay.animator().alphaValue = 1
        }

        // Initial keyboard selection: active workspace if visible,
        // else first cell.
        gv.kbSelectedWS = lastWorkspaces.first(where: {
            $0.isActive
        })?.index ?? lastWorkspaces.first?.index

        // -- Local key monitor for grid kb input --
        gridKbMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] e in
            guard let gv = self?.gridView else { return e }
            let shift = e.modifierFlags.contains(.shift)
            switch e.keyCode {
            case 53:  gv.kbEscape();                       return nil
            case 36, 76:
                gv.kbCommit();                             return nil
            case 49:
                // Space lifts the selection — a window (move) or the
                // header slot (whole-WS swap). Theme A: no Shift; Tab
                // moves between the header and the windows.
                gv.kbSpaceLift();                          return nil
            case 48:
                gv.kbCycleWindow(forward: !shift);         return nil
            case 123: gv.kbMoveSelection(dx: -1, dy: 0);   return nil
            case 124: gv.kbMoveSelection(dx:  1, dy: 0);   return nil
            case 126: gv.kbMoveSelection(dx: 0, dy: -1);   return nil
            case 125: gv.kbMoveSelection(dx: 0, dy:  1);   return nil
            default:  return e
            }
        }

        gridOverlay = overlay
        gridView = gv
        gridBackdrop = host
        // Screen-edge neon border for the overview + an entrance flash.
        applyBorderFromConfig()
        gv.flashBorder()

        // Kick off captures for every window in every workspace.
        // Each capture is async + independent — cells paint with
        // app icons first and progressively swap to real thumbnails
        // as captures land. Snapshot-on-show: no refresh during
        // display.
        if #available(macOS 14.0, *),
           let wp = winPreview as? WindowPreview {
            for ws in lastWorkspaces {
                for win in ws.windows {
                    let id = win.id
                    wp.request(id) { [weak self] img, _, gotID in
                        MainActor.assumeIsolated {
                            self?.gridView?.setThumbnail(img, for: gotID)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Active mode (--active keyboard navigation)
    //
    // `--show` stays passive (non-activating, never steals focus).
    // `--active` additionally makes the app/panel key so a plain
    // local NSEvent monitor receives ↑↓/Enter/Esc — no Input
    // Monitoring, no CGEventTap (those paths fail silently when
    // permissions are not granted, which is too easy a footgun).

    func enterActive() {
        Log.debug("enterActive")
        setHidden(false)                           // ensure visible
        // kbMonitor was already installed by setHidden(false) so
        // `s` works even in passive (--view=tree without --active)
        // when the panel has focus; enterActive only flips kbNav on
        // to unlock the full nav set (↑↓/Enter/Esc/etc).
        prevApp = NSWorkspace.shared.frontmostApplication
        // A .accessory + .nonactivatingPanel app can't reliably
        // become key, so the local keyDown monitor wouldn't fire
        // and keys leaked to the window behind. Become a regular
        // app for the duration of keyboard mode so we actually
        // take key focus; revert on exit.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panelHost.makeKey()
        sidebarView.enterKbNav()
    }

    func _exitActiveImpl(restore: Bool) {
        Log.debug("exitActive restore=\(restore) wasKbNav=\(sidebarView.kbNav)")
        // Don't remove kbMonitor here — passive `s` opens search after
        // the panel is clicked, which we want to keep. The monitor's
        // own `panel.isKeyWindow` guard means it's idempotent /
        // harmless while the panel isn't focused.
        guard sidebarView.kbNav else { return }
        sidebarView.exitKbNav()                    // also clears `searching`
        panelHost.resignKey()
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
        NSApp.setActivationPolicy(.accessory)      // back to LSUIElement
        if restore, let p = prevApp { p.activate() }
        prevApp = nil
    }

    /// Returns true if the key was consumed (swallowed so it doesn't
    /// beep or fall through to whatever is behind the panel).
    private func handleKbKey(_ e: NSEvent) -> Bool {
        // Only intercept keys when our panel actually has focus.
        // Without this, the local monitor would catch keys while
        // a different window is key and silently swallow them.
        guard panelHost.panel.isKeyWindow else { return false }

        let ctrl = e.modifierFlags.contains(.control)
        let shift = e.modifierFlags.contains(.shift)

        // A Space-opened context menu is up: let its own monitor
        // handle keys (Esc closes, mouse picks). Don't run nav /
        // exit-active here.
        if PopupMenu.shared.isOpen { return false }

        // -- Type-to-filter sub-mode --
        // Nav/commit keys consumed here; everything else returns
        // false so the event reaches the NSTextField (text + IME
        // work natively).
        if sidebarView.searching {
            // While the IME has uncommitted text, intercept nothing:
            // Enter commits the conversion, arrows move candidates,
            // Esc cancels — all must reach the input.
            if panelHost.searchBar.isComposing { return false }
            switch e.keyCode {
            case 53:                                            // Esc
                if panelHost.searchBar.stringValue.isEmpty {
                    exitSearch()
                } else {
                    panelHost.searchBar.stringValue = ""
                    sidebarView.setQuery("")
                }
                return true
            case 36, 76:  sidebarView.kbActivate();      return true
            case 125:     sidebarView.kbMove(1);         return true
            case 126:     sidebarView.kbMove(-1);        return true
            case 48:      sidebarView.kbMove(shift ? -1 : 1)
                          return true
            default:      break
            }
            if ctrl, e.charactersIgnoringModifiers?.lowercased() == "n" {
                sidebarView.kbMove(1);  return true
            }
            if ctrl, e.charactersIgnoringModifiers?.lowercased() == "p" {
                sidebarView.kbMove(-1); return true
            }
            return false           // → NSTextField (typing, IME, ⌫)
        }

        // panel.isKeyWindow already implies kbNav was enabled by the
        // didBecomeKey hook below — fall through to the full nav.

        // -- Normal keyboard nav --
        // Theme A keyboard DnD: Space lifts the selected row (window
        // = move, header = WS-swap); while lifted the arrow keys aim
        // the drop target (kbMove/kbJumpWS redirect internally),
        // Return/Space commits, Esc cancels the lift before exiting.
        switch e.keyCode {
        case 53:      if sidebarView.kbCancelLift() { return true }
                      _exitActiveImpl(restore: true);    return true
        case 36, 76:  if sidebarView.kbCommitLift() { return true }
                      sidebarView.kbActivate();          return true
        case 125:     sidebarView.kbMove(1);             return true
        case 126:     sidebarView.kbMove(-1);            return true
        case 124:     sidebarView.kbJumpWS(1);           return true
        case 123:     sidebarView.kbJumpWS(-1);          return true
        case 48:      sidebarView.kbJumpWS(shift ? -1 : 1)
                      return true
        case 49:      sidebarView.kbToggleLift();         return true
        default:      break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "n" where ctrl: sidebarView.kbMove(1);      return true
        case "p" where ctrl: sidebarView.kbMove(-1);     return true
        case "j":            sidebarView.kbMove(1);      return true
        case "k":            sidebarView.kbMove(-1);     return true
        case "l":            sidebarView.kbJumpWS(1);    return true
        case "h":            sidebarView.kbJumpWS(-1);   return true
        case "m":            sidebarView.kbContextMenu(); return true
        case "s":            enterSearch();              return true
        default:             return false
        }
    }

    private func enterSearch() {
        sidebarView.beginSearch()
        panelHost.searchBar.stringValue = ""
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
        // IME input goes to the field.
        panelHost.panel.makeFirstResponder(panelHost.searchBar.field)
    }

    private func exitSearch() {
        sidebarView.endSearch()
        panelHost.resignKey()
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
    }

    /// Dismiss the grid overlay. `immediate` tears it down
    /// synchronously (no fade): used when switching to another view,
    /// where the grid must be gone *this turn* — both so it doesn't
    /// ride a mac-desktop slide (the `--view=tree` chord binding
    /// fires right before the switch) and so `isGridVisible` is false
    /// by the time the caller's `showLoading` / panel logic runs. The
    /// caller owns what shows next, so the immediate path skips the
    /// tree-restore refresh.
    func hideGrid(immediate: Bool = false) {
        Log.debug("hideGrid\(immediate ? " (immediate)" : "")")
        guard let overlay = gridOverlay else { return }
        if let m = gridKbMonitor {
            NSEvent.removeMonitor(m); gridKbMonitor = nil
        }
        gridView?.clearThumbnails()
        gridView?.stopBorder()        // no orphaned border timer
        let restoreTree = !treeWasHidden
        if immediate {
            overlay.orderOut(nil)
            gridOverlay = nil; gridView = nil; gridBackdrop = nil
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = gridFadeOut
            overlay.animator().alphaValue = 0
        }) { [weak self] in
            guard let self else { return }
            overlay.orderOut(nil)
            self.gridOverlay = nil
            self.gridView = nil
            self.gridBackdrop = nil
            if restoreTree { self.refresh() }       // re-shows the panel
        }
    }

    // MARK: - Rail lifecycle

    func toggleRail() {
        if isRailVisible { hideRail() } else { showRail() }
    }

    func showRail(edge: RailEdge? = nil) {
        let edge = edge ?? config.effectiveRailEdge
        Log.debug("showRail request (isVisible=\(isRailVisible) edge=\(edge.rawValue))")
        if isRailVisible { return }
        guard let scr = NSScreen.main else { return }
        // No snapshot yet (cold start): fetch then re-enter so the rail
        // never paints empty. Bail if the fetch comes back empty (e.g.
        // an unmanaged mac desktop under opt-in `[desktop.N]` config) so
        // we don't spin re-fetching forever.
        if lastWorkspaces.isEmpty {
            let bk = backend
            cliQueue.async {
                let wss = bk.workspaces()
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.lastWorkspaces = wss
                        if wss.isEmpty { return }   // nothing to show
                        self.showRail(edge: edge)   // forward the requested edge
                    }
                }
            }
            return
        }

        // Full-screen takeover: a near-black backdrop hides the desktop,
        // the active workspace shows large in the centre, every
        // workspace lines the bottom as a small mini-screen.
        let overlay = RailOverlay(
            contentRect: scr.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        overlay.isFloatingPanel = true
        overlay.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 2)   // above tree
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                      .fullScreenAuxiliary]

        let rv = RailView(frame: NSRect(origin: .zero, size: scr.frame.size))
        rv.autoresizingMask = [.width, .height]
        rv.screenFrame = scr.frame
        rv.edge = edge                              // M9-3: docked edge
        rv.cellsTarget = config.effectiveRailCells  // upper bound on visible cells
        rv.stripPercent = config.effectiveRailStrip // strip band size (% short edge)
        rv.workspaces = lastWorkspaces
        rv.activeIndex = lastWorkspaces.first(where: { $0.isActive })?.index
        rv.selectedWS = rv.activeIndex      // browse cursor starts on the active WS
        rv.onPick = { [weak self] ws in
            guard let self else { return }
            // Commit-on-click (grid-like): dispatch the switch off-main
            // and dismiss in parallel so the overlay clears immediately;
            // the workspace-switch lands as it fades out. autoFocus lets
            // the backend focus the destination's last-touched window.
            cliQueue.async {
                self.backend.switchWorkspace(toIndex: ws, autoFocus: true)
            }
            self.hideRail()
        }
        rv.onDismiss = { [weak self] in self?.hideRail() }
        // Click a specific window thumbnail → switch to its WS AND focus
        // THAT window (grid parity). Unlike onPick (which uses
        // autoFocus = the WS's last-touched window), this omits
        // autoFocus then Focus.asserts the picked window. Dispatch
        // off-main + dismiss in parallel, like the grid's onPick.window.
        rv.onPickWindow = { [weak self, bk = backend] ws, pid, id in
            guard let self else { return }
            cliQueue.async {
                bk.switchWorkspace(toIndex: ws)
                let win = Window(id: id, pid: pid, appName: "",
                                 title: "", isFocused: false,
                                 isFloating: false, frame: nil)
                Focus.assert(win, backend: bk)
            }
            self.hideRail()
        }
        // Drag a window onto another WS cell → move it there. The
        // overlay STAYS OPEN (no hideRail) so the user sees the result.
        // Reuses the grid's onDrop body shape.
        rv.onMoveWindow = { [weak self, bk = backend] src, dst, _, id in
            guard src != dst else { return }
            cliQueue.async {
                bk.moveWindow(id, toWorkspaceIndex: dst)
                let wss = bk.workspaces()
                let titles = AXTitles.resolve(wss)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(wss, titles)
                        self?.refreshRailThumbnails(forWSIndices: [src, dst], in: wss)
                    }
                }
            }
        }
        // Drag a header onto another cell → swap the two WS' contents
        // (N+M moveWindow calls; the WM indices stay put).
        rv.onSwap = { [weak self, bk = backend] src, dst, srcIDs, dstIDs in
            guard src != dst else { return }
            cliQueue.async {
                for id in srcIDs { bk.moveWindow(id, toWorkspaceIndex: dst) }
                for id in dstIDs { bk.moveWindow(id, toWorkspaceIndex: src) }
                let wss = bk.workspaces()
                let titles = AXTitles.resolve(wss)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(wss, titles)
                        self?.refreshRailThumbnails(forWSIndices: [src, dst], in: wss)
                    }
                }
            }
        }
        overlay.contentView = rv

        // Hide the tree panel while the rail is up (it would otherwise
        // sit behind the backdrop); restore on dismiss like the grid.
        treeWasHidden = userHidden
        if panelHost.isVisible { panelHost.hide() }

        overlay.alphaValue = 0
        overlay.makeKeyAndOrderFront(nil)
        rv.layoutCells()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = gridFadeIn
            overlay.animator().alphaValue = 1
        }

        // Keyboard: browse along the strip's axis (←/→ for a top/bottom
        // rail, ↑/↓ for left/right), Return commits, Esc dismisses (the
        // overlay is key, so a local monitor fires). The cross-axis
        // arrows pass through (inert) so they don't fight the browse.
        railKbMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] e in
            guard let rv = self?.railView else { return e }
            let shift = e.modifierFlags.contains(.shift)
            let horizontal = rv.edge.axis == .horizontal
            switch e.keyCode {
            case 53:     rv.kbEscape();                     return nil  // Esc → cancel/close
            case 36, 76: rv.kbCommit();                     return nil  // Return → commit
            case 49:     rv.kbSpaceLift();                  return nil  // Space → lift
            case 48:     rv.kbCycleWindow(forward: !shift); return nil  // Tab / Shift-Tab
            case 123 where horizontal: rv.kbMoveSelection(dx: -1); return nil  // ← prev
            case 124 where horizontal: rv.kbMoveSelection(dx:  1); return nil  // → next
            case 126 where !horizontal: rv.kbMoveSelection(dx: -1); return nil  // ↑ prev
            case 125 where !horizontal: rv.kbMoveSelection(dx:  1); return nil  // ↓ next
            default:     return e
            }
        }

        // Scroll-wheel browse (⑦): a monitor (not a view override) so it
        // fires for the nonactivating panel — scroll DOWN = next, UP =
        // previous, on every edge. Consumed so it never leaks to the app
        // behind the overlay.
        railScrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] e in
            guard let rv = self?.railView else { return e }
            rv.scrollRotate(e)
            return nil
        }

        railOverlay = overlay
        railView = rv
        // Neon border framing the strip band + an entrance flash.
        applyBorderFromConfig()
        rv.flashBorder()

        // Request every window in every workspace from the shared
        // `winPreview`, which the Controller's thumbnail timer keeps
        // warm in the background — so on open the cells paint real
        // thumbnails from the cache immediately (no app-icon flash).
        // The rail is a full-screen modal that HIDES the tree, so the
        // tree's `bump()` can't cancel these in-flight captures while
        // it's up (no separate instance needed). Snapshot-on-show.
        if #available(macOS 14.0, *), let wp = winPreview as? WindowPreview {
            for ws in lastWorkspaces {
                for win in ws.windows {
                    let id = win.id
                    wp.request(id) { [weak self] img, _, gotID in
                        MainActor.assumeIsolated {
                            self?.railView?.setThumbnail(img, for: gotID)
                        }
                    }
                }
            }
        }
    }

    func hideRail() {
        Log.debug("hideRail")
        guard let overlay = railOverlay else { return }
        if let m = railKbMonitor {
            NSEvent.removeMonitor(m); railKbMonitor = nil
        }
        if let m = railScrollMonitor {
            NSEvent.removeMonitor(m); railScrollMonitor = nil
        }
        railView?.clearDrag()        // explicit cancel if a drag is mid-flight
        railView?.clearThumbnails()
        railView?.stopBorder()       // no orphaned border timer
        // Flip `isRailVisible` synchronously so a quick hide→show within
        // the fade window builds a fresh overlay instead of no-op'ing.
        let restoreTree = !treeWasHidden
        railOverlay = nil
        railView = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = gridFadeOut
            overlay.animator().alphaValue = 0
        }) { [weak self] in
            overlay.orderOut(nil)
            if restoreTree { self?.refresh() }   // re-shows the tree panel
        }
    }

    // MARK: - Visibility

    func setHidden(_ hide: Bool) {
        Log.debug("setHidden hide=\(hide)")
        userHidden = hide
        if hide {
            _exitActiveImpl(restore: false)
            previewTimer?.invalidate(); previewPool.hideAll()
            panelHost.hide()
            removeKbMonitor()
        } else {
            installKbMonitor()
            refresh()
        }
    }

    private func installKbMonitor() {
        guard kbMonitor == nil else { return }
        kbMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown
        ) { [weak self] e in
            guard let self else { return e }
            return self.handleKbKey(e) ? nil : e
        }
    }

    private func removeKbMonitor() {
        if let m = kbMonitor {
            NSEvent.removeMonitor(m); kbMonitor = nil
        }
    }
}

// MARK: - TreeController conformance

extension Controller: TreeController {

    // -- Panel mechanics → delegate to PanelHost

    func movePanel(by delta: CGSize) {
        panelHost.movePanel(by: delta)
    }

    /// Header double-click: reset the panel to its `[tree]` config
    /// geometry, or the built-in default when none is configured.
    func resetPanelGeometry() {
        if let g = config.effectiveTreeGeometry {
            panelHost.setExplicitFrame(g)
        } else {
            panelHost.resetGeometryToDefault()
        }
    }

    // -- Refresh

    func scheduleReconcile(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // -- Focus

    func focusWindow(_ window: Window, postSwitch: Bool) {
        Log.debug("focusWindow id=\(window.id.serverID) "
            + "pid=\(window.pid) postSwitch=\(postSwitch)")
        cliQueue.async { [bk = backend] in
            if postSwitch {
                Focus.assert(window, backend: bk)
            } else {
                Focus.withRetry(window)
            }
        }
    }

    func runWindowOps(_ ops: [WindowAction],
                      on window: Window,
                      workspaceIndex ws: Int) {
        // Switch to the target workspace if needed, focus, give the
        // WM ~140 ms to register, then run the ops in sequence with
        // ~120 ms between them so each one's effect is visible
        // before the next lands.
        let needSwitch = (ws != lastWorkspaces.first(where: {
            $0.isActive
        })?.index)
        let bk = backend
        cliQueue.async {
            if needSwitch { bk.switchWorkspace(toIndex: ws) }
            _ = AX.focus(window)
            usleep(140_000)
            for a in ops { bk.perform(a); usleep(120_000) }
        }
    }

    // -- Stubs for follow-up steps

    func previewTargetChanged() {
        _previewTargetChangedImpl()
    }

    func exitActive(restore: Bool) {
        _exitActiveImpl(restore: restore)
    }
}
