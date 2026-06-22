// `WindowBackend` conformance using only AX + public macOS APIs
// (no external CLI, no private-API injection). This file is the
// seam between facet and the OS for the native backend.
//
// Phase progression (memory: facet-architecture-decisions):
//   α (shipped) — virtual workspace state self-managed; focus
//   β (shipped) — window move across workspaces; off-screen
//                 park/unpark (`anchor` hide method,
//                 memory: native-window-hide-methods)
//   γ (shipped) — tiling layout engines (BSP + stack, AX-role
//                 auto-float). Frozen 2026-05-26, memory:
//                 facet-phase-gamma-decisions.
//   δ (shipped) — display reconfigure handling, geometry persistence
//                 (memory: facet-phase-delta-decisions)
//   ε (shipped) — `FacetAdapterRift` retired (v2.0.0); native is
//                 the sole backend
//
// State lives in `WorkspaceCatalog` (pure value type, AX-free,
// unit-testable). This file owns only the effects: CGWindowList
// enumeration, AX focus / position / close, AX event
// subscription wiring, tile / stack frame application, and the
// AsyncStream plumbing for events and errors.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore
import FacetAccessibility
import FacetCore

public final class NativeAdapter: WindowBackend, @unchecked Sendable {
    public let name = "native"

    /// Advertised layout-mode set — drives the layout picker and the
    /// accepted `--layout` values. `bsp` / `stack` are the stateful
    /// Phase γ modes; `LayoutRegistry.names` adds the stateless
    /// engines (Theme B — memory: facet-theme-b-decisions). `float`
    /// is the "no tiling applied" baseline: picking it leaves the
    /// WS's windows exactly where they are (facet stops controlling
    /// geometry but still tracks them / parks on mac-desktop switch). The
    /// CLI's `canonicalLayoutModes` already lists it; advertise it
    /// here too so it appears in the right-click picker.
    public let layoutModes = LayoutRegistry.allModeNames

    // MARK: - State (delegated to catalog)

    /// Self-managed workspace state for the **currently active**
    /// mac desktop. All mutations go through here so the
    /// state machine stays pure and testable; this file only
    /// applies the AX side-effects the catalog hands back.
    var catalog = WorkspaceCatalog()

    /// Per-mac-desktop catalogs that aren't currently active.
    /// facet keeps an independent set of virtual workspaces per
    /// mac desktop (memory: facet-per-native-space-ws). On a
    /// mac-desktop switch the active `catalog` is parked here under its
    /// mac desktop id and the destination mac desktop's catalog is swapped in
    /// (lazily created on first visit). Window state is session-only
    /// (facet never persists), so on restart each mac desktop's catalog
    /// rebuilds from its live windows.
    var parkedCatalogs: [UInt64: WorkspaceCatalog] = [:]

    /// SkyLight id of the mac desktop `catalog` belongs to. `0`
    /// when SkyLight is unavailable — then facet runs a single
    /// shared catalog (pre-per-mac-desktop behaviour) and never swaps.
    var activeMacDesktopID: UInt64 = 0

    /// 1-based Mission-Control ordinal of the active mac desktop
    /// (user mac desktops only). Selects the `[[desktop.N.section]]` config;
    /// `nil` → fall back to `defaultWorkspaceCount` unnamed slots.
    /// Refreshed on every mac-desktop swap. May briefly go stale if the
    /// user reorders mac desktops in Mission Control without switching —
    /// a cosmetic count mismatch only
    /// (memory: facet-per-native-space-ws).
    var activeMacDesktopOrdinal: Int?

    /// Snapshot of the last `workspaces()` build, returned as-is on
    /// the next call. Rebuilt every `refreshCatalog()` invocation.
    var workspaceList: [Workspace] = []

    /// Backend config, hot-reloaded via `updateConfig` (the
    /// `WindowBackend` command `Controller.reloadConfig()` calls). The
    /// gaps / animation / layout-default / exclusion-rules / grouping
    /// that `refreshCatalog` reads each tick pick up `config.toml` edits
    /// without a restart. The live workspace SET is NOT re-seeded — once
    /// seeded it's runtime-authoritative (`facet workspace --add/--remove`
    /// own it; config stays the read-only seed, see
    /// `WorkspaceCatalog.seed`), so `[[desktop.N.section]]` workspace-count /
    /// layout edits still land only on restart by design.
    ///
    /// Lock-guarded: the slide path reads it on the MAIN thread
    /// (`NativeAdapter+Slide.swift` resolveAnimPreset) while `updateConfig`
    /// writes on `cliQueue`, so the lock keeps the struct read/write atomic
    /// (no torn read). Every `config.effective…` call site reads through
    /// the computed accessor unchanged.
    private let configLock = NSLock()
    private var _config: FacetConfig
    var config: FacetConfig {
        configLock.lock(); defer { configLock.unlock() }
        return _config
    }

