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
//   - keyboard-nav + search
//   - distributed-notification CLI IPC
//
// Conforms to ``TreeController`` so ``SidebarView`` can talk to it
// without knowing about any of the above.

import AppKit
import FacetCore
import FacetAccessibility
import FacetCapture
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
    /// EX-2: last projected sections + active lens, refreshed every
    /// ``apply`` (hoisted above the grid/rail feed) and fed to the overview
    /// surfaces — the same ordered `[ProjectedSection]` the tree renders, so
    /// all three views agree. Empty/nil ⇒ section model off here ⇒ the
    /// overview degrades to `lastWorkspaces`. Snapshot-on-show seeds from these.
    var lastSections: [ProjectedSection] = []
    /// §A: the active lens's stable section id (`ProjectedSection.id`), fed to
    /// all three views as the single-highlight key. Keyed on the id, not the
    /// display label, so a non-unique / empty lens label can't light the wrong
    /// cell. Display labels still come from each cell's own `label`.
    var lastActiveLensID: String?
    /// Session-only, per-mac-desktop DISPLAY-ORDER override for the section
    /// list (the drag-to-reorder feature). Keyed by mac-desktop ordinal
    /// (`currentMacDesktopOrdinal() ?? -1`), value = ordered stable section
    /// ids (`"ws:<index>"` / `"section:<declOrder>:<label>"`). Applied to the
    /// PROJECTED result in `apply()` via `SectionOrder` so tree/grid/rail all
    /// reflect it; NEVER written to disk (config.toml stays read-only) and
    /// NEVER touches the backend (display-only — windows don't move). A
    /// relaunch resets to config order. See `SectionOrder` for the why
    /// (reorder the OUTPUT, not the input `[DesktopSection]`).
    var macDesktopSectionOrder: [Int: [String]] = [:]
    /// §E: session-only DISPLAY-LABEL override for `type="lens"` sections.
    /// Keyed by mac-desktop ordinal (`currentMacDesktopOrdinal() ?? -1`),
    /// then by the section's stable id (`"section:<declOrder>:<label>"`),
    /// value = the new display label. Applied to the PROJECTED result at the
    /// single seam in `apply()` (via `applyLabelOverrides`), so tree/grid/rail
    /// all reflect it; NEVER written to disk (config.toml stays read-only) and
    /// NEVER touches the backend (display-only — windows / ids don't move).
    /// Same lifetime as `macDesktopSectionOrder`: per-mac-desktop, non-
    /// persisted, a relaunch resets to config order. Keyed on the FULL stable
    /// id (not declOrder alone) so a config edit that changes declOrder/label
    /// naturally orphans a stale override (the self-heal `activeSectionLens`
    /// uses); a reorder leaves the id unchanged so the override follows its
    /// section. Workspace labels live in the catalog (`workspaceNames`), so a
    /// workspace rename routes to `renameWorkspace` and never lands here.
    var sectionLabelOverride: [Int: [String: String]] = [:]
    /// W2.2 (board model, t-wrd2): the session-only SELECTED BOARD index per
    /// mac desktop — the view-state twin of `sectionLabelOverride` (a
    /// PROJECTION-SEAM dict, NOT the degrade-path `macDesktopSectionOrder`).
    /// Keyed by the NON-NIL mac-desktop ordinal, read ONLY inside the
    /// `let ordinal = macDesktopOrdinal` guard at the single `apply()`
    /// projection seam via `config.activeBoardSections(forMacDesktopOrdinal:
    /// board:)`; the value is the 0-based index of the `[[desktop.N.tab]]`
    /// board currently SHOWN by tree/grid/rail. Absent ⇒ board 0 (the first
    /// board, and the flat-degrade path when no boards are configured), so all
    /// three views agree. Because the read is ordinal-gated it NEVER consults a
    /// `-1` bucket — a future writer (W2.3 `facet board`) must therefore guard
    /// on a non-nil `currentMacDesktopOrdinal()` like `sectionLabelOverride`'s
    /// writer (Controller+CLIDispatch), NOT write under `?? -1` (which would
    /// orphan the entry in a bucket the seam can't read). NEVER written to disk
    /// (config.toml stays read-only) and NEVER touches the backend (a board
    /// switch re-groups the SAME windows — display only). A relaunch resets to
    /// board 0; a mac-desktop swap reads the destination ordinal's own
    /// selection for free. The resolver clamps the index, so a stale selection
    /// after a hot-reload that dropped boards self-heals to the nearest
    /// in-range board.
    var selectedBoard: [Int: Int] = [:]

    /// Per-board remembered active section (t-wrd2 / L1), keyed
    /// `[ordinal: [board: ActiveSection]]`. A board switch saves the section the
    /// user was on under the board they LEAVE and restores the destination
    /// board's — the single `currentActiveSection` would otherwise go stale on a
    /// switch (`apply()`'s re-read fires on a desktop swap / WS switch, never a
    /// board switch), leaving the active-lens highlight on the wrong board.
    /// Session-only, per-mac-desktop, reset on relaunch — same contract as
    /// `selectedBoard` / `macDesktopSectionOrder`. Written ONLY through
    /// `commitBoardSelection`.
    var boardActiveSection: [Int: [Int: ActiveSection]] = [:]

    /// The active board's sections for `ordinal` (t-wrd2 / W2.5) — the board
    /// SELECTOR keyed by this mac desktop's session-selected board. EVERY
    /// Controller-side section read goes through this ONE seam so the
    /// section-id `declOrder` agrees with what the `apply()` projection minted
    /// (`FilterProjection` enumerates the SAME list) — the W2.5 Risk#1
    /// guard against a second, stale section SSOT. With no `[[desktop.N.tab]]`
    /// boards (or no selection) it degrades to the flat `[[desktop.N.section]]`
    /// list at board 0 — byte-identical to the pre-board reads. `nil` ordinal →
    /// empty (the config selector keys off the ordinal). The adapter's own id
    /// resolution is now board-aware too (W2.5-adapter — the Controller pushes
    /// the board via `setSelectedBoard`), so both sides resolve a board-minted
    /// id against the same selected-board section list.
    func selectedBoardSections(forOrdinal ordinal: Int?) -> [DesktopSection] {
        config.activeBoardSections(
            forMacDesktopOrdinal: ordinal,
            board: ordinal.flatMap { selectedBoard[$0] } ?? 0)
    }
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
    /// Last `FilterProjection` diagnostics logged for the section/lens
    /// model (PR5). `apply()` runs the projection every refresh, but the
    /// diagnostics (malformed lens `match`, surplus workspace section) depend
    /// only on the static config — so log them once per change, not once per
    /// frame.
    private var loggedSectionDiagnostics: [String] = []
    /// Section/lens model (EX-1): the session-only ACTIVE SECTION — a
    /// `type="lens"` section the user activated (`.lens(id)`, A0: keyed by the
    /// stable section id) or the active workspace (`.workspace(index)`), exactly
    /// one at a time. This is the VIEW's highlight MIRROR (emphasises the active
    /// section's tree header in `pal.primary`); the real state — the
    /// cross-workspace anchor-park + the active workspace — lives in the catalog,
    /// which is the authority. Set optimistically (lens) via `setActiveLens` →
    /// `activateLensID`; `apply()` re-reads it from `backend.currentActiveSection()`
    /// (the authority) whenever the active section context shifts (a mac-desktop
    /// swap reads BACK the destination's persisted section; a facet-workspace
    /// switch reads back the now-cleared lens → `.workspace(N)`, EX-0.4). Carrying
    /// the workspace index (not just a lens `String?`) is what resolves the EX-0.5
    /// double-source-of-truth: the idempotent guard `currentActiveSection != .lens(id)`
    /// can never stale-swallow a re-activation because `.workspace(N) != .lens(id)`
    /// structurally.
    var currentActiveSection: ActiveSection = .workspace(1)

    /// The **1-based** index of the active workspace from the latest snapshot,
    /// or 1. ⚠️ `Workspace.index` is **0-based** (snapshot seam:
    /// `index: entry.index - 1`, WorkspaceCatalog) while `ActiveSection.workspace`
    /// is 1-based — convert with `+ 1`. The `?? 0` only fires on an empty
    /// snapshot. (The catalog's own `activeIndex` is already 1-based and maps to
    /// the enum directly; only the `[Workspace]` snapshot crosses this boundary.)
    func activeWSIndex(in wss: [Workspace]) -> Int {
        (wss.first(where: { $0.isActive })?.index ?? 0) + 1
    }
    /// Whether `apply()` has rendered at least once, and the mac-desktop
    /// ordinal it last rendered — together they detect a mac-desktop swap so
    /// `currentActiveSection` resets. The first render only records the ordinal
    /// (no clear), so a lens activated between renders survives.
    /// Internal (not private) so `setActiveLens` can sync them before its
    /// synchronous `apply()` (keeping a just-set active lens from being read as
    /// a mac-desktop swap and wiped).
    var hasRenderedMacDesktop = false
    var lastRenderedMacDesktopOrdinal: Int?
    /// Leading-edge debounce flag for `requestRefresh`: coalesces a
    /// burst of backend events into a single `refresh()` within
    /// `refreshDebounce`. Set on the first event, cleared when the
    /// debounced refresh fires. Main-actor confined. (Grip-drag
    /// protection is separate — it lives in `refresh()` via the
    /// `realWindowDrag?.inProgress` gate.)
    private var refreshPending = false
    /// `--view tree --loading MS` skeleton hold timer (see
    /// `showLoading` in Controller+CLIDispatch.swift). Lives here —
    /// extensions can't hold stored properties.
    var loadingTimer: Timer?
    /// A `--loading` show wants to enter keyboard nav once the skeleton
    /// gives way to real content. `--view tree` (no loading) calls
    /// `enterActive` synchronously, but the `--loading` branch returns
    /// before it so the skeleton never steals key mid-mac-desktop-switch
    /// (#311). Deferring the activate to the skeleton→content transition
    /// (= the switch has settled) restores keyboard nav for the chord
    /// `--view tree --loading` path without the mid-switch focus grab the
    /// old `--active`+`--loading` loud-error guarded against. Consumed
    /// once in `apply()`. Memory: [[facet-per-native-space-ws]].
    var loadingWantsActive = false

    // MARK: - Preview (hover overlay + grid thumbnails)

    let previewPool = PreviewOverlayPool()
    /// The capture port (`WindowCapturing`, FacetCore) — always present.
    /// The sole implementation (`SCKWindowCapture`, ScreenCaptureKit) is
    /// built once in `init`; capture call sites use it unconditionally.
    let winPreview: any WindowCapturing
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

    var gridOverlay: OverviewPanel?
    var gridView: GridView?
    var gridBackdrop: NSView?
    var gridKbMonitor: Any?
    /// Remembered while the grid is up so we can restore exactly the
    /// pre-show visibility state on dismiss.
    var treeWasHidden = false
    var isGridVisible: Bool { gridOverlay != nil }

    // MARK: - Workspace rail (bottom overview bar)

    var railOverlay: OverviewPanel?
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
    /// True when `openTagEditor` itself flipped the activation policy to
    /// `.regular` (i.e. the tree was passive when the tag panel opened), so
    /// `finishTagEditor` knows to revert it on close. When the tree was already
    /// in keyboard nav, this stays false and close just re-keys the tree.
    var tagEditorSelfActivated = false
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
        self.panelHost = PanelHost(view: view, paletteBox: treePaletteBox)
        self.winPreview = SCKWindowCapture()
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
        panelHost.handleBar.onContextMenu = { [weak self] scr in
            self?.showDesktopMenu(at: scr)
        }
        panelHost.boardTabBar.onSelectBoard = { [weak self] idx in
            self?.selectBoardFromUI(idx)
        }
        searchDelegate.onChange = { [weak self] q in
            MainActor.assumeIsolated {
                self?.sidebarView.setQuery(q)
            }
        }
        panelHost.searchBar.field.delegate = searchDelegate
        // Keep kbNav in sync with the panel's key status. The panel
        // only becomes key via explicit kb-nav entry (`enterActive` →
        // makeKey); a plain tree-row click no longer grabs key (that
        // would break same-app focus — see KeyablePanel). So this now
        // fires on the kb-nav enter/exit, not on every click.
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

    /// True while ANY of facet's own keyable sibling editors holds key (the
    /// tag-edit checklist or the section-rename field). Used by
    /// `handlePanelKeyChange` to distinguish "the tree handed key to our own
    /// editor" (keep kbNav alive — `finishTagEditor` re-keys on close) from a
    /// genuine involuntary key loss (a mac-desktop switch). Add every future
    /// keyable editor here so the #66 hand-back invariant can't silently
    /// regress.
    private var anyKeyableEditorOpen: Bool {
        TagEditPanel.shared.isOpen || SectionRenamePanel.shared.isOpen
    }

    private func handlePanelKeyChange(isKey: Bool) {
        if isKey {
            Log.debug("panelKey gained (kbNav=\(sidebarView.kbNav))")
            if !sidebarView.kbNav { sidebarView.enterKbNav() }
        } else {
            // The tag-edit checklist (R10) — or the section-rename editor (E2)
            // — just took key — its own panel is now key, so the tree resigned.
            // Don't tear down kbNav: it's a hand-off to our own keyable editor,
            // not a focus loss. `finishTagEditor` re-keys the tree on close,
            // resuming nav. Without this guard the tree would self-destruct nav
            // the moment the editor opened. Every keyable sibling editor must be
            // listed here, so they share one helper (the next one can't silently
            // regress this #66 invariant).
            if anyKeyableEditorOpen { return }
            // Drop kbNav. If we got here via the kb-nav exitActive
            // path, exitKbNav has already run and
            // this is a harmless idempotent call.
            if sidebarView.kbNav {
                // Reaching here with kbNav STILL set is an INVOLUNTARY key loss
                // (a deliberate exitActive clears kbNav first — so a row-click /
                // Enter never lands here, #66). A mac-desktop switch is the
                // common trigger: the OS strips key from the shared
                // `.canJoinAllSpaces` panel. Settle CLEANLY to passive (R12 / ト
                // ミー: facet must NOT auto-grab focus on a switch).
                Log.debug("panelKey lost (kbNav-active) → passive")
                sidebarView.exitKbNav()
                // Fully relinquish key, not just kbNav: otherwise `wantsKey`
                // lingers true and the passive panel re-grabs key on the next OS
                // activation cycle (e.g. switching desktops back), thrashing key
                // on/off. A later explicit summon (`--view tree` → enterActive →
                // makeKey) re-arms `wantsKey`. (R12: removing the lingering
                // wantsKey is what stopped the post-switch focus storm.)
                panelHost.resignKey()
                // You leave nav by losing key — clicking another app or
                // pressing Enter on a window (ESC no longer exits; it stays
                // in the tree). So this is now the sole revert path for that
                // case: drop facet back to .accessory so no Dock icon /
                // Cmd-Tab entry lingers after a click-away / window-activate.
                if NSApp.activationPolicy() == .regular {
                    NSApp.setActivationPolicy(.accessory)
                }
                prevApp = nil
            }
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
        writeStatus([])     // touch the files so `facet query` /
        writeQuery()        // `facet query --windows` work even before
                            // the first backend reply
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
    /// applyThemeOverride / writeStatus calls become no-ops).
    ///
    /// Reload-on (memory facet-cli-surface N11):
    ///   - theme           → applyThemeOverride live
    ///   - preview-mode    → next hover-preview reads the new value
    ///   - [workspaces]    → reflected in writeStatus (the live
    ///                       data-model overlay onto facet
    ///                       workspaces lands at Phase α impl)
    ///   - backend config  → `backend.updateConfig` pushes the fresh
    ///                       value so gaps / animation / layout-default /
    ///                       exclusion-rules / grouping hot-reload
    /// Reload-off (intentionally — restart required):
    ///   - [[desktop.N.section]] workspace count / layout — the catalog set is
    ///     seed-once / runtime-authoritative (config is the read-only
    ///     seed); a reload won't clobber runtime add/remove/rename.
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
        // PR6 / A0: drop a now-stale active lens — if the edited config no
        // longer resolves the active lens's stable id (`section:<declOrder>:<label>`)
        // to a lens section on the current mac desktop, clear it (else a re-added
        // same-label section would silently auto-light, and a removed one would
        // keep a dead highlight). Session-only contract.
        // A0 note: identity is the declOrder-embedded id, so a config **reorder**
        // (or rename) that moves the lens to a new declOrder no longer resolves
        // and DROPS — where the old label scan persisted it. Accepted (the drop
        // is to the always-present workspace; benign + narrow), surfaced via
        // `Log.line` (which also makes today's silent label-removal drop visible).
        if case .lens(let id) = currentActiveSection {
            // W2.5: validate against the ACTIVE board's sections (the same list
            // the projection minted the id from), not the flat list — else a
            // lens on a board config never re-resolves and is dropped on reload.
            let stillValid = ApplyResolver.section(
                forSectionID: id,
                in: selectedBoardSections(forOrdinal: currentMacDesktopOrdinal())
            ) != nil
            if !stillValid {
                let ws = activeWSIndex(in: lastWorkspaces)
                Log.line("active lens no longer resolves after config reload "
                    + "(id=\(id)) → workspace \(ws)")
                currentActiveSection = .workspace(ws)
                // COMPLETE the drop: clear the backend lens too, so the catalog
                // un-parks the windows the dropped lens was holding. The mirror
                // alone would leave the catalog's `activeSectionLens` set (its
                // windows parked) while the Controller shows a workspace —
                // desynced until the next lens op. Enqueued on `cliQueue` BEFORE
                // `updateConfig` below (FIFO), so the clear runs against the
                // still-valid old adapter config (its guards pass; the clear
                // path only restores parked members, it never re-resolves the
                // id). Mirrors `setActiveLens(nil)`'s clear.
                runBackendCommand { bk in
                    bk.setSectionLens(nil, autoFocus: false); return nil
                }
            }
        }
        backend.updateConfig(fresh)   // hot-reload the backend's copy
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

    /// The active mac-desktop ordinal via read-only SkyLight (nil = SkyLight
    /// unavailable / single-desktop). `apply()` (section keying), `setActiveLens`
    /// (active-lens validation), and `reloadConfig` (re-validation) all read
    /// through this so they agree on "which mac desktop" within one main-actor
    /// turn. (PR6.)
    func currentMacDesktopOrdinal() -> Int? {
        let id = MacDesktops.activeID()
        return id == 0 ? nil : MacDesktops.ordinal(for: id)
    }

    /// The `type="lens"` section labels on the mac desktop at `ordinal` — the
    /// active-lens domain (empty when the section model isn't active there, or
    /// it defines no lens sections). Reads the ACTIVE board's sections (W2.5),
    /// so on a board config the domain is the SELECTED board's lenses. Shared by
    /// `setActiveLens` (validate) and `reloadConfig` (re-validate after an
    /// edit). (PR6.)
    func lensSectionLabels(ordinal: Int?) -> [String] {
        guard config.isSectionModelActive(ordinal: ordinal), let ord = ordinal
        else { return [] }
        return selectedBoardSections(forOrdinal: ord)
            .filter { $0.type == .lens }.map(\.label)
    }

    /// A0: resolve a lens section's display `label` to its **stable id**
    /// (`"section:<declOrder>:<label>"`) on the mac desktop at `ordinal`, or nil
    /// when no `type="lens"` section there has that label. `declOrder` is the
    /// index into the ACTIVE board's section array (W2.5) — the SAME index
    /// `FilterProjection` mints the id from (`FilterProjection.swift`) and
    /// `ApplyResolver.section(forSectionID:)` parses back, so the round-trip is
    /// exact (both now read the selected board via `selectedBoardSections`).
    /// Config-based (not `lastSections`) so it resolves even before the first
    /// render (headless CLI). The label↔id map is 1:1 while labels are unique +
    /// non-empty (the A0 invariant). Shared by `setActiveLens`,
    /// `toggleActiveLens`.
    func lensID(forLabel label: String, ordinal: Int?) -> String? {
        guard config.isSectionModelActive(ordinal: ordinal), let ord = ordinal
        else { return nil }
        guard let declOrder = selectedBoardSections(forOrdinal: ord)
            .firstIndex(where: { $0.type == .lens && $0.label == label })
        else { return nil }
        return "section:\(declOrder):\(label)"
    }

    // The grid/rail don't recompute a lens `match` view-side. A lens is a pure
    // VIEW (t-0021): `FilterProjection` builds each section's window list (a
    // lens section lists its matched windows) and the views render that — one
    // display authority, no view-side recompute to drift from it.

    /// Surface any named-enum config value that silently clamped to a
    /// default (e.g. a layout name carried across a breaking rename:
    /// `tall` → `master-left` now degrades to `float`). `Log.line` —
    /// always on, so brew / plain `open Facet.app` users see it too,
    /// not just `FACET_DEBUG` runs. Fired once per load (startup +
    /// hot-reload), never from the per-tick `effective*` accessors.
    private func logConfigWarnings() {
        for warning in config.unknownValueWarnings() { Log.line(warning) }
    }

    /// Log `diagnostics` once per change, each line carrying `prefix`.
    /// `previous` is the per-call-site state slot it diffs against — the
    /// projection runs every refresh but its diagnostics depend only on the
    /// static config, so this emits only when the set actually changes, not
    /// once per frame. Each caller keeps its OWN slot (overview / section):
    /// folding them into one would let an overview change suppress a tree
    /// change and vice versa.
    private func logDiagnosticsOnChange(_ diagnostics: [String],
                                        prefix: String,
                                        against previous: inout [String]) {
        guard diagnostics != previous else { return }
        previous = diagnostics
        for d in diagnostics { Log.line(prefix + d) }
    }

    // MARK: - Per-surface palette resolution (PR-B)

    /// Resolve all three surface palettes into their boxes. Called at
    /// startup + on hot-reload + after a `--theme` override (via
    /// `applyThemeOverride`). Honors the active `themeOverride` (forces every
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
    /// the live `--theme` override (`applyThemeOverride`) and the hot-reload path.
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
        // P6: don't reconcile mid-slide — a reconcile-triggered re-tile
        // would AX-fight the in-flight cosmetic tween. The slide's settle
        // yields a fresh refresh when it lands.
        if backend.isAnimating {
            Log.debug("refresh skipped (slide animation in progress)")
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
        // capture only the active set.
        // Also remember which WS each window lived in, to spot a
        // cross-workspace move (trigger 3 below).
        var prevActiveFrames: [WindowID: CGRect] = [:]
        var prevWSofWindow: [WindowID: Int] = [:]
        var prevOnscreen: [WindowID: Bool] = [:]
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
        // Mac desktop ordinal (read-only SkyLight): the tree's top handle
        // band, the section-model routing below, AND the PR7 grid/rail
        // active-lens narrow all key off it — read ONCE here so they agree
        // within this main-actor turn. 0 = SkyLight unavailable → no name.
        let macDesktopOrdinal = currentMacDesktopOrdinal()
        // Session-only display-order override for this mac desktop (drag-to-
        // reorder). `displaySectionOrder` permutes the PROJECTED section list
        // (section path) and `displayWss` the degrade-path workspace list —
        // DISPLAY-ONLY (routing/landing key off `ws.index` / `sourceWorkspace
        // Index`, not array position, so windows never move). `lastWorkspaces`
        // (set above) stays index-ascending for routing/snapshot; only the
        // copies handed to the views are reordered. Empty override ⇒ identity.
        let displaySectionOrder = macDesktopSectionOrder[macDesktopOrdinal ?? -1]
        let displayWss = SectionOrder.applyWorkspaces(displaySectionOrder, to: wss)
        // Tag-unification + EX-0.4 (exclusive model) + EX-1 (ActiveSection):
        // the active section is held per-mac-desktop in the catalog (the
        // authority); `currentActiveSection` is only the view's highlight MIRROR.
        // Re-read it from the catalog whenever the active SECTION context may
        // have shifted underneath the mirror:
        //   • a facet-workspace switch — EX-0.4 clears the active lens at the
        //     catalog, so the mirror must drop the highlight; without this the
        //     stale mirror also makes `setActiveLens`'s idempotent guard swallow
        //     a re-activation of the SAME lens after a switch.
        //   • a genuine mac-desktop swap — the catalog (and its persisted lens)
        //     swaps in; READ BACK the destination's lens rather than blanket-nil
        //     (the grid/rail display rides the swapped-in catalog's active lens,
        //     which `FilterProjection` re-projects automatically).
        // The catalog's mirror — read ordinal-independently via
        // `backend.currentActiveSection()` — is the authority, so on a WS switch
        // we re-read it EVEN IF SkyLight momentarily can't name the desktop
        // (ordinal == nil); the ordinal only gates the mac-desktop-swap detector
        // and the not-section-model fallback. A PURE transient blip (no switch,
        // no real swap) fires neither trigger, so it can't false-nil a live lens;
        // and the baseline advances only on a real ordinal so a blip can't
        // register as a new baseline (→ a false swap on recovery). HOISTED above
        // the tree render so a cleared highlight lands in the same frame. The
        // FIRST render only records the ordinal (no read-back), so an
        // optimistically-set lens survives until the first real change.
        let macDesktopSwapped = hasRenderedMacDesktop
            && macDesktopOrdinal != nil
            && macDesktopOrdinal != lastRenderedMacDesktopOrdinal
        let wsSwitched = prevActive != nil && prevActiveWSIndex != prevActive
        if macDesktopSwapped || wsSwitched {
            if let ord = macDesktopOrdinal, !config.isSectionModelActive(ordinal: ord) {
                // section model off here → fall back to the spatial workspace
                currentActiveSection = .workspace(activeWSIndex(in: wss))
            } else {
                currentActiveSection = backend.currentActiveSection()   // the authority
            }
        }
        // Instrument a real mac-desktop ordinal change (read against the OLD
        // baseline so the log shows the transition).
        if macDesktopSwapped {
            Log.debug("apply: mac-desktop swap "
                + "\(lastRenderedMacDesktopOrdinal.map(String.init) ?? "nil")"
                + "→\(macDesktopOrdinal.map(String.init) ?? "nil")")
        }
        hasRenderedMacDesktop = true
        // Advance the baseline only on a real reading so a transient nil can't
        // register as the new baseline (and fire a false swap on recovery).
        if macDesktopOrdinal != nil { lastRenderedMacDesktopOrdinal = macDesktopOrdinal }
        // EX-2: project ONCE here (hoisted above the grid/rail feed AND the
        // tree render) so all three views share one ordered section list. Must
        // run AFTER the active-section re-read above — `activeLensID` reads the
        // freshly-resolved `currentActiveSection.lensID`. Section model off
        // ⇒ empty sections ⇒ the overview degrades to `wss` (byte-identical).
        if config.isSectionModelActive(ordinal: macDesktopOrdinal),
           let ordinal = macDesktopOrdinal {
            // W2.2 (board model): read the section list through the board
            // SELECTOR keyed by the session-selected board for this mac desktop.
            // The SAME `selectedBoardSections` seam every other Controller-side
            // section read uses (W2.5), so the id `declOrder` minted HERE matches
            // what the lens/DnD resolvers parse back. With no `[[desktop.N.tab]]`
            // boards this DEGRADES to the flat list (board 0) — byte-identical.
            let secs = selectedBoardSections(forOrdinal: ordinal)
            // EX-3 迷子: feed the orphan windows (in no workspace, so absent
            // from `wss`) so the projection appends them into the `not
            // workspace` receptacle + any content lens they match. Main-actor-
            // safe mirror read (lock-guarded, refreshed on cliQueue). Closes the
            // GAP where an orphan rendered in no tree/grid/rail section even
            // though the activation path gathered it on-screen.
            let projected = FilterProjection.project(
                workspaces: wss, sections: secs,
                orphans: backend.orphanWindows())
            logDiagnosticsOnChange(projected.diagnostics, prefix: "overview: ",
                                   against: &loggedSectionDiagnostics)
            // §E: overlay the session-only lens DISPLAY-LABEL override BEFORE
            // the reorder — display-only, id-preserving (identity is invariant
            // so `--focus index:N` + the active-lens highlight stay correct),
            // and lens-only (a workspace label comes from the catalog). Flows
            // into all three views via `lastSections`.
            let relabeled = applyLabelOverrides(projected.sections,
                                                to: sectionLabelOverride[ordinal] ?? [:])
            // Apply the session-only reorder to the PROJECTED result (never
            // the config input — see `SectionOrder`). Flows for free into
            // tree/grid/rail since all three read `lastSections`.
            lastSections = SectionOrder.apply(displaySectionOrder,
                                              to: relabeled)
        } else {
            lastSections = []
        }
        lastActiveLensID = currentActiveSection.lensID
        // A lens is a pure VIEW (t-0021): the open grid/rail show whatever
        // `FilterProjection` projects (a lens section lists its matched
        // windows) — no park-flag narrowing, no view-side recompute. `wss`
        // stays the full set.
        if let g = gridView {
            g.workspaces = displayWss          // reorder: degrade-path cell order
            g.activeIndex = wss.first(where: { $0.isActive })?.index
            g.sections = lastSections          // EX-2: section list (empty ⇒ degrade)
            g.activeLensID = lastActiveLensID  // EX-2: active lens id for single-highlight
            g.layoutCells()       // refresh open grid on backend events
        }
        // The rail is a *persistent* bar (unlike the snapshot-on-show
        // grid), so keep it live with every reconcile — the active-WS
        // highlight + window counts track switches and add/close.
        if let rv = railView {
            // EX-2b: the active SECTION id BEFORE the field update (reads the
            // rail's still-old activeLensID/activeIndex/sections).
            let oldActiveID = activeSectionID(activeLensID: rv.activeLensID,
                                              activeIndex: rv.activeIndex,
                                              sections: rv.sections)
            rv.workspaces = displayWss         // reorder: degrade-path cell order
            rv.activeIndex = wss.first(where: { $0.isActive })?.index
            rv.sections = lastSections         // EX-2: section list (empty ⇒ degrade)
            rv.activeLensID = lastActiveLensID  // EX-2: active lens id for single-highlight
            // 2-b carousel: an EXTERNAL activate (CLI / lens) while the rail
            // is open re-centres the strip on the new active SECTION — but
            // only when the user isn't mid-browse (cursor still on the OLD
            // active section), so a manual rotation isn't yanked back.
            let newActiveID = activeSectionID(activeLensID: rv.activeLensID,
                                              activeIndex: rv.activeIndex,
                                              sections: rv.sections)
            if rv.selectedSectionID == oldActiveID, let n = newActiveID {
                rv.selectedSectionID = n
            }
            rv.layoutCells()      // refresh open rail on backend events
        }
        if firstRealApply {
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
        let wp = winPreview
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
        if userHidden { return }
        guard !wss.isEmpty, NSScreen.main != nil else {
            // The loading show resolved to an empty / screenless mac
            // desktop (panel hidden) — there is nothing to enter keyboard
            // nav on, so disarm the deferred activate (else it would fire
            // spuriously when a window later appears here).
            loadingWantsActive = false
            panelHost.hide(); return
        }
        sidebarView.frame.size.width = panelHost.userWidth
        sidebarView.forceRedraw()
        // `macDesktopOrdinal` + the PR6 active-lens swap-reset were computed
        // / applied above. Section/lens model (PR5): when this mac desktop is
        // section-managed (≥1 `type="workspace"` section), the tree renders the
        // config's ordered sections — a window shows up in EVERY section it
        // matches. Otherwise the by-workspace / tag path.
        // EX-2: the projection is now HOISTED above the grid/rail feed (see
        // `lastSections`/`lastActiveLensID`), so the tree consumes the SAME
        // ordered list all three views share — no second `FilterProjection.project`
        // call, no second diagnostics log (logged once under "overview: ").
        let contentH: CGFloat
        if config.isSectionModelActive(ordinal: macDesktopOrdinal) {
            contentH = sidebarView.update(sections: lastSections,
                                          workspaces: wss,
                                          activeLensID: lastActiveLensID,
                                          titles: titles,
                                          macDesktop: macDesktopOrdinal)
        } else {
            contentH = sidebarView.update(displayWss, titles: titles,
                                          macDesktop: macDesktopOrdinal)
        }
        // Board tab bar (W2.4): feed the tree's board switcher. Shown only with
        // ≥2 `[[desktop.N.tab]]` boards on this mac desktop — a flat / single-
        // board config feeds an empty label list, so PanelHost hides the band
        // and reserves no height (byte-identical chrome). The active index is
        // clamped, matching the projection's board clamp.
        let boards = macDesktopOrdinal
            .flatMap { config.effectiveMacDesktopTabConfigs[$0] } ?? []
        if boards.count >= 2, let ord = macDesktopOrdinal {
            panelHost.boardTabBar.boardLabels = boards.map(\.displayLabel)
            panelHost.boardTabBar.activeBoardIndex =
                max(0, min(boards.count - 1, selectedBoard[ord] ?? 0))
        } else {
            panelHost.boardTabBar.boardLabels = []
        }
        panelHost.layout(contentHeight: contentH,
                         searching: sidebarView.searching)
        if !panelHost.isVisible { panelHost.show() }
        // Deferred activate for the `--loading` show: the skeleton has now
        // given way to the new mac desktop's real content (`update`
        // cleared it on a content-signature change, or the timer-cap path
        // did). This is the settled moment the old `--active`+`--loading`
        // mutual-exclusion was protecting — enter keyboard nav here, never
        // mid-switch. Consume the flag FIRST so the `enterActive` →
        // `setHidden(false)` → `refresh()` → `apply()` bounce (async, so no
        // sync re-entry) can't re-trigger. `isSkeleton` guards the held
        // mid-switch applies, where `update` returned early with the
        // skeleton still up.
        if loadingWantsActive, !sidebarView.isSkeleton {
            loadingWantsActive = false
            Log.debug("apply: loading settled → enterActive (deferred kb-nav)")
            enterActive()
        }
        writeStatus(wss)
        writeQuery()
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
        // P6: the catalog reads (stashedScratchpads / definedTagNames)
        // run on `cliQueue` — the single catalog
        // serialization point — alongside the file write. `wss` is an
        // immutable value snapshot, so `entries` is catalog-free. The
        // status file is a debugging convenience, so the tiny
        // eventual-consistency window from deferring the catalog read is
        // fine (it never tears against the cliQueue mutators).
        let bk = backend
        let theme = config.effectiveTheme
        let lastError = self.lastError
        cliQueue.async {
            let entries = wss.map { w in
                WorkspaceStatusEntry(
                    index: w.index + 1,     // 1-indexed for the CLI surface
                    name: w.name,
                    active: w.isActive,
                    windowCount: w.windows.count,
                    stickyCount: w.windows.filter(\.isSticky).count)
            }
            let snap = StatusSnapshot(
                backend: bk.name,
                theme: theme,
                workspaces: entries,
                stashed: bk.stashedScratchpads(),
                tags: bk.definedTagNames(),
                lastError: lastError,
                timestamp: ISO8601DateFormatter().string(from: Date()))
            do { try snap.write() } catch {
                Log.debug("writeStatus failed: \(error)")
            }
        }
    }

    /// Leading-edge throttle for `writeQuery()`. The window-query sweep
    /// (`backend.queryEntries()`) is much heavier than `writeStatus`
    /// (a full CGWindowList + SkyLight + AX-title pass over EVERY mac
    /// desktop), so we cap it: a query file 0.5 s stale is fine for a CLI
    /// read, and the 2 s poll guarantees eventual freshness.
    private static let queryWriteThrottle: TimeInterval = 0.5
    private var lastQueryWriteAt: Date?

    /// Snapshot every window to `/tmp/facet-query.json` for
    /// `facet query --windows` (#223). Runs `backend.queryEntries()` OFF
    /// the main actor on `cliQueue` — the sweep is heavy and AXTitles is
    /// cliQueue-only by contract; the atomic file write is pure I/O.
    /// Throttled (see `queryWriteThrottle`); errors swallowed, same as
    /// `writeStatus` (a debugging/inspection convenience, not a
    /// correctness path). Hooked to `apply()` (every reconcile) + once at
    /// `start()`.
    private func writeQuery() {
        let now = Date()
        if let last = lastQueryWriteAt,
           now.timeIntervalSince(last) < Self.queryWriteThrottle { return }
        lastQueryWriteAt = now
        // P6: read the catalog state (active + parked) AND run the heavy
        // CGWindowList + SkyLight + AX sweep on `cliQueue` — the single
        // catalog serialization point. `queryFacetStates()` is the only
        // place `parkedCatalogs` is read; keeping it on cliQueue (not main)
        // is what stops it tearing against the cliQueue mutators.
        cliQueue.async { [bk = backend] in
            let states = bk.queryFacetStates()
            let entries = bk.queryEntries(facetStates: states)
            do { try WindowQuery.write(entries) }
            catch { Log.debug("writeQuery failed: \(error)") }
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
            loadingWantsActive = false   // a hide cancels a pending loading-activate
            exitActive(restore: false)
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
        // Switch to the target workspace if needed, then run the ops in
        // sequence with ~120 ms between them so each one's effect is
        // visible before the next lands. The ops act on the FOCUSED
        // window (WindowAction contract, Backend.swift), so CONFIRM focus
        // landed on `window` before running them — `Focus.assertBlocking`
        // re-asserts until the backend agrees, beating the WM's
        // post-switch default-focus race that a single focus + fixed
        // sleep would lose (ops would then hit the wrong window).
        let needSwitch = (ws != lastWorkspaces.first(where: {
            $0.isActive
        })?.index)
        let bk = backend
        cliQueue.async {
            if needSwitch { bk.switchWorkspace(toIndex: ws) }
            let ok = Focus.assertBlocking(window, backend: bk)
            Log.debug("runWindowOps ws=\(ws) needSwitch=\(needSwitch) "
                + "target=\(window.id.serverID) focusConfirmed=\(ok) "
                + "ops=\(ops.count)")
            for a in ops { bk.perform(a); usleep(120_000) }
        }
    }

}
