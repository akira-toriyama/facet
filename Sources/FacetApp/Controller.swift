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
    var config: FacetConfig
    private let configPath: String
    private var configWatcher: ConfigWatcher?
    let panelHost: PanelHost
    let sidebarView: SidebarView

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
    /// (Setter is internal — the grid / rail cold-start fetch in
    /// Controller+Grid.swift / Controller+Rail.swift re-seeds it.)
    var lastWorkspaces: [Workspace] = []
    /// Active-WS index at the previous ``apply`` — lets the
    /// event-driven preview refresh spot a workspace switch (the
    /// snapshot frame is switch-stable by design, so an index change is
    /// the only reliable signal that windows were parked / unparked).
    private var prevActiveWSIndex: Int?
    var userHidden = false
    // MARK: - Per-surface palettes (PR-B)

    /// Each painted surface owns its resolved palette, driven by the
    /// config keys `[tree]/[grid]/[rail].theme` (`""` / unset = inherit
    /// `[theme]`). The box is the shared, mutable handle so that surface's
    /// whole chrome reads one palette and updates together on a re-theme
    /// (hot-reload, `--theme`) or a 30 Hz animator tick.
    let treePaletteBox = PaletteBox(resolve(.terminal))
    let gridPaletteBox = PaletteBox(resolve(.terminal))
    let railPaletteBox = PaletteBox(resolve(.terminal))
    /// Concrete theme name per surface — `random` is resolved to a real
    /// theme ONCE per config load (not per frame); drives the animator.
    var treeThemeName = "terminal"
    var gridThemeName = "terminal"
    var railThemeName = "terminal"
    /// The pre-random-roll SOURCE each surface last resolved from (the
    /// `--theme` override, or its per-view effective theme). A hot-reload
    /// re-resolves only the surfaces whose source changed, so saving an
    /// unrelated key never re-rolls a `random` surface or snaps a running
    /// color-cycle back to phase 0.
    var treeSource = ""
    var gridSource = ""
    var railSource = ""
    /// Active `facet --theme` session override (nil = follow config).
    /// Persists across hot-reloads until the user edits a theme key (then
    /// config wins) or issues another `--theme`.
    var themeOverride: String?
    private var themeFXTimer: Timer?
    /// Per-surface theme-cycle phase (0…1). Only animatable surfaces
    /// (rainbow / chomp + `[theme].color-cycle-ms`) advance theirs.
    var treeFXPhase: CGFloat = 0
    var gridFXPhase: CGFloat = 0
    var railFXPhase: CGFloat = 0
    /// Whether `[tree] line-pets` is active (after typo validation). The
    /// theme-FX timer keeps running while this is true so the tree can
    /// animate its pets even on a non-cycling theme.
    private var petsActive = false

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
    /// `--view tree --loading MS` skeleton hold timer (see
    /// `showLoading` in Controller+CLIDispatch.swift). Lives here —
    /// extensions can't hold stored properties.
    var loadingTimer: Timer?

    // MARK: - Preview (hover overlay + grid thumbnails)

    let previewPool = PreviewOverlayPool()
    /// Held as ``Any`` so the class compiles on macOS 13 (the
    /// ``WindowPreview`` type is gated on macOS 14+). Cast at use
    /// site.
    var winPreview: Any?
    var previewTimer: Timer?
    var thumbnailTimer: Timer?
    var thumbnailTimerInterval: TimeInterval?

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
    /// flag gates one neighbour-write at a time (self-regulating the
    /// cadence to the apply rate). See `liveDragTick` /
    /// `resolveLiveDragEnd` (RealWindowDrag.swift).
    var liveGestureIsResize = false
    var liveResizeLastFrame: CGRect?
    var liveResizeInFlight = false
    /// Was the PREVIOUS tick classified as a resize? A drag is only
    /// latched to resize once TWO consecutive ticks see the size changed,
    /// so a single-frame OS size blip during a title-bar move (display
    /// clamp / app self-resize) can't latch resize or write a stray ratio.
    /// The in-flight gate serialises ticks, so this reads consistently.
    var liveResizePrevResized = false

    // MARK: - Grid overview

    var gridOverlay: GridOverlay?
    var gridView: GridView?
    var gridBackdrop: NSView?
    var gridKbMonitor: Any?
    /// Remembered while the grid is up so we can restore exactly the
    /// pre-show visibility state on dismiss.
    var treeWasHidden = false
    var isGridVisible: Bool { gridOverlay != nil }

    // MARK: - Workspace rail (bottom overview bar)

    var railOverlay: RailOverlay?
    var railView: RailView?
    /// Local key monitor for the rail's Escape-to-dismiss while it's up.
    var railKbMonitor: Any?
    /// Local scroll-wheel monitor (⑦) — rotates the carousel while the
    /// rail is up. A monitor (not an NSView override) so it fires for the
    /// nonactivating panel, exactly like `railKbMonitor`.
    var railScrollMonitor: Any?
    var isRailVisible: Bool { railOverlay != nil }

    // MARK: - Active mode (kb-nav)

    private var kbMonitor: Any?
    /// Frontmost app at the moment ``enterActive`` was called, so
    /// ``exitActive(restore: true)`` can hand focus back.
    var prevApp: NSRunningApplication?
    private let searchDelegate = SearchFieldDelegate()
    /// Target window of an in-progress GUI tag-input (#191 PR-7), or nil
    /// when the tag-input box isn't open. Set by `beginTagInput`; the
    /// search field's text is committed to this window on Return.
    var tagInputTarget: WindowID?
    /// Whether `beginTagInput` itself entered `--active` (the panel was
    /// passive — right-click path) vs. found it already active (the `m`
    /// path). Drives teardown: only the former fully exits `--active` (and
    /// reverts the `.regular` activation policy); the latter stays in the
    /// keyboard-nav session the user came from.
    var tagInputEnteredActive = false

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
        self.panelHost = PanelHost(view: view, paletteBox: treePaletteBox)
        super.init()
        view.controller = self
        // PR-B: each surface's chrome shares its box. Tree chrome is wired
        // inside PanelHost.init; the Controller-owned tree overlays get the
        // tree box here. Grid / rail views get their boxes at build time.
        dndOverlay.paletteBox = treePaletteBox
        previewPool.paletteBox = treePaletteBox
        panelHost.handleBar.onResetGeometry = { [weak self] in
            self?.resetPanelGeometry()
        }
        if #available(macOS 14.0, *) { winPreview = WindowPreview() }
        searchDelegate.onChange = { [weak self] q in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Tag-input sub-mode (#191 PR-7) reuses the same field but
                // must NOT filter the list — the text is committed on Return.
                guard self.tagInputTarget == nil else { return }
                self.sidebarView.setQuery(q)
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
        resolveSurfacePalettes()      // PR-B: seed all three boxes from config
        // PanelHost.init painted its bg / border / vibrancy layers from the
        // box's terminal seed; re-apply now that the tree box holds the
        // configured theme so the first frame is correct.
        panelHost.applyTheme()
        updateThemeAnimator()
        seedTreeGeometry()
        applyPetsFromConfig()
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
    func applyBorderFromConfig() {
        let e = config.effectiveBorderEffect
        let g = config.effectiveBorderGlow
        let w = config.effectiveBorderWidth
        let cs = config.effectiveBorderCycleSeconds
        // Explicitly setting `[border] cycle-seconds` also opts a
        // non-rainbow effect into a continuous color cycle (⑧).
        let cc = config.borderColorCycleMs != nil
        let mn = config.effectiveBorderMinWidth
        let mx = config.effectiveBorderMaxWidth
        panelHost.applyBorder(effectName: e, glow: g, width: w,
                              cycleSeconds: cs, cycleColors: cc, minWidth: mn, maxWidth: mx)
        // The grid + rail borders (when their overlay is up) —
        // reconfigure on a hot-reload too.
        gridView?.applyBorder(effectName: e, glow: g, width: w,
                              cycleSeconds: cs, cycleColors: cc, minWidth: mn, maxWidth: mx)
        railView?.applyBorder(effectName: e, glow: g, width: w,
                              cycleSeconds: cs, cycleColors: cc, minWidth: mn, maxWidth: mx)
    }

    private func handlePanelKeyChange(isKey: Bool) {
        if isKey {
            if !sidebarView.kbNav { sidebarView.enterKbNav() }
        } else {
            // Drop kbNav. If we got here via --active's
            // _exitActiveImpl path, exitKbNav has already run and
            // this is a harmless idempotent call.
            if sidebarView.kbNav { sidebarView.exitKbNav() }
            // Abandon an open tag-input box (#191 PR-7) if focus left the
            // panel externally — otherwise its stale target would catch
            // the next key when the panel regains key. The normal
            // commit/cancel path clears `tagInputTarget` before resigning,
            // so this only fires on an external focus loss.
            if tagInputTarget != nil { abandonTagInput() }
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
        // Adapter error stream → lastError slot in facet query.
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
        writeStatus([])     // touch the file so `facet query` works
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
        // PR-B: snapshot the per-view effective themes so we can tell a
        // deliberate theme edit (→ a live `--theme` override yields to
        // config) from an unrelated save (→ the override survives).
        let oldThemes = [config.effectiveTreeTheme,
                         config.effectiveGridTheme,
                         config.effectiveRailTheme]
        config = fresh
        logConfigWarnings()
        applyBorderFromConfig()
        seedTreeGeometry()
        applyPetsFromConfig()
        let newTheme = config.effectiveTheme
        let newPrev = config.effectiveTreePreviewMode
        Log.debug("reloadConfig: theme=\(oldTheme)→\(newTheme) "
            + "preview-mode=\(oldPrev)→\(newPrev)")
        // PR-B: re-resolve all three surface palettes. resolveSurfacePalettes
        // re-rolls only the surfaces whose source changed, so an unrelated
        // save won't jump a running color-cycle. A theme-key edit drops any
        // live `--theme` override (config becomes source of truth again).
        let newThemes = [config.effectiveTreeTheme,
                         config.effectiveGridTheme,
                         config.effectiveRailTheme]
        if themeOverride != nil, newThemes != oldThemes { themeOverride = nil }
        applyThemesFromConfig()
        // Always refresh the snapshot — [workspaces] changes need
        // to surface in `facet query` without waiting for the
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

    // MARK: - Per-surface palette resolution (PR-B)

    /// Resolve all three surface palettes into their boxes. Called at
    /// startup + on hot-reload + after a `--theme` override (via
    /// `applyStyle`). Honors the active `themeOverride` (forces every
    /// surface) else the per-view `[tree]/[grid]/[rail].theme` keys.
    ///
    /// `random` semantics: an APP-WIDE random — a single `--theme random`,
    /// or an inherited `[theme].name = random` — rolls ONE concrete theme
    /// shared by every surface that inherits it (matches the pre-PR-B
    /// single-`pal` behavior). A surface whose OWN key is literally
    /// `theme = "random"` rolls its own. Rolled ONCE per load.
    ///
    /// Each surface only re-resolves when its SOURCE (override / per-view
    /// effective theme) actually changed, so an unrelated config save
    /// neither re-rolls a `random` surface nor restarts a running cycle.
    func resolveSurfacePalettes() {
        let override = themeOverride
        var appRandom: String?
        func sharedRandom() -> String {
            if appRandom == nil { appRandom = randomConcreteTheme() }
            return appRandom!
        }
        func apply(effective: String, rawKey: String?,
                   source: inout String, name: inout String,
                   phase: inout CGFloat, box: PaletteBox) {
            let src = override ?? effective
            // Reload fast-path: an unchanged source keeps the surface's
            // current concrete theme (no random re-roll) AND its cycle
            // phase. The override path always re-resolves so a re-issued
            // `--theme` (incl. a fresh `--theme random` roll) still lands.
            if override == nil, src == source { return }
            let concrete: String
            if src == "random" {
                let ownRandom = override == nil
                    && rawKey?.trimmingCharacters(in: .whitespaces)
                        .lowercased() == "random"
                concrete = ownRandom ? randomConcreteTheme() : sharedRandom()
            } else {
                concrete = src
            }
            if concrete != name { phase = 0 }   // restart cycle only on a real change
            source = src
            name = concrete
            box.pal = resolve(paletteFor(concrete))
        }
        apply(effective: config.effectiveTreeTheme, rawKey: config.treeTheme,
              source: &treeSource, name: &treeThemeName,
              phase: &treeFXPhase, box: treePaletteBox)
        apply(effective: config.effectiveGridTheme, rawKey: config.gridTheme,
              source: &gridSource, name: &gridThemeName,
              phase: &gridFXPhase, box: gridPaletteBox)
        apply(effective: config.effectiveRailTheme, rawKey: config.railTheme,
              source: &railSource, name: &railThemeName,
              phase: &railFXPhase, box: railPaletteBox)
    }

    /// One concrete theme for a `random` surface — the same pool
    /// `paletteFor("random")` draws from (every catalog theme but
    /// `system`), picked once at load so the surface holds steady.
    func randomConcreteTheme() -> String {
        canonicalThemeNames
            .filter { $0 != "random" && $0 != "system" }
            .randomElement() ?? "terminal"
    }

    /// Re-theme every surface + chrome and re-gate the animator. Shared by
    /// the live `--theme` override (`applyStyle`) and the hot-reload path.
    func reapplyThemes() {
        panelHost.applyTheme()
        sidebarView.needsDisplay = true
        gridView?.needsDisplay = true
        railView?.needsDisplay = true
        updateThemeAnimator()
    }

    /// Re-resolve every surface's palette from fresh config (hot-reload).
    /// Honors a live `--theme` override if still active (the caller clears
    /// it when a theme key changed); otherwise follows the per-view keys.
    func applyThemesFromConfig() {
        resolveSurfacePalettes()
        reapplyThemes()
    }

    // MARK: - Theme color animator (⑪)

    /// Is `name` a color-cycling theme with cycling switched on?
    /// (rainbow / chomp + `[theme].color-cycle-ms`.) "Animatable" is
    /// DERIVED from sill's effect catalog (`isAnimatableTheme`), the single
    /// source of truth in `Effects`. `name` is always a CONCRETE theme here
    /// (`random` is resolved once at load), so a random-rolled rainbow /
    /// chomp animates cleanly — no per-tick re-pick, no flicker.
    private func surfaceIsCycling(_ name: String) -> Bool {
        isAnimatableTheme(name) && config.themeColorCycleMs != nil
    }

    /// Any surface needs the cycle clock running.
    private var anySurfaceCycling: Bool {
        surfaceIsCycling(treeThemeName)
            || surfaceIsCycling(gridThemeName)
            || surfaceIsCycling(railThemeName)
    }

    func updateThemeAnimator() {
        // The one 30 Hz timer drives two independent animations: the
        // per-surface theme color cycle AND the tree line-pets. Run it
        // while EITHER is live so pets keep orbiting even on a static theme.
        let on = anySurfaceCycling || petsActive
        if on, themeFXTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickThemeFX() }
            }
            RunLoop.main.add(t, forMode: .common)
            themeFXTimer = t
        } else if !on {
            themeFXTimer?.invalidate(); themeFXTimer = nil
        }
    }

    /// Advance one surface's cycle phase and fold sill's live accents onto
    /// its steady base. Returns true if the surface was repainted.
    private func tickSurfaceCycle(name: String, phase: inout CGFloat,
                                  box: PaletteBox) -> Bool {
        guard surfaceIsCycling(name) else { return false }
        phase += (1.0 / 30.0) / config.effectiveThemeCycleSeconds
        if phase >= 1 { phase -= 1 }
        // `animatedPalette` returns only the live primary / secondary /
        // selection; fold them onto the steady resolved base so background
        // / foreground / muted / border hold and the UI stays usable.
        guard let f = animatedPalette(theme: name, at: phase) else { return false }
        let base = resolve(paletteFor(name))
        box.pal = ResolvedPalette(
            background: base.background, foreground: base.foreground,
            muted: base.muted, tertiary: base.tertiary,
            primary: f.primary, secondary: f.secondary,
            border: base.border, hover: base.hover,
            selection: f.selection, error: base.error, font: base.font,
            backgroundAlpha: base.backgroundAlpha,
            vibrancyMaterial: base.vibrancyMaterial,
            forceDarkAqua: base.forceDarkAqua)
        return true
    }

    private func tickThemeFX() {
        // Per-surface theme color cycle. Each animatable surface advances
        // its own phase + box; non-cycling surfaces hold their steady
        // palette. Repaint only the surfaces that changed.
        if tickSurfaceCycle(name: treeThemeName, phase: &treeFXPhase,
                            box: treePaletteBox) {
            panelHost.applyTheme()
            sidebarView.needsDisplay = true
        }
        if tickSurfaceCycle(name: gridThemeName, phase: &gridFXPhase,
                            box: gridPaletteBox) {
            gridView?.needsDisplay = true
        }
        if tickSurfaceCycle(name: railThemeName, phase: &railFXPhase,
                            box: railPaletteBox) {
            railView?.needsDisplay = true
        }
        // Line-pets ride a panel-level overlay (above the border); repaint
        // it every tick so they keep orbiting even on a static theme.
        if petsActive { panelHost.redrawPets() }
    }

    /// Push `[tree] line-pets` onto the panel overlay + (re)gate the FX
    /// timer. Called at startup + on hot-reload, mirroring
    /// `applyBorderFromConfig`.
    private func applyPetsFromConfig() {
        panelHost.setPets(names: config.effectiveTreeLinePets,
                          scale: config.effectiveTreePetScale,
                          lapSeconds: config.effectiveTreePetLapSeconds)
        // `hasPets` reflects post-validation names (typos dropped), so a
        // config of only-typos correctly parks the timer.
        petsActive = panelHost.hasPets
        updateThemeAnimator()
        panelHost.redrawPets()
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

    func refresh() {
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

    func apply(_ wss: [Workspace],
               _ titles: [WindowID: String] = [:]) {
        // First non-empty snapshot? Warm the thumbnail cache one-shot
        // so the very first `--view grid` (especially right after
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
                                          macDesktop: macDesktopOrdinal,
                                          tagMode: config.effectiveGrouping == .tag)
        panelHost.layout(contentHeight: contentH,
                         searching: sidebarView.searching)
        if !panelHost.isVisible { panelHost.show() }
        writeStatus(wss)
    }

    /// Snapshot the current workspace state to
    /// `/tmp/facet-status.json` so `facet query` (client mode)
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
    /// and therefore `facet query` — surfaces it. Single-slot
    /// (newest overwrites): the status file shows the most recent
    /// thing that went wrong, not a history. Re-snapshots
    /// immediately so the file reflects the new error without
    /// waiting for the next reconcile.
    ///
    /// Call sites are intentionally narrow today (dispatch
    /// out-of-range only). Broaden later — AX focus failure,
    /// backend command failure, etc. — as the seam proves out.
    func setError(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        lastError = "\(message) at \(ts)"
        Log.line("error: \(lastError ?? "")")
        writeStatus(lastWorkspaces)
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

    func syncPanelAfterDrag() {
        panelHost.syncPanelAfterDrag()
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