    /// `WindowBackend` hot-reload: swap the config on `cliQueue` (so a
    /// `refreshCatalog` tick never straddles the change) under the lock
    /// (which covers the main-thread slide reader), then nudge one refresh
    /// so the edits surface promptly rather than waiting for the ~2 s poll.
    /// The workspace SET is unaffected — `WorkspaceCatalog.seed` is
    /// one-shot, so runtime add/remove/rename stay authoritative.
    public func updateConfig(_ config: FacetConfig) {
        cliQueue.async { [weak self] in
            guard let self else { return }
            self.configLock.lock()
            self._config = config
            self.configLock.unlock()
            Log.debug("native: config hot-reloaded")
            self.eventContinuation.yield(.refreshNeeded)
        }
    }

    /// AX-driven event observer. Cuts the lag between "user
    /// opened a window" and "facet sees it" from the Controller's
    /// 2 s poll cadence to the system's own AX latency.
    /// Held here for the adapter's lifetime; never `stop()`d.
    private var eventObserver: WindowEventObserver?

    /// Phase δ: fires when the OS finishes a display
    /// reconfiguration (resolution change / arrangement /
    /// hot-plug / lid / sleep wake). Debounced 0.5 s so a burst
    /// of mid-transition notifications collapses to one handler
    /// invocation on the final stable layout. Held for the
    /// adapter's lifetime alongside `eventObserver`.
    private var displayObserver: DisplayChangeObserver?

    // ── Stored state for the extracted extension files (#182 phase 4)
    // Swift requires stored properties on the primary declaration, so
    // the state owned by the Queries / Slide / Scratchpad clusters
    // stays here (internal: the funcs that use it live in the
    // NativeAdapter+*.swift extension files).

    // (Queries — reconcile / classify bookkeeping)
    /// Cleared after the first successful `refreshCatalog`. Used
    /// to bulk-mark the initial CGWindowList as pre-existing so
    /// off-screen windows alive at launch can't sneak in later.
    var didBootstrap = false
    /// Last time a managed window vanished (Cmd+W, app quit).
    /// Bounds the post-close redirect so it only kicks in right
    /// after a close — Cmd+Tab and other deliberate focus moves
    /// outside this window are left untouched.
    var recentCloseAt: Date?
    /// How long after a close the redirect stays armed. Long
    /// enough to cover the AX-event + reconcile settling, short
    /// enough not to hijack the user's next deliberate action.
    let closeFocusWindow: TimeInterval = 0.6

    /// raise-on-open: window ids ever seen in the `.optionAll`
    /// enumeration this session. A pre-existing window on another mac
    /// desktop is already enumerated (off-screen) before you switch to
    /// it, so it is NOT new; a window whose id first appears here just
    /// came into existence — a signal independent of the
    /// `kAXWindowCreated` observer (which races app launches and has a
    /// 2 s hint TTL). Seeded at bootstrap so startup windows don't count
    /// as freshly opened. Cumulative on purpose: NOT pruned to the live
    /// set, so a one-poll enumeration flicker can't re-flag a window as
    /// new. Only maintained when raise-on-open is enabled.
    var seenWindowIDs: Set<WindowID> = []
    /// raise-on-open: genuinely-new window ids awaiting their first
    /// catalog commit. A float here is raised once when it joins
    /// `windowMap`; an id is dropped on commit (raised, or — if it tiled
    /// — simply handled) or when it closes before committing.
    var freshlyOpenedIDs: Set<WindowID> = []

    /// CGWindowIDs of windows that fired `kAXWindowCreated`, mapped
    /// to the create timestamp. A genuinely-new window can't be a
    /// mac-desktop switch `isOnscreen` flip of an existing one, so
    /// `reconcile` adds these on first on-screen sight — skipping the
    /// two-tick gate that otherwise costs up to one ~2s poll. Touched
    /// only on `cliQueue` (write from the observer closure's
    /// `cliQueue.async`, drain in `refreshCatalog`, both serial) so no
    /// lock is needed. Entries are consumed on add and expire after
    /// `trustedNewTTL` (e.g. a transient window that closed before it
    /// ever became on-screen).
    var trustedNew: [WindowID: Date] = [:]
    /// Upper bound a trusted-new hint lives before it's discarded if
    /// the window never materialised on-screen. ~matches the poll
    /// cadence — long enough for the create→settle transient, short
    /// enough that a stale hint can't fast-add much later.
    let trustedNewTTL: TimeInterval = 2.0

    /// Cap on `classifyNewWindows`'s per-refresh AX probes. The
    /// role check costs ~3 AX round-trips per window (window
    /// lookup + role + subrole), and each round-trip has a
    /// default 6s timeout — a 100-window startup with one busy
    /// app could otherwise stall reconcile for minutes. Beyond
    /// the cap, new windows simply enter the tiler without the
    /// auto-float hint; the user can `--toggle-float` them
    /// manually. Tuned so a normal session start (≤16 new
    /// windows per refresh tick) is fully covered.
    let maxAutoFloatProbes = 16

    /// pid → bundle id cache. Bundle id is stable for a process's
    /// lifetime, so resolve once via `NSRunningApplication` and reuse.
    /// Only failures are left uncached (so a later tick can retry an
    /// app that wasn't ready). Touched only on `cliQueue`
    /// (`enumerateCGWindows`), like the rest of the catalog state.
    var pidToBundleId: [pid_t: String] = [:]

    // (Slide — in-flight animation state)
    // P6: the slide CLOCK (timer / anims / settle / clock fields below) is
    // touched ONLY on the main runloop — by `startSlide`, `slideTick`, and
    // the settle, all main. The COMMAND that starts a slide runs on
    // `cliQueue`: it commits the catalog there, then hands a *value* plan to
    // `startSlide` via a single `DispatchQueue.main.async`. The settle is
    // AX-only (no catalog access) so the slide never re-touches catalog off
    // the cliQueue serialization point. See NativeAdapter+Slide.swift.
    /// In-flight slide clock + its settle. Touched on main only.
    var slideTimer: Timer?
    var slideFinish: (() -> Void)?
    /// Resolved AX elements + from/to origins for the in-flight slide.
    /// Resolved ONCE (not per frame): the per-frame AX window lookup was
    /// the main smoothness drag. Read through `self` in the timer block
    /// so the non-Sendable AX element stays behind the class's
    /// `@unchecked Sendable` boundary.
    var slideAnims: [(ax: AXUIElement, slide: WindowSlide)] = []
    var slideStart: Date?
    var slideDuration: TimeInterval = 0
    /// Easing for the in-flight animation; set when the driver starts.
    var slideCurve: (Double) -> Double = SlideCurve.easeOutCubic
    /// True while the in-flight slide is a retile (no park bookkeeping),
    /// so an interrupt can drop it and retarget from current positions.
    var slideIsRetile = false
    /// True from `startSlide` until the settle fires. Read by
    /// `Controller.refresh` (via `isAnimating`) so a poll-driven reconcile
    /// doesn't AX-snap windows mid-tween. Main-confined like the rest of
    /// the slide clock — set in `startSlide`, which runs one
    /// `DispatchQueue.main.async` hop after the command commits the catalog
    /// on cliQueue. A reconcile landing in that sub-millisecond gap can
    /// still slip past the guard, but the cost is at most a transient
    /// frame-fight that self-heals on the settle's refresh — never catalog
    /// corruption (the catalog was already committed on cliQueue).
    var slideInProgress = false
    /// CADisplayLink (macOS 14+) driving the slide; `AnyObject?` keeps
    /// the stored type available on macOS 13. nil = Timer fallback.
    var displayLink: AnyObject?
    lazy var slideTicker = SlideTicker(self)

    /// Direction for the next switch's slide: +1 forward, -1 back, nil =
    /// derive from the index delta. `switchWorkspaceRelative` sets it so
    /// next/prev always slide the intuitive way even when they wrap
    /// (e.g. last → first reads as "forward", not the long way back).
    var slideDirectionHint: CGFloat?

    // (Scratchpad / frame-apply — live-resize-follow fast path)
    // Live-resize-follow fast path state. During a master/bsp divider
    // drag, the neighbour write happens every tick — re-resolving the AX
    // element each time (`AXGeom.window`) measured ~14ms/tick (the bulk of
    // the "ワンテンポ遅れ"). Cache the element for the drag; cleared at
    // gesture end (`endLiveResize`). Touched only on the cliQueue
    // live-resize path, so no lock.
    var followAXCache: [WindowID: AXUIElement] = [:]

    // (Section-lens — tag-unification Phase 1)
    /// Compiled cache for the active section-lens's `match`, keyed by the raw
    /// string so a config hot-reload (or a lens change) recompiles. Avoids
    /// re-parsing the WHERE-clause on every reconcile's continuous re-park.
    /// Touched only on `cliQueue` (the eval helpers), like the rest of the
    /// catalog-adjacent state.
    var sectionLensCompiled: (match: String, filter: FacetFilter)?

    /// Lock-guarded, main-readable mirror of the active catalog's
    /// `activeSection` (EX-1: was a lens-only `String?`). The catalog is
    /// `cliQueue`-confined, but the Controller's `apply()` (main actor) reads
    /// the active section back to drive the single active-section highlight —
    /// including after a mac-desktop swap restored a desktop whose lens
    /// persists (the swapped-in catalog's `activeSection` is mirrored by the
    /// `syncSectionLensMirror()` call in `refreshCatalog`, after
    /// `swapCatalogIfMacDesktopChanged`). Refreshed on `cliQueue` (every
    /// `refreshCatalog` + each `setSectionLens` / `switchWorkspace`) under the
    /// lock so the main-thread reads are race-free (same pattern as `config`).
    private let sectionLensLock = NSLock()
    private var _activeSection: ActiveSection = .workspace(1)

    /// Refresh the main-readable mirror from the active catalog. Called on
    /// `cliQueue` wherever `catalog.activeSection` may have changed.
    func syncSectionLensMirror() {
        sectionLensLock.lock(); defer { sectionLensLock.unlock() }
        _activeSection = catalog.activeSection
    }

    public func currentActiveSection() -> ActiveSection {
        sectionLensLock.lock(); defer { sectionLensLock.unlock() }
        return _activeSection
    }

    /// Lens-only shim over `currentActiveSection()` for existing callers.
    public func currentSectionLens() -> String? { currentActiveSection().lensLabel }

    /// EX-3 迷子: the main-readable mirror of the catalog's orphan windows
    /// (managed, assigned to no workspace). `snapshot` can't carry orphans
    /// (they belong to no `Workspace`), so `Controller.apply` (main) reads this
    /// mirror and feeds it to `FilterProjection.project(…, orphans:)` for the
    /// views' lens sections. Refreshed on `cliQueue` at the tail of every
    /// `refreshCatalog` (right after the `snapshot`) under `sectionLensLock`,
    /// so the main-thread read is race-free — same handoff as `_activeSection`.
    private var _orphanWindows: [Window] = []

    /// Refresh the orphan mirror from the active catalog. Called on `cliQueue`
    /// with the SAME `live` / `focused` / section-model `populateTags` gate the
    /// `snapshot` used, so the two agree. The catalog read happens on-queue
    /// (no concurrent mutator — catalog is cliQueue-confined); the lock guards
    /// only the array handoff to the main thread.
    func syncOrphanMirror(in live: [Window], focused: WindowID?,
                          populateTags: Bool) {
        let orphans = catalog.orphanWindows(in: live, focused: focused,
                                            populateTags: populateTags)
        sectionLensLock.lock(); defer { sectionLensLock.unlock() }
        _orphanWindows = orphans
    }

    public func orphanWindows() -> [Window] {
        sectionLensLock.lock(); defer { sectionLensLock.unlock() }
        return _orphanWindows
    }

    // MARK: - Event / error streams

    private let eventStream: AsyncStream<BackendEvent>
    let eventContinuation: AsyncStream<BackendEvent>.Continuation
    private let errorStream: AsyncStream<String>
    let errorContinuation: AsyncStream<String>.Continuation

    /// Init with config so the workspace count + per-WS layout come from the
    /// user's `[[desktop.N.section]]` blocks (names are auto-assigned). The
    /// (default = 5) fallback in FacetConfig keeps a vanilla
    /// `~/.config/facet/config.toml` usable out of the box.
    public init(config: FacetConfig) {
        self._config = config
        var ec: AsyncStream<BackendEvent>.Continuation!
        self.eventStream = AsyncStream { c in ec = c }
        self.eventContinuation = ec
        var errC: AsyncStream<String>.Continuation!
        self.errorStream = AsyncStream { c in errC = c }
        self.errorContinuation = errC

        // Seed the active mac desktop so the first refresh doesn't
        // spuriously swap. 0 (SkyLight unavailable) → single shared
        // catalog, never swaps.
        self.activeMacDesktopID = MacDesktops.activeID()
        self.activeMacDesktopOrdinal = MacDesktops.ordinal(for: activeMacDesktopID)

        Log.debug("native: init workspaces="
            + "\(config.effectiveWorkspaceList(forMacDesktopOrdinal: activeMacDesktopOrdinal).count) "
            + "desktop=\(activeMacDesktopID) ordinal=\(activeMacDesktopOrdinal.map(String.init) ?? "-") "
            + "desktopAware=\(MacDesktops.available)")

        // AX permission is the foundation of every native-backend
        // operation (focus, title resolution, window enumeration).
        // Routed through the shared `AXPermission` helper so the
        // hint reads identically wherever it surfaces.
        if let msg = AXPermission.errorMessageIfMissing() {
            DispatchQueue.main.async { [errorContinuation] in
                errorContinuation.yield(msg)
            }
        }

        // AX event subscription. start() must run on main; init
        // is not MainActor-isolated, so hop. Throughput: each
        // observed event yields a single refreshNeeded — Controller
        // already debounces, so a focus burst collapses into one
        // backend.workspaces() round-trip.
        //
        // A `.created` event additionally records the new window's id
        // as trusted (so `reconcile` fast-paths it past the two-tick
        // gate) and schedules ONE follow-up refresh ~250ms later: at
        // create time the window is often listed but transiently
        // `isOnscreen=false`, so the immediate (debounced) reconcile
        // can miss it; the follow-up catches it without waiting for
        // the 2s poll. The trusted record is enqueued on `cliQueue`
        // BEFORE the yield, so it's in place by the time the
        // debounced refresh's reconcile reads it (serial FIFO).
        let observer = WindowEventObserver { [weak self, eventContinuation] event in
            if case let .created(wid) = event, let self {
                let t0 = Date()
                cliQueue.async { self.trustedNew[wid] = t0 }
                Log.debug("native: window created wid=\(wid.serverID)"
                    + " -> trusted (fast-add)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    eventContinuation.yield(.refreshNeeded)
                }
            }
            if case .visibilityChanged = event {
                // Hide-reclaim fast path. The immediate refresh below
                // arms the hide (first of `reconcileHidden`'s two-tick
                // gate, which guards mac-desktop switch transients); this
                // follow-up confirms + detaches it ~0.3 s later instead
                // of waiting for the 2 s poll. A reveal is single-tick
                // (no gate) so for it the follow-up is just a harmless
                // re-check. Memory: `facet-hide-reclaim-decisions`.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    eventContinuation.yield(.refreshNeeded)
                }
            }
            eventContinuation.yield(.refreshNeeded)
        }
        self.eventObserver = observer
        DispatchQueue.main.async {
            MainActor.assumeIsolated { observer.start() }
        }

        // Phase δ: display reconfigure observer. Fires the
        // handler 0.5 s after the OS settles on a new layout
        // (debounce inside the observer). The closure is `@MainActor`,
        // so the handler starts on main only to snapshot the `NSScreen`
        // frames (main-only API); it then hands ALL catalog + AX work to
        // `cliQueue.async` — the single serialization point (P6). It does
        // NOT touch the catalog on main.
        let dObs = DisplayChangeObserver { [weak self] in
            self?.handleDisplayReconfigure()
        }
        self.displayObserver = dObs
        DispatchQueue.main.async {
            MainActor.assumeIsolated { dObs.start() }
        }

        // macOS mac-desktop switch observer. Nudges a refresh so
        // `refreshCatalog` re-reads the active mac desktop and
        // swaps to that mac desktop's catalog (per-mac-desktop WS,
        // memory `facet-per-native-space-ws`). The poll loop would
        // catch the switch within ~2 s anyway; this just makes it
        // immediate.
        let nc = NSWorkspace.shared.notificationCenter
        spaceChangeToken = nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self, eventContinuation] _ in
            MainActor.assumeIsolated {
                // After the mac-desktop transition settles (~500 ms
                // covers the swipe animation +
                // `kCGWindowIsOnscreen` flip), nudge focus onto a
                // managed window visible on the new mac desktop — but
                // only when the current frontmost isn't already
                // one of ours, so the user explicitly landing on
                // Finder / a non-managed app is left alone.
                // Handles the "switch back to mac desktop N, no window
                // focused" gap the user reported.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        self?.handleSpaceChangeAutoFocus()
                    }
                }
            }
            eventContinuation.yield(.refreshNeeded)
        }
    }

    /// See the comment on the mac-desktop-change observer in `init`.
    @MainActor
    private func handleSpaceChangeAutoFocus() {
        cliQueue.async { [weak self] in
            guard let self else { return }
            // Ensure we're looking at the destination mac desktop's
            // catalog even if the poll-driven refresh hasn't run
            // yet (both run on this serial queue, so this is safe).
            self.swapCatalogIfMacDesktopChanged()
            if let cur = self.focusedWindow(),
               self.catalog.windowMap[cur] != nil {
                return
            }
            let live = self.enumerateCGWindows()
            let visibleManaged = live.filter {
                $0.isOnscreen
                    && self.catalog.windowMap[$0.id] != nil
            }
            guard let pick = visibleManaged.predictedFocus()
            else { return }
            Log.debug("native: macDesktopChange autoFocus "
                + "pick=\(pick.id.serverID) app=\(pick.appName)")
            Focus.assert(pick, backend: self)
        }
    }

    /// Observer token for `NSWorkspace.activeSpaceDidChange`;
    /// retained so the observer survives init and is releasable.
    private var spaceChangeToken: NSObjectProtocol?

    public var events: AsyncStream<BackendEvent> { eventStream }
    public var errors: AsyncStream<String> { errorStream }

    /// P6: true while a cosmetic slide is in flight (see `slideInProgress`).
    /// Read on the main actor by `Controller.refresh` to skip a reconcile
    /// that would AX-fight the tween.
    public var isAnimating: Bool { slideInProgress }

    // MARK: - Commands

    /// EX-1 throughline: route a section activation to the right machinery.
    /// `.workspace` clears any active lens (exclusive model); `.lens` activates
    /// the cross-workspace union. Both delegate to existing methods that
    /// already `syncSectionLensMirror()`, so the mirror stays current.
    public func activateSection(_ section: ActiveSection, autoFocus: Bool) {
        dispatchPrecondition(condition: .onQueue(cliQueue))
        switch section {
        case .workspace(let n):
            // Exclusive model: activating a workspace clears any active lens.
            // `setActive(activeIndex)` is a no-op (guards `n1Based != activeIndex`)
            // so `switchWorkspace(sameIndex)` would NOT clear the lens — clear it
            // explicitly when the target IS the current workspace but a lens is set.
            if catalog.activeSectionLens != nil && n == catalog.activeIndex {
                setSectionLens(nil, autoFocus: autoFocus)
            } else {
                switchWorkspace(toIndex: n - 1, autoFocus: autoFocus)   // 1-based → 0-based
            }
        case .lens(let label):
            setSectionLens(label, autoFocus: autoFocus)
        }
    }

    public func switchWorkspace(toIndex index: Int, autoFocus: Bool) {
        // P6: the catalog is cliQueue-confined. Every caller dispatches on
        // cliQueue (DNC `runBackendCommand`, grid/rail/tree, runWindowOps);
        // fail fast if a future caller regresses to the main thread.
        dispatchPrecondition(condition: .onQueue(cliQueue))
        // No facet workspaces on an unmanaged mac desktop.
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        // Backend protocol convention is 0-based; catalog (matching
        // the user-facing CLI) is 1-based. Translate at the seam.
        let target = index + 1
        let rect = activeDisplayRect()
        // EX-0.4 (exclusive model): workspace switch always clears the active
        // section-lens — no D1 re-compose on the destination. `setActive`
        // handles the lift (restores lens-parked windows to their home layouts,
        // nulls activeSectionLens + activeSectionLensLayout) and returns the
        // unconditional restore plan for the destination's own members.
        guard let plan = catalog.setActive(target, in: rect) else { return }

        // Leave-snapshot only fires on a real transition: setActive
        // already returned nil for the no-op `target == activeIndex`
        // case, so we'd otherwise be writing the *current* focused
        // window into `currentWS`'s slot and clobber the real
        // "last time we left here" value.
        if let cur = focusedWindow() {
            catalog.recordLeaveFocus(cur, in: plan.oldActive)
        }
        // The lens-park set + activeSectionLens just changed (cleared by
        // setActive) — keep the main-readable mirror in lock-step for read-back.
        syncSectionLensMirror()
        Log.debug("native: switchWorkspace \(plan.oldActive) -> "
            + "\(plan.newActive) autoFocus=\(autoFocus)")
        // Consume the relative-switch direction hint (set just before by
        // switchWorkspaceRelative) regardless of whether we animate, so
        // it never leaks into a later switch.
        let hint = slideDirectionHint
        slideDirectionHint = nil

        // 枠 E Phase 1: animate the switch as a directional slide. The
        // animated path owns its own settle (anchor park + tile +
        // auto-focus + refresh) on completion, so we return early.
        if config.effectiveAnimationsEnabled,
           plan.newActive != plan.oldActive,
           animateSwitch(toPark: plan.toPark, toRestore: plan.toRestore,
                         oldActive: plan.oldActive, newActive: plan.newActive,
                         directionHint: hint, rect: rect, autoFocus: autoFocus) {
            return
        }

        applyHide(toPark: plan.toPark, toRestore: plan.toRestore)
        // Phase γ: overlay layout-specific frames on top of the
        // anchor restore. Floating windows in the same WS keep the
        // restoreAnchor position; tiled / stacked windows snap to
        // their computed frame.
        applyLayout(workspace: plan.newActive, rect: rect)

        // 2-a / 2-b: no-pick callers (CLI --workspace, sidebar
        // header click, grid workspace cell click) opt in to
        // auto-focus the destination's last-touched window — or
        // deactivate the source app when the destination is
        // empty.
        if autoFocus {
            applyAutoFocus(newActiveWS: plan.newActive)
        }

        eventContinuation.yield(.refreshNeeded)
    }

    public func switchWorkspaceRelative(_ target: RelativeWorkspace,
                                        autoFocus: Bool) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        guard let t = catalog.relativeTarget(target) else {
            Log.debug("native: switchWorkspaceRelative \(target) → no-op")
            return
        }
        // Slide the intuitive way for next/prev even across the wrap
        // edge; `recent` has no inherent direction, so leave it to the
        // index delta.
        switch target {
        case .next: slideDirectionHint = 1
        case .prev: slideDirectionHint = -1
        case .recent: slideDirectionHint = nil
        }
        switchWorkspace(toIndex: t - 1, autoFocus: autoFocus)
    }

    /// Focus the window the user was last on in `newActiveWS`, or
    /// — when the WS has no windows — bounce focus to Finder so
    /// the source app doesn't linger as frontmost. Window pick
    /// goes through `WorkspaceCatalog.autoFocusTarget`, which
    /// matches the same pred chain the sidebar's optimistic
    /// highlight uses (memory `facet-ws-switch-focus-management`).
    func applyAutoFocus(newActiveWS: Int) {
        let wsWindows = enumerateCGWindows().filter {
            catalog.windowMap[$0.id]?.workspace == newActiveWS
                // Section-lens (Phase 1): a window the active lens parked is
                // off-screen — never auto-focus it. Empty set in the no-lens
                // case, so this is a no-op there.
                && !catalog.lensParkedMembers.contains($0.id)
        }
        guard let pick = catalog.autoFocusTarget(
                in: newActiveWS, windows: wsWindows)
        else {
            activateFinder()
            return
        }
        Log.debug("native: autoFocus WS=\(newActiveWS) "
            + "pick=\(pick.id.serverID) app=\(pick.appName)")
        Focus.assert(pick, backend: self)
    }

    // MARK: - Section-lens (tag-unification Phase 1)

    /// Activate / clear the active section-lens (`type="lens"` section, by
    /// `label`): resolve the label → the section's `match`, evaluate it across ALL
    /// workspaces on the current mac desktop (`sectionLensVisibleIDsAll`),
    /// park out-of-lens windows everywhere, and gather the cross-workspace
    /// union for tiling. `nil` clears the lens (restores every parked window).
    /// No-op outside the section model; an unknown label or malformed `match`
    /// is a loud-but-non-fatal operational error (the lens is left unchanged,
    /// D2). The catalog (`activeSectionLens`) is the authority; the
    /// main-readable mirror is synced so the view's highlight reads back.
    public func setSectionLens(_ label: String?, autoFocus: Bool) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal),
              config.isSectionModelActive(ordinal: activeMacDesktopOrdinal)
        else { return }
        let rect = activeDisplayRect()

        // Clear.
        guard let label else {
            guard catalog.activeSectionLens != nil else { return }
            let plan = catalog.clearSectionLens(in: rect)
            sectionLensCompiled = nil
            syncSectionLensMirror()
            Log.debug("native: setSectionLens cleared "
                + "(restored=\(plan.toRestore.count))")
            applyHide(toPark: plan.toPark, toRestore: plan.toRestore)
            applyLayout(workspace: catalog.activeIndex, rect: rect)
            eventContinuation.yield(.refreshNeeded)
            return
        }

        // Activate. Validate the label → resolve + compile its `match`. D2:
        // an unknown label or a `match` that won't parse rejects LOUD (the
        // lens is left unchanged — no park decision without a sound filter).
        guard let ord = activeMacDesktopOrdinal,
              let section = config.effectiveMacDesktopSectionConfigs[ord]?
                .first(where: { $0.type == .lens && $0.label == label })
        else {
            errorContinuation.yield("lens \(label): no such lens section")
            return
        }
        guard case .success = FacetFilter.parse(section.match) else {
            errorContinuation.yield("lens \(label): malformed match")
            return
        }
        catalog.activeSectionLens = label
        catalog.activeSectionLensLayout = nil   // EX-0.3: freshly-activated lens starts from config layout
        sectionLensCompiled = nil   // recompile against the (possibly new) match
        syncSectionLensMirror()
        let live = enumerateCGWindows()
        // EX-0.1: evaluate cross-workspace so windows in INACTIVE workspaces
        // that match the lens are gathered (not mis-parked). A per-WS evaluator
        // (removed in EX-0.4) only passed windows whose home WS == activeIndex,
        // so matching inactive-WS windows were absent from the visible set and
        // incorrectly parked. See SectionLensGatherTests for the regression pin.
        let visible = sectionLensVisibleIDsAll(live: live) ?? []
        let plan = catalog.applySectionLens(visibleIDs: visible, in: rect)
        Log.debug("native: setSectionLens \"\(label)\" "
            + "visible=\(visible.count) parked=\(plan.toPark.count) "
            + "restored=\(plan.toRestore.count)")
        applyHide(toPark: plan.toPark, toRestore: plan.toRestore)
        applyLayout(workspace: catalog.activeIndex, rect: rect)
        if autoFocus { applySectionLensAutoFocus(visibleIDs: visible) }
        eventContinuation.yield(.refreshNeeded)
    }

    /// Auto-focus after a section-lens change. Keep the current focus when its
    /// window stays visible (passes the lens, or is sticky — never parked) so
    /// activating a lens that still shows the focused window doesn't yank
    /// focus; otherwise focus the first in-lens window, or defocus to Finder
    /// when the lens selects nothing (D2: an empty workspace is allowed).
    /// Internal so the continuous re-park can reuse it. `visibleIDs` is the
    /// cross-workspace in-lens id set; the focus pick may target a window whose
    /// home workspace is inactive — intended, because the union has already been
    /// tiled on-screen before focus fires.
    func applySectionLensAutoFocus(visibleIDs: Set<WindowID>) {
        if let cur = focusedWindow(), let slot = catalog.windowMap[cur],
           slot.workspace == catalog.activeIndex {
            let staysVisible = visibleIDs.contains(cur)
                || catalog.everywhereWindows.contains(cur)
            if staysVisible { return }
        }
        let live = enumerateCGWindows()
        guard let pick = live.first(where: {
            visibleIDs.contains($0.id)
                && !catalog.floatingWindows.contains($0.id)
        }) ?? live.first(where: { visibleIDs.contains($0.id) })
        else {
            activateFinder()
            return
        }
        Log.debug("native: section-lens autoFocus pick=\(pick.id.serverID) "
            + "app=\(pick.appName)")
        Focus.assert(pick, backend: self)
    }

    /// 2-b defocus: when the destination WS is empty, push the
    /// frontmost-app crown to Finder. Public API only — facet
    /// stays inside the macOS sandbox ([[facet-buddha-palm-principle]]).
    /// Finder is always running; the menu bar swapping to it is
    /// the user-visible "this WS is empty" signal.
    func activateFinder() {
        let finders = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder")
        guard let finder = finders.first else {
            Log.debug("native: autoFocus defocus skipped "
                + "(Finder not running, unexpected)")
            return
        }
        finder.activate()
        Log.debug("native: autoFocus defocus -> Finder")
    }

    public func moveWindow(_ id: WindowID, toWorkspaceIndex index: Int) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        let target = index + 1
        let rect = activeDisplayRect()
        let outcome = catalog.moveWindow(id, to: target, in: rect)
        switch outcome {
        case .rejected:
            return
        case .stateOnly:
            Log.debug("native: moveWindow \(id.serverID) -> WS "
                + "\(target) outcome=stateOnly")
        case .park(let ref):
            Log.debug("native: moveWindow \(id.serverID) -> WS "
                + "\(target) outcome=park")
            applyHide(toPark: [ref], toRestore: [])
        case .restore(let ref):
            Log.debug("native: moveWindow \(id.serverID) -> WS "
                + "\(target) outcome=restore")
            applyHide(toPark: [], toRestore: [ref])
        }
        // Layout changed for source AND/OR destination — re-apply
        // the active WS if its mode produces an on-screen layout.
        // Inactive WSs catch up on their next switchWorkspace
        // (Phase γ: lazy retile / re-stack). 枠 E: the remaining
        // windows animate as they reflow to fill the moved window's
        // slot (the moved window itself already parked off-screen).
        reflowActive(rect: rect)
    }

    /// EX-3: relocate `id` OUT of its workspace → 迷子 (mirrors `moveWindow`'s
    /// outcome handling). A section DnD's ws→lens MOVE routes here (instead of
    /// `moveWindow`) so the window leaves its workspace. If a lens that matches
    /// the window is active, the trailing reconcile (`applySectionLensReconcile`)
    /// re-shows it in the union; otherwise it stays parked (invisible 迷子). The
    /// loud `Log.line` makes the orphaning visible (canon ⑧ invisible-but-logged).
    public func orphanWindow(_ id: WindowID) {
        dispatchPrecondition(condition: .onQueue(cliQueue))   // P6
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        let rect = activeDisplayRect()
        let outcome = catalog.setOrphan(id)
        switch outcome {
        case .rejected:
            return
        case .stateOnly:
            Log.line("native: orphan \(id.serverID) — left its workspace "
                + "(迷子); invisible unless a 迷子 receptacle lens is active")
        case .park(let ref):
            Log.line("native: orphan \(id.serverID) — left its workspace "
                + "(迷子); parked")
            applyHide(toPark: [ref], toRestore: [])
        case .restore:
            break   // setOrphan never returns .restore
        }
        reflowActive(rect: rect)
    }

}
