// `WindowBackend` conformance using only AX + public macOS APIs
// (no `rift-cli`, no private-API injection). This file is the
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
//   δ (pending) — display reconfigure handling, geometry persistence
//   ε (pending) — `FacetAdapterRift` deprecation
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
    /// geometry but still tracks them / parks on Space switch). The
    /// CLI's `canonicalLayoutModes` already lists it; advertise it
    /// here too so it appears in the right-click picker.
    public let layoutModes = ["bsp", "stack", "float"] + LayoutRegistry.names

    // MARK: - State (delegated to catalog)

    /// Self-managed workspace state for the **currently active**
    /// native macOS Space. All mutations go through here so the
    /// state machine stays pure and testable; this file only
    /// applies the AX side-effects the catalog hands back.
    private var catalog = WorkspaceCatalog()

    /// Per-native-Space catalogs that aren't currently active.
    /// facet keeps an independent set of virtual workspaces per
    /// native macOS Space (memory: facet-per-native-space-ws). On a
    /// Space switch the active `catalog` is parked here under its
    /// Space id and the destination Space's catalog is swapped in
    /// (lazily created on first visit). Window state is session-only
    /// (facet never persists), so on restart each Space's catalog
    /// rebuilds from its live windows.
    private var parkedCatalogs: [UInt64: WorkspaceCatalog] = [:]

    /// SkyLight id of the native Space `catalog` belongs to. `0`
    /// when SkyLight is unavailable — then facet runs a single
    /// shared catalog (pre-per-Space behaviour) and never swaps.
    private var activeSpaceID: UInt64 = 0

    /// 1-based Mission-Control ordinal of the active native Space
    /// (user Spaces only). Selects the `[space.N]` workspace config;
    /// `nil` → fall back to the global `[workspace]`. Refreshed on
    /// every Space swap. May briefly go stale if the user reorders
    /// Spaces in Mission Control without switching — a cosmetic
    /// name/count mismatch only (memory: facet-per-native-space-ws).
    private var activeSpaceOrdinal: Int?

    /// Snapshot of the last `workspaces()` build, returned as-is on
    /// the next call. Rebuilt every `refreshCatalog()` invocation.
    private var workspaceList: [Workspace] = []

    /// Held so `refreshCatalog` can read the configured workspace
    /// list each tick. Note: this captures the config at adapter
    /// init time; `Controller.reloadConfig()` re-reads
    /// `config.toml` but does NOT push the fresh value back to
    /// the adapter, so `[workspace]` table edits during a session
    /// take effect only on restart. Wiring a config-push channel
    /// is a known follow-up.
    private let config: FacetConfig

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

    // MARK: - Event / error streams

    private let eventStream: AsyncStream<BackendEvent>
    private let eventContinuation: AsyncStream<BackendEvent>.Continuation
    private let errorStream: AsyncStream<String>
    private let errorContinuation: AsyncStream<String>.Continuation

    /// Init with config so workspace count + names come from the
    /// user's `[workspace]` section. The (default = 5) fallback in
    /// FacetConfig keeps a vanilla `~/.config/facet/config.toml`
    /// usable out of the box.
    public init(config: FacetConfig) {
        self.config = config
        var ec: AsyncStream<BackendEvent>.Continuation!
        self.eventStream = AsyncStream { c in ec = c }
        self.eventContinuation = ec
        var errC: AsyncStream<String>.Continuation!
        self.errorStream = AsyncStream { c in errC = c }
        self.errorContinuation = errC

        // Seed the active native Space so the first refresh doesn't
        // spuriously swap. 0 (SkyLight unavailable) → single shared
        // catalog, never swaps.
        self.activeSpaceID = Spaces.activeSpaceID()
        self.activeSpaceOrdinal = Spaces.activeSpaceOrdinal(for: activeSpaceID)

        Log.debug("native: init workspaces="
            + "\(config.effectiveWorkspaceList(forSpaceOrdinal: activeSpaceOrdinal).count) "
            + "space=\(activeSpaceID) ordinal=\(activeSpaceOrdinal.map(String.init) ?? "-") "
            + "spaceAware=\(Spaces.available)")

        // AX permission is the foundation of every native-backend
        // operation (focus, title resolution, window enumeration).
        // Same surface as RiftAdapter so the user sees the same
        // hint regardless of which backend is active.
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
            eventContinuation.yield(.refreshNeeded)
        }
        self.eventObserver = observer
        DispatchQueue.main.async {
            MainActor.assumeIsolated { observer.start() }
        }

        // Phase δ: display reconfigure observer. Fires the
        // handler 0.5 s after the OS settles on a new layout
        // (debounce inside the observer). Handler runs on main
        // (the closure is `@MainActor`); it touches AX + the
        // catalog, both of which the rest of NativeAdapter
        // already manipulates from main paths.
        let dObs = DisplayChangeObserver { [weak self] in
            self?.handleDisplayReconfigure()
        }
        self.displayObserver = dObs
        DispatchQueue.main.async {
            MainActor.assumeIsolated { dObs.start() }
        }

        // macOS Space switch observer. Nudges a refresh so
        // `refreshCatalog` re-reads the active native Space and
        // swaps to that Space's catalog (per-native-Space WS,
        // memory `facet-per-native-space-ws`). The poll loop would
        // catch the switch within ~2 s anyway; this just makes it
        // immediate.
        let nc = NSWorkspace.shared.notificationCenter
        spaceChangeToken = nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self, eventContinuation] _ in
            MainActor.assumeIsolated {
                // After the Space transition settles (~500 ms
                // covers the swipe animation +
                // `kCGWindowIsOnscreen` flip), nudge focus onto a
                // managed window visible on the new Space — but
                // only when the current frontmost isn't already
                // one of ours, so the user explicitly landing on
                // Finder / a non-managed app is left alone.
                // Handles the "switch back to Space N, no window
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

    /// See the comment on the Space-change observer in `init`.
    @MainActor
    private func handleSpaceChangeAutoFocus() {
        cliQueue.async { [weak self] in
            guard let self else { return }
            // Ensure we're looking at the destination Space's
            // catalog even if the poll-driven refresh hasn't run
            // yet (both run on this serial queue, so this is safe).
            self.swapCatalogIfSpaceChanged()
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
            Log.debug("native: spaceChange autoFocus "
                + "pick=\(pick.id.serverID) app=\(pick.appName)")
            Focus.assert(pick, backend: self)
        }
    }

    /// Observer token for `NSWorkspace.activeSpaceDidChange`;
    /// retained so the observer survives init and is releasable.
    private var spaceChangeToken: NSObjectProtocol?

    public var events: AsyncStream<BackendEvent> { eventStream }
    public var errors: AsyncStream<String> { errorStream }

    // MARK: - Queries

    public func workspaces() -> [Workspace] {
        refreshCatalog()
        return workspaceList
    }

    /// Refresh the cached snapshot. Re-enumerates CGWindowList,
    /// asks the catalog to reconcile against the live list (which
    /// also records each window's owning pid for later AX calls
    /// and threads new windows into the BSP tree of the active
    /// WS when that WS is in `"bsp"` mode), and builds the
    /// `[Workspace]` snapshot through the catalog.
    ///
    /// Lazy retile (Phase γ frozen): if `reconcile` added or
    /// removed any window AND the active WS is in `"bsp"` mode,
    /// re-apply tile frames so the on-screen layout matches the
    /// new tree. Pure UI / mode flips don't trigger AX writes
    /// here — they go through `switchWorkspace` /
    /// `setLayoutMode` / `perform`.
    private func refreshCatalog() {
        // Per-native-Space: if the user switched native macOS Spaces,
        // park the current catalog and swap in the destination
        // Space's. Done here (off-main, same context as every other
        // catalog mutation) rather than from the main-thread Space
        // observer, so catalog access stays single-threaded.
        swapCatalogIfSpaceChanged()
        // Unmanaged native desktop (no `[space.N]` in opt-in mode):
        // facet stays completely hands-off — adopt no windows, park
        // nothing, and return an empty workspace list so the
        // Controller hides the panel (its empty-list guard in
        // `apply`). Windows on the desktop are left exactly as the
        // user arranged them.
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal) else {
            if !workspaceList.isEmpty {
                Log.debug("native: desktop ordinal="
                    + "\(activeSpaceOrdinal.map(String.init) ?? "-") "
                    + "unmanaged -> hands-off, panel hidden")
            }
            workspaceList = []
            return
        }
        // Seed the per-WS default layout mode from config (`[layout]
        // default`). Layout mode is otherwise session-only, so without
        // this every restart / per-native-Space catalog resets to the
        // hardcoded "float" and the user's windows stop tiling until
        // they re-issue `facet workspace --layout=…`. Set every refresh
        // (cheap, value-type field) so a config hot-reload takes too.
        catalog.defaultMode = config.effectiveDefaultLayout
        // Seed the live workspace set from config the first time this
        // (per-Space) catalog is used. Idempotent — once seeded, the
        // catalog's set is authoritative and runtime add/remove/rename/
        // move own it (config stays the read-only seed).
        catalog.seed(names: config.effectiveWorkspaceList(
            forSpaceOrdinal: activeSpaceOrdinal))
        let live = enumerateCGWindows()
        let focused = focusedWindow()
        let rect = activeDisplayRect()
        // Phase γ.3 + F: classify first-sight windows — auto-float
        // (sheets / dialogs / palettes + config float rules) and
        // ignore (config `action="ignore"` → kept fully unmanaged).
        let (autoFloat, ignore) = classifyNewWindows(live: live)
        // Drop expired trusted-new hints, then hand the survivors to
        // reconcile so a genuinely-new window joins on first on-screen
        // sight (skips the two-tick gate). Non-trusted windows — incl.
        // Space-switch `isOnscreen` flips of existing windows — still
        // go through the gate, so its flip protection is intact.
        let nowDate = Date()
        trustedNew = trustedNew.filter {
            nowDate.timeIntervalSince($0.value) < trustedNewTTL
        }
        let trusted = Set(trustedNew.keys)
        let result = catalog.reconcile(live: live,
                                       focused: focused,
                                       activeRect: rect,
                                       autoFloat: autoFloat,
                                       trusted: trusted,
                                       ignore: ignore,
                                       requireConfirm: true)
        // Latency telemetry + consume: any trusted id now in the
        // catalog was fast-added — log create→add dt and forget the
        // hint so it can't act again.
        for id in trusted where catalog.windowMap[id] != nil {
            if let t0 = trustedNew.removeValue(forKey: id) {
                let dt = Int(Date().timeIntervalSince(t0) * 1000)
                Log.debug("native: fast-add wid=\(id.serverID) dt=\(dt)ms")
            }
        }
        if result.added > 0 || result.removed > 0 {
            Log.debug("native: refreshCatalog "
                + "added=\(result.added) removed=\(result.removed) "
                + "total=\(live.count)")
        }
        if result.removed > 0 { recentCloseAt = Date() }
        // Heal (native-Space drift): a window can leak into this
        // catalog's WS when it was swept in during a native macOS
        // Space switch (the destination Space's windows flip
        // `isOnscreen=true` before `swapCatalogIfSpaceChanged` sees
        // the new active-Space id, so the two-tick gate adds them to
        // the wrong catalog). Prevention is racy and トミー accepts the
        // leak; instead we recompute hard here. Read each managed
        // window's TRUE native Space (read-only SkyLight) and evict any
        // that isn't on the active Space — it'll be re-adopted by its
        // real Space's catalog on visit. Only runs when SkyLight is
        // live (`activeSpaceID != 0`); an empty query result leaves the
        // window untouched, so a transient SkyLight miss can't evict a
        // real window. Must run BEFORE applyLayout / snapshot so both
        // the tiling and the tree reflect the cleaned membership.
        if activeSpaceID != 0 {
            // Cache each window's Space query for this reconcile (the
            // sanity gate + the eviction filter would otherwise double-
            // query the on-screen windows).
            var spaceCache: [WindowID: [UInt64]] = [:]
            func windowSpaces(_ id: WindowID) -> [UInt64] {
                if let c = spaceCache[id] { return c }
                let s = Spaces.spaces(forWindow: id.serverID)
                spaceCache[id] = s
                return s
            }
            // Sanity gate: an on-screen managed window is, by
            // definition, on the active Space right now — so if the
            // SLS query is sound, at least one must report it. If NONE
            // do, the query is untrustworthy (selector / id-format
            // drift across an OS update) and evicting on its word could
            // wrongly remove every real window. Bail in that case —
            // a no-op heal is harmless; a false mass-eviction is not.
            let trustworthy = live.contains { w in
                w.isOnscreen && catalog.windowMap[w.id] != nil
                    && windowSpaces(w.id).contains(activeSpaceID)
            }
            if trustworthy {
                let foreign = catalog.windowMap.keys.filter { id in
                    let s = windowSpaces(id)
                    return !s.isEmpty && !s.contains(activeSpaceID)
                }
                for id in foreign { catalog.drop(id) }
                if !foreign.isEmpty {
                    Log.debug("native: heal evicted \(foreign.count) "
                        + "off-Space window(s) from space=\(activeSpaceID)")
                }
            } else if !catalog.windowMap.isEmpty {
                Log.debug("native: heal skipped "
                    + "(SLS space query untrustworthy, space=\(activeSpaceID))")
            }
        }
        // D (event-driven re-tile): re-tile the active WS on every
        // refresh, not only when windows were added/removed. Cheap
        // when nothing drifted (applyFrames' frame-match skip reads
        // only, no AX write) and self-heals geometry after a native
        // WS switch / resize / external nudge that the old lazy
        // retile (add/remove only) missed. float WS is a no-op (no
        // engine). Supersedes the Phase γ lazy-retile invariant.
        applyLayout(workspace: catalog.activeIndex, rect: rect)
        // Post-close focus redirect. When a managed window closes
        // (Cmd+W, app quit), macOS hands focus to the next
        // z-ordered window of the same app, which often sits in a
        // DIFFERENT facet WS — the user sees the wrong window flash
        // selected. We compute the focus the sidebar should SHOW
        // (= a visible window in the active WS) and feed THAT to
        // the snapshot, so the highlight never lands on the
        // wrong-WS window even for a frame. `Focus.assert` then
        // makes the AX reality catch up. See memory
        // `facet-ws-switch-focus-management`.
        let displayFocus = redirectedFocus(live: live, axFocus: focused)
        workspaceList = catalog.snapshot(
            live: live,
            focused: displayFocus,
            activeRect: rect)
        // Bootstrap snapshot: lock OFF-SCREEN pre-existing
        // windows (Cmd+H'd apps, windows on other macOS Spaces,
        // minimized windows) as examined so a later
        // `isOnscreen` flip doesn't sweep them into
        // `activeIndex`. On-screen windows are intentionally
        // skipped — they go through the catalog's 2-tick
        // confirmation gate and join `windowMap` normally.
        if !didBootstrap {
            didBootstrap = true
            catalog.markPreExisting(
                live.lazy.filter { !$0.isOnscreen }.map(\.id))
        }
    }

    /// Park the active Space's catalog and swap in the destination
    /// Space's (lazily created) when the user has switched native
    /// macOS Spaces. No-op when SkyLight is unavailable
    /// (`activeSpaceID` stays 0 → one shared catalog) or the Space
    /// is unchanged. Called only from `refreshCatalog` so all
    /// catalog access stays on a single thread. The destination
    /// Space's windows are picked up by the normal reconcile that
    /// follows (its on-screen windows enter that catalog's WS1);
    /// other Spaces' windows read `isOnscreen=false` and are
    /// ignored, so no cross-Space leakage occurs.
    private func swapCatalogIfSpaceChanged() {
        let live = Spaces.activeSpaceID()
        guard live != 0, live != activeSpaceID else { return }
        parkedCatalogs[activeSpaceID] = catalog
        let restored = parkedCatalogs.removeValue(forKey: live)
        catalog = restored ?? WorkspaceCatalog()
        activeSpaceID = live
        activeSpaceOrdinal = Spaces.activeSpaceOrdinal(for: live)
        Log.debug("native: native-space -> \(live) "
            + "ordinal=\(activeSpaceOrdinal.map(String.init) ?? "-") "
            + "(\(restored == nil ? "fresh" : "restored"), "
            + "parked=\(parkedCatalogs.count))")
    }
    /// Cleared after the first successful `refreshCatalog`. Used
    /// to bulk-mark the initial CGWindowList as pre-existing so
    /// off-screen windows alive at launch can't sneak in later.
    private var didBootstrap = false
    /// Last time a managed window vanished (Cmd+W, app quit).
    /// Bounds the post-close redirect so it only kicks in right
    /// after a close — Cmd+Tab and other deliberate focus moves
    /// outside this window are left untouched.
    private var recentCloseAt: Date?
    /// How long after a close the redirect stays armed. Long
    /// enough to cover the AX-event + reconcile settling, short
    /// enough not to hijack the user's next deliberate action.
    private let closeFocusWindow: TimeInterval = 0.6

    /// CGWindowIDs of windows that fired `kAXWindowCreated`, mapped
    /// to the create timestamp. A genuinely-new window can't be a
    /// Space-switch `isOnscreen` flip of an existing one, so
    /// `reconcile` adds these on first on-screen sight — skipping the
    /// two-tick gate that otherwise costs up to one ~2s poll. Touched
    /// only on `cliQueue` (write from the observer closure's
    /// `cliQueue.async`, drain in `refreshCatalog`, both serial) so no
    /// lock is needed. Entries are consumed on add and expire after
    /// `trustedNewTTL` (e.g. a transient window that closed before it
    /// ever became on-screen).
    private var trustedNew: [WindowID: Date] = [:]
    /// Upper bound a trusted-new hint lives before it's discarded if
    /// the window never materialised on-screen. ~matches the poll
    /// cadence — long enough for the create→settle transient, short
    /// enough that a stale hint can't fast-add much later.
    private let trustedNewTTL: TimeInterval = 2.0

    /// What the sidebar should show as focused. Normally the AX
    /// frontmost (`axFocus`). But within `closeFocusWindow` after
    /// a managed window closed, if the AX frontmost drifted to a
    /// window OUTSIDE the active WS, returns the active WS's
    /// would-be focus instead — and fires `Focus.assert` so the
    /// real AX state catches up. Feeding this to `snapshot` means
    /// the highlight lands on the right window from the first
    /// frame, with no wrong-WS flash. Empty active WS → bounce
    /// to Finder (matches the WS-switch defocus, memory
    /// `facet-ws-switch-focus-management`).
    private func redirectedFocus(live: [Window],
                                 axFocus: WindowID?) -> WindowID? {
        let armed = recentCloseAt.map {
            Date().timeIntervalSince($0) < closeFocusWindow
        } ?? false
        guard armed else { return axFocus }
        // Already on an active-WS window → nothing to redirect.
        if let f = axFocus,
           catalog.windowMap[f]?.workspace == catalog.activeIndex {
            return axFocus
        }
        let visibleActive = live.filter { w in
            catalog.windowMap[w.id]?.workspace == catalog.activeIndex
                && w.isOnscreen
        }
        guard let pick = catalog.autoFocusTarget(
                in: catalog.activeIndex, windows: visibleActive)
        else {
            activateFinder()
            return axFocus
        }
        Log.debug("native: post-close redirect "
            + "pick=\(pick.id.serverID) app=\(pick.appName)")
        Focus.assert(pick, backend: self)
        return pick.id
    }

    /// Cap on `detectAutoFloating`'s per-refresh AX probes. The
    /// role check costs ~3 AX round-trips per window (window
    /// lookup + role + subrole), and each round-trip has a
    /// default 6s timeout — a 100-window startup with one busy
    /// app could otherwise stall reconcile for minutes. Beyond
    /// the cap, new windows simply enter the tiler without the
    /// auto-float hint; the user can `--toggle-float` them
    /// manually. Tuned so a normal session start (≤16 new
    /// windows per refresh tick) is fully covered.
    private let maxAutoFloatProbes = 16

    /// pid → bundle id cache. Bundle id is stable for a process's
    /// lifetime, so resolve once via `NSRunningApplication` and reuse.
    /// Only failures are left uncached (so a later tick can retry an
    /// app that wasn't ready). Touched only on `cliQueue`
    /// (`enumerateCGWindows`), like the rest of the catalog state.
    private var pidToBundleId: [pid_t: String] = [:]

    private func bundleId(forPid pid: Int) -> String? {
        let p = pid_t(pid)
        if let cached = pidToBundleId[p] { return cached }
        guard let b = NSRunningApplication(processIdentifier: p)?
            .bundleIdentifier else { return nil }
        pidToBundleId[p] = b
        return b
    }

    /// Phase γ.3 + window-exclusion (F): classify not-yet-managed
    /// windows on first sight into the ones to auto-float vs. ignore.
    ///
    /// - **Built-in role auto-float**: sheets / dialogs / palettes by
    ///   AX role (`AXGeom.isFloatingByRole`) — kept tracked but not
    ///   tiled.
    /// - **Config `[[exclude]]` rules**: `action="float"` joins the
    ///   auto-float set; `action="ignore"` is dropped entirely (never
    ///   managed). Config rules take **precedence** over the built-in
    ///   heuristic (explicit user intent wins).
    ///
    /// Allowlist gate (yabai / AeroSpace style): a window is TILED only
    /// when it's positively confirmed a standard window; everything else
    /// is floated (tracked + shown, not tiled) or ignored (dropped).
    /// Two signals, cheapest first:
    ///   1. window-server level (SkyLight read, no AX) — a raised level
    ///      (tool-tip / pop-up / menu) is ignored without an AX probe.
    ///   2. AX role/subrole (probed, capped at `maxAutoFloatProbes`) —
    ///      `AXWindow`+`AXStandardWindow` tiles; sheets / dialogs /
    ///      palettes and `AXWindow`+non-standard subrole (e.g.
    ///      `AXUnknown`) float; a non-window role (AXHelpTag / menu /
    ///      popover) is ignored. An un-probed/un-probeable normal-level
    ///      window leans MANAGED — junk is almost always raised-level
    ///      (caught by 1 without a probe), so a bare normal-level window
    ///      is most likely real; tiling it beats risking a real window
    ///      vanishing from the layout.
    /// User `[[exclude]]` rules win over the heuristic (incl. the
    /// `manage` force-tile escape hatch). Only unseen + unexamined
    /// windows are classified. Tile-eligible windows are left out of
    /// both returned sets so `reconcile` manages them normally.
    private func classifyNewWindows(live: [Window])
        -> (autoFloat: Set<WindowID>, ignore: Set<WindowID>)
    {
        let rules = config.effectiveExclusionRules
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        var autoFloat: Set<WindowID> = []
        var ignore: Set<WindowID> = []
        var probed = 0
        for w in live
        where catalog.windowMap[w.id] == nil
            && !catalog.examinedIDs.contains(w.id)
        {
            // 1. Cheap level gate (SkyLight read, no AX). nil = SkyLight
            //    down → unknown; defer to the AX gate rather than
            //    excluding on a missing signal.
            let level = Spaces.windowLevel(forWindow: w.id.serverID)
            let normalOrUnknownLevel = (level == nil) || (level == normalLevel)

            // AX role/subrole — probe only windows that could still tile
            // (normal/unknown level), within the per-call cap.
            var ax: AXUIElement?
            var role: String?
            var subrole: String?
            if normalOrUnknownLevel, probed < maxAutoFloatProbes {
                probed += 1
                ax = AXGeom.window(for: CGWindowID(w.id.serverID),
                                   pid: pid_t(w.pid))
                if let ax {
                    role = AXGeom.role(ax)
                    subrole = AXGeom.subrole(ax)
                }
            }

            // 2. User `[[exclude]]` rules win over the heuristic.
            let probe = WindowProbe(bundleId: w.bundleId, title: w.title,
                                    role: role, subrole: subrole,
                                    size: w.frame?.size)
            switch rules.action(for: probe) {
            case .manage:
                Log.debug("native: rule=manage wsid=\(w.id.serverID) "
                    + "app=\(w.appName)")
                continue                          // force-tile
            case .ignore:
                ignore.insert(w.id)
                Log.debug("native: exclude=ignore wsid=\(w.id.serverID) "
                    + "app=\(w.appName)")
                continue
            case .float:
                autoFloat.insert(w.id)
                Log.debug("native: exclude=float wsid=\(w.id.serverID) "
                    + "app=\(w.appName)")
                continue
            case nil:
                break
            }

            // 3. Level gate verdict: raised level → never tiled.
            if let level, level != normalLevel {
                ignore.insert(w.id)
                Log.debug("native: gate=ignore(level=\(level)) "
                    + "wsid=\(w.id.serverID) app=\(w.appName)")
                continue
            }

            // 4. Allowlist gate on AX role/subrole.
            if role == "AXWindow", subrole == "AXStandardWindow" {
                // yabai/rift `window_can_move`: a standard window AX
                // won't let us reposition can't be tiled (we'd hand it
                // a slot it can't fill) → float it instead of tiling.
                if let ax, !AXGeom.canMove(ax) {
                    autoFloat.insert(w.id)
                    Log.debug("native: gate=float(immovable) "
                        + "wsid=\(w.id.serverID) app=\(w.appName)")
                    continue
                }
                continue                          // tile (managed by reconcile)
            }
            if let ax, AXGeom.isFloatingByRole(ax) {
                autoFloat.insert(w.id)            // sheet / dialog / palette
                Log.debug("native: gate=float(role) wsid=\(w.id.serverID) "
                    + "app=\(w.appName)")
                continue
            }
            if role == "AXWindow" {
                // AXWindow with a non-standard subrole (e.g. AXUnknown):
                // conservative — show it, don't tile.
                autoFloat.insert(w.id)
                Log.debug("native: gate=float(nonstd sub=\(subrole ?? "-")) "
                    + "wsid=\(w.id.serverID) app=\(w.appName)")
                continue
            }
            if role == nil {
                continue                          // un-probed normal-level → tile
            }
            // A definite non-window role (AXHelpTag / menu / popover …).
            ignore.insert(w.id)
            Log.debug("native: gate=ignore(role=\(role ?? "-")) "
                + "wsid=\(w.id.serverID) app=\(w.appName)")
        }
        return (autoFloat, ignore)
    }

    /// Display rect to anchor tile / stack math against.
    /// Determined by the focused window's centre point (or the
    /// origin when nothing is focused — startup, mid-switch).
    /// Always returns `Displays.visibleFrame` (full display
    /// *minus menu bar / Dock*), the correct rect for tile
    /// geometry.
    ///
    /// `visibleFrame` is `@MainActor` because it talks to
    /// `NSScreen`. Two call contexts:
    ///
    ///   - **Main thread** (CLI dispatch: `switchWorkspace` /
    ///     `moveWindow` / `setLayoutMode` / `retileActive` /
    ///     `perform`, all called from `Controller.dispatch*`
    ///     under `MainActor.assumeIsolated`): direct call, no
    ///     hop.
    ///
    ///   - **Off-main** (`Controller.refresh` dispatches
    ///     `workspaces()` to its serial `cliQueue` so AX-title
    ///     resolution can run off-main — see
    ///     `Controller.swift:472`. `refreshCatalog` →
    ///     `applyLayout` chain therefore runs off-main too):
    ///     synchronously hop to main to read `visibleFrame`,
    ///     then return. Deadlock-free: main is not blocked
    ///     waiting on cliQueue (the dispatch is `.async`),
    ///     so main is always free to service the hop. Cost:
    ///     ~1 ms per refresh tick, acceptable at the current
    ///     2 s poll cadence.
    private func activeDisplayRect() -> CGRect {
        let probe: CGPoint
        if let id = focusedWindow(),
           let pid = catalog.pid(for: id),
           let ax = AXGeom.window(for: CGWindowID(id.serverID),
                                  pid: pid_t(pid)),
           let pos = AXGeom.position(ax),
           let size = AXGeom.size(ax) {
            probe = CGPoint(x: pos.x + size.width / 2,
                            y: pos.y + size.height / 2)
        } else {
            probe = .zero
        }
        let full: CGRect
        if Thread.isMainThread {
            full = MainActor.assumeIsolated {
                Displays.visibleFrame(containing: probe)
            }
        } else {
            full = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    Displays.visibleFrame(containing: probe)
                }
            }
        }
        // Outer gap: inset the whole tiling area from each screen
        // edge before any layout carves it. Per-edge; doing it here
        // feeds every downstream path (tile / stack / engine) from
        // one place. `full` is top-left origin (Displays.visibleFrame
        // returns Quartz coords), so screen top → minY, bottom → maxY.
        let top = config.effectiveOuterGapTop
        let bottom = config.effectiveOuterGapBottom
        let left = config.effectiveOuterGapLeft
        let right = config.effectiveOuterGapRight
        guard top + bottom + left + right > 0 else { return full }
        return CGRect(x: full.minX + left,
                      y: full.minY + top,
                      width: max(0, full.width - left - right),
                      height: max(0, full.height - top - bottom))
    }

    /// Backing scale of the display the tiling `rect` sits on, for
    /// pixel-rounding tile frames. Same main-thread hop as
    /// `activeDisplayRect` (NSScreen is main-only). `rect` is already
    /// in the display's Quartz coords, so its centre identifies the
    /// screen.
    private func activeScale(near rect: CGRect) -> CGFloat {
        let p = CGPoint(x: rect.midX, y: rect.midY)
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                Displays.backingScaleFactor(containing: p)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                Displays.backingScaleFactor(containing: p)
            }
        }
    }

    /// Enumerate windows via the public CGWindowList API.
    /// Returns **every** window in the user session, not just the
    /// ones currently on-screen — each entry carries an
    /// `isOnscreen` flag (= `kCGWindowIsOnscreen`) instead. The
    /// catalog uses that flag to gate new-window entry while
    /// keeping the WS assignment of existing windows that
    /// temporarily go off-screen (different macOS Space,
    /// minimized to Dock, Cmd+H'd). Without this split, a Space
    /// switch made every previously-managed window look "gone",
    /// `forgetWindow` dropped them, and they re-landed in the
    /// current activeIndex on next sight. See memory
    /// `facet-macos-spaces-coexistence`.
    ///
    /// Skips:
    ///   - facet's own process (avoid managing our own panel)
    ///   - non-normal `kCGWindowLayer` values — wallpapers
    ///     (negative), floating panels / Dock / menu-bar /
    ///     status overlays (positive), and any third-party
    ///     overlay tool (e.g. wand / Übersicht / Sketchybar
    ///     custom panels). User app windows live at layer 0;
    ///     anything else is structural OS chrome or a tool
    ///     that won't play nicely with tiling. Auto-detected
    ///     rather than hard-coded so new overlay tools don't
    ///     require a code change.
    ///   - explicit app-name guards for `Window Server` and
    ///     `borders` — both happen to ALSO fall outside layer 0
    ///     (Window Server is huge int, borders draws decoration
    ///     overlays via a child window-server process), but the
    ///     name guard is belt-and-braces against an OS change
    ///     that ever floats them onto layer 0.
    /// `isFocused` is stamped by `WorkspaceCatalog.snapshot` against
    /// the focused-window query, so this helper stays a pure
    /// CGWindowList adapter with no AX dependency.
    private func enumerateCGWindows() -> [Window] {
        let opts: CGWindowListOption = [
            .optionAll, .excludeDesktopElements,
        ]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let myPid = Int(ProcessInfo.processInfo.processIdentifier)
        return raw.compactMap { dict in
            guard
                let cgID = dict[kCGWindowNumber as String] as? CGWindowID,
                let pid = dict[kCGWindowOwnerPID as String] as? Int,
                pid != myPid
            else { return nil }
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { return nil }
            let owner = dict[kCGWindowOwnerName as String]
                as? String ?? ""
            if owner == "Window Server" || owner == "borders" {
                return nil
            }
            let title = dict[kCGWindowName as String] as? String ?? ""
            var frame: CGRect?
            if let b = dict[kCGWindowBounds as String] as? [String: Any] {
                frame = CGRect(
                    x: b["X"]      as? CGFloat ?? 0,
                    y: b["Y"]      as? CGFloat ?? 0,
                    width: b["Width"]  as? CGFloat ?? 0,
                    height: b["Height"] as? CGFloat ?? 0)
            }
            let isOnscreen = (dict[kCGWindowIsOnscreen as String]
                as? Bool) ?? false
            return Window(
                id: WindowID(serverID: Int(cgID)),
                pid: pid,
                appName: owner,
                title: title,
                isFocused: false,
                isFloating: false,
                frame: frame,
                isOnscreen: isOnscreen,
                bundleId: bundleId(forPid: pid))
        }
    }

    public func focusedWindow() -> WindowID? {
        // Frontmost-app → AX focused-window → CGWindowID is the
        // same dance the rift adapter would need; lives in
        // `AX.frontmostFocusedCGID` so the adapters share it.
        guard let cgID = AX.frontmostFocusedCGID() else { return nil }
        return WindowID(serverID: Int(cgID))
    }

    // MARK: - Commands

    public func switchWorkspace(toIndex index: Int, autoFocus: Bool) {
        // No facet workspaces on an unmanaged native desktop.
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal)
        else { return }
        // Backend protocol convention is 0-based; catalog (matching
        // the user-facing CLI) is 1-based. Translate at the seam.
        let target = index + 1
        guard let plan = catalog.setActive(target) else { return }

        // Leave-snapshot only fires on a real transition: setActive
        // already returned nil for the no-op `target == activeIndex`
        // case, so we'd otherwise be writing the *current* focused
        // window into `currentWS`'s slot and clobber the real
        // "last time we left here" value.
        if let cur = focusedWindow() {
            catalog.recordLeaveFocus(cur, in: plan.oldActive)
        }
        Log.debug("native: switchWorkspace \(plan.oldActive) -> "
            + "\(plan.newActive) autoFocus=\(autoFocus)")
        applyHide(toPark: plan.toPark, toRestore: plan.toRestore)
        // Phase γ: overlay layout-specific frames on top of the
        // anchor restore. Floating windows in the same WS keep the
        // restoreAnchor position; tiled / stacked windows snap to
        // their computed frame.
        applyLayout(workspace: plan.newActive,
                    rect: activeDisplayRect())

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
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal)
        else { return }
        guard let t = catalog.relativeTarget(target) else {
            Log.debug("native: switchWorkspaceRelative \(target) → no-op")
            return
        }
        switchWorkspace(toIndex: t - 1, autoFocus: autoFocus)
    }

    /// Focus the window the user was last on in `newActiveWS`, or
    /// — when the WS has no windows — bounce focus to Finder so
    /// the source app doesn't linger as frontmost. Window pick
    /// goes through `WorkspaceCatalog.autoFocusTarget`, which
    /// matches the same pred chain the sidebar's optimistic
    /// highlight uses (memory `facet-ws-switch-focus-management`).
    private func applyAutoFocus(newActiveWS: Int) {
        let wsWindows = enumerateCGWindows().filter {
            catalog.windowMap[$0.id]?.workspace == newActiveWS
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

    /// 2-b defocus: when the destination WS is empty, push the
    /// frontmost-app crown to Finder. Public API only — facet
    /// stays inside the macOS sandbox ([[facet-buddha-palm-principle]]).
    /// Finder is always running; the menu bar swapping to it is
    /// the user-visible "this WS is empty" signal.
    private func activateFinder() {
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
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal)
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
        // (Phase γ: lazy retile / re-stack).
        applyLayout(workspace: catalog.activeIndex, rect: rect)
        eventContinuation.yield(.refreshNeeded)
    }

    // MARK: - Dynamic workspace commands (A: runtime WS set)

    public func switchWorkspace(named name: String, autoFocus: Bool) {
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal)
        else { return }
        guard let pos = catalog.index(ofName: name) else {
            Log.debug("native: switchWorkspace(named: \"\(name)\") → no match")
            return
        }
        switchWorkspace(toIndex: pos - 1, autoFocus: autoFocus)
    }

    public func addWorkspace() {
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal)
        else { return }
        let pos = catalog.addWorkspace()
        Log.debug("native: addWorkspace → position \(pos) "
            + "(count=\(catalog.workspaceCount))")
        eventContinuation.yield(.refreshNeeded)
    }

    public func removeWorkspace(at position: Int?) {
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal)
        else { return }
        let target = position ?? catalog.activeIndex
        let rect = activeDisplayRect()
        guard catalog.removeWorkspace(target, in: rect) else {
            Log.debug("native: removeWorkspace(\(target)) → rejected "
                + "(invalid, or last workspace)")
            return
        }
        Log.debug("native: removeWorkspace(\(target)) → "
            + "count=\(catalog.workspaceCount) active=\(catalog.activeIndex)")
        // Windows evacuated to a neighbour and positions shifted —
        // re-establish what's visible (only the active WS) and tile.
        resyncVisibleState(rect: rect)
        eventContinuation.yield(.refreshNeeded)
    }

    public func renameWorkspace(at position: Int?, to name: String) {
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal)
        else { return }
        let target = position ?? catalog.activeIndex
        catalog.renameWorkspace(target, to: name)
        Log.debug("native: renameWorkspace(\(target)) → \"\(name)\"")
        eventContinuation.yield(.refreshNeeded)
    }

    public func moveActiveWorkspace(to position: Int) {
        guard config.isSpaceManaged(ordinal: activeSpaceOrdinal)
        else { return }
        // 1-based position; active follows the moved WS. Pure
        // renumber — windows / visibility don't change.
        guard catalog.moveActiveWorkspace(to: position) else {
            Log.debug("native: moveActiveWorkspace(to: \(position)) → no-op")
            return
        }
        Log.debug("native: moveActiveWorkspace → \(position) "
            + "active=\(catalog.activeIndex)")
        eventContinuation.yield(.refreshNeeded)
    }

    /// Force on-screen reality to match the catalog: only the active
    /// workspace's windows visible (rest parked), then tile. Idempotent
    /// — `applyHide` guards already-parked / already-restored windows —
    /// so it's safe after a remove that shuffled windows + positions.
    private func resyncVisibleState(rect: CGRect) {
        let active = catalog.activeIndex
        var toPark: [WindowRef] = []
        var toRestore: [WindowRef] = []
        for (id, slot) in catalog.windowMap {
            let ref = WindowRef(id: id, pid: slot.pid)
            if slot.workspace == active { toRestore.append(ref) }
            else { toPark.append(ref) }
        }
        applyHide(toPark: toPark, toRestore: toRestore)
        applyLayout(workspace: active, rect: rect)
    }

    /// Park / restore two `WindowRef` lists at the anchor sliver.
    /// Centralises the call so callers (workspace switch,
    /// single-window move) don't repeat it.
    private func applyHide(toPark: [WindowRef],
                           toRestore: [WindowRef]) {
        for ref in toPark { parkAnchor(ref) }
        for ref in toRestore { restoreAnchor(ref) }
        if !toPark.isEmpty || !toRestore.isEmpty {
            Log.debug("native: anchor "
                + "parked=\(toPark.count) restored=\(toRestore.count)")
        }
    }

    public func setLayoutMode(workspaceIndex index: Int, mode: String) {
        let target = index + 1
        let rect = activeDisplayRect()
        // BSP → Stack migration parks all but the focused window
        // at the anchor sliver. The catalog's setMode discards
        // layoutTrees / stackOrders entries, so we rely on
        // applyStack post-flip to park non-top members. Symmetric
        // for Stack → BSP.
        let applied = catalog.setMode(workspace: target,
                                      to: mode, in: rect)
        Log.debug("native: setLayoutMode WS \(target) -> \(applied)")
        if target == catalog.activeIndex {
            applyLayout(workspace: target, rect: rect)
        }
        eventContinuation.yield(.refreshNeeded)
    }

    /// Phase δ: respond to a display reconfiguration. Fires
    /// from `displayObserver` 0.5 s after the OS settles on a
    /// new layout. Three steps in order:
    ///
    ///   1. Re-apply the active workspace's layout against the
    ///      now-current visible frame. Inactive workspaces are
    ///      not touched (lazy retile invariant —
    ///      `facet-phase-gamma-lessons`).
    ///   2. Rescue anchor-parked windows whose recorded
    ///      `originalPosition` is no longer on any visible
    ///      display: AX setPosition to the bottom-right anchor
    ///      sliver of the nearest surviving display.
    ///   3. (PanelHost handles its own reconfigure response —
    ///      Controller owns its own `DisplayChangeObserver`,
    ///      we don't notify it from here.)
    @MainActor
    private func handleDisplayReconfigure() {
        Log.debug("native: handleDisplayReconfigure")

        // Step 1: re-apply layout of the active WS against the
        // freshly-queried display rect.
        applyLayout(workspace: catalog.activeIndex,
                    rect: activeDisplayRect())

        // Step 2: anchor-parked rescue. Walk every parked
        // window's recorded originalPosition; if it no longer
        // sits on any visible display, move it to the nearest
        // surviving display's anchor sliver.
        let displays = NSScreen.screens.map(\.frame)
        let parkedPositions = catalog.anchorParked.compactMap {
            id -> (WindowID, CGPoint)? in
            guard let pos = catalog.originalPositions[id]
            else { return nil }
            return (id, pos)
        }
        let orphanPoints = DisplayGeometry.orphanedPoints(
            among: parkedPositions.map(\.1),
            displays: displays)
        guard !orphanPoints.isEmpty else {
            eventContinuation.yield(.refreshNeeded)
            return
        }
        // Group orphans by id for the AX dispatch.
        var rescued = 0
        for (id, pos) in parkedPositions where orphanPoints.contains(pos) {
            guard let pid = catalog.pid(for: id) else { continue }
            // Rescue rect: the nearest surviving display. Anchor
            // sliver lives at (maxX-1, maxY-1) of that display.
            let probe = CGRect(x: pos.x, y: pos.y,
                               width: 1, height: 1)
            guard let dest = DisplayGeometry.nearestDisplay(
                to: probe, in: displays) else { continue }
            guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID),
                pid: pid_t(pid)) else { continue }
            let anchor = CGPoint(x: dest.maxX - 1,
                                 y: dest.maxY - 1)
            AXGeom.setPosition(ax, anchor)
            rescued += 1
        }
        if rescued > 0 {
            Log.debug("native: reconfig rescued \(rescued) "
                + "anchor-parked window(s)")
        }
        eventContinuation.yield(.refreshNeeded)
    }

    /// `WindowBackend.retileActiveWorkspace` implementation:
    /// recompute + reapply the active workspace's layout. For
    /// BSP this re-tiles the tree; for stack this re-stacks
    /// (top fills, others park). No-op for float mode.
    public func retileActiveWorkspace() {
        let mode = catalog.mode(of: catalog.activeIndex)
        guard mode == "bsp" || mode == "stack"
                || LayoutRegistry.engine(named: mode) != nil else {
            Log.debug("native: retile noop "
                + "(WS \(catalog.activeIndex) is \(mode))")
            return
        }
        applyLayout(workspace: catalog.activeIndex,
                    rect: activeDisplayRect())
        eventContinuation.yield(.refreshNeeded)
    }

    /// Apply stack mode to `n1Based`: the catalog's
    /// `stackOrder[0]` fills `rect` (un-parked from the anchor
    /// sliver), all other members are parked there. Floating
    /// windows are excluded entirely (they live outside the
    /// stack). No-op when the WS isn't in stack mode or has no
    /// members.
    private func applyStack(workspace n1Based: Int, rect: CGRect) {
        let order = catalog.stackOrder(of: n1Based)
        guard let top = order.first else { return }
        // Top: force visible, full rect. Bypass the regular
        // restore flow (which would use the recorded
        // originalPosition); the stack contract is that top
        // fills the display.
        if let pid = catalog.pid(for: top),
           let ax = AXGeom.window(for: CGWindowID(top.serverID),
                                  pid: pid_t(pid))
        {
            AXGeom.setPosition(ax, rect.origin)
            AXGeom.setSize(ax, rect.size)
            catalog.clearParkedState(of: top)
        }
        // Others: park at the anchor sliver (parkAnchor owns the
        // "skip if already parked" guard).
        for id in order.dropFirst() {
            guard let pid = catalog.pid(for: id) else { continue }
            parkAnchor(WindowRef(id: id, pid: pid))
        }
        Log.debug("native: stack WS \(n1Based) "
            + "top=\(top.serverID) members=\(order.count) "
            + "rect=\(rect)")
    }

    /// Iterate the WS's tree-computed frames and push each one
    /// through AX. Floating windows are skipped (they're not in
    /// the tree). No-op when the WS has no tree.
    private func applyTile(workspace n1Based: Int, rect: CGRect) {
        applyFrames(catalog.tiledFrames(for: n1Based, in: rect),
                    label: "tile WS \(n1Based)", rect: rect)
    }

    /// Apply a stateless `LayoutEngine`'s frames for `n1Based`. The
    /// engine path: catalog computes pure geometry, this pushes it
    /// through AX exactly like `applyTile`.
    private func applyEngine(workspace n1Based: Int, rect: CGRect) {
        applyFrames(catalog.engineFrames(for: n1Based, in: rect),
                    label: "engine WS \(n1Based)", rect: rect)
    }

    /// Shared AX writer: set each window's position + size from a
    /// pre-computed frame map. Used by both the bsp tree path and
    /// the stateless-engine path.
    private func applyFrames(_ frames: [WindowID: CGRect],
                             label: String, rect: CGRect) {
        // Inner gap: pull abutting windows apart. The screen-edge
        // side of an outermost window stays flush — that distance is
        // the outer gap, already inset into `rect`. No-op when 0.
        let frames = applyInnerGap(frames, in: rect,
                                   gap: config.effectiveInnerGap)
        guard !frames.isEmpty else { return }
        // Pixel-round each frame to whole physical pixels (HiDPI
        // crispness) on the active display's backing scale — after
        // gap (which introduces fractional points), before the AX
        // write. Kept out of AXGeom's generic setters so anchor-hide's
        // sub-pixel reveal coords aren't rounded (would break the
        // macOS clamp dodge).
        let scale = activeScale(near: rect)
        // Below this (≈1pt), treat the window as already at the
        // target and skip the AX write. pixel-rounding lands frames
        // on 0.5pt (Retina) boundaries so genuine targets compare
        // well within 1pt.
        let eps: CGFloat = 1.0
        var applied = 0
        for (id, frame) in frames {
            guard let pid = catalog.pid(for: id) else { continue }
            guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID),
                pid: pid_t(pid)) else { continue }
            let r = frame.roundedToPhysicalPixels(scale: scale)
            // Frame-match skip: if the window already sits at the
            // target, don't write. This stops facet's own setSize/
            // setPosition from re-firing kAXWindowResized/Moved →
            // re-tile loop (event-driven re-tile, D), and saves the
            // AX round-trip when nothing drifted.
            if let cur = AXGeom.position(ax), let sz = AXGeom.size(ax),
               abs(cur.x - r.minX) < eps, abs(cur.y - r.minY) < eps,
               abs(sz.width - r.width) < eps, abs(sz.height - r.height) < eps {
                continue
            }
            AXGeom.setPosition(ax, r.origin)
            AXGeom.setSize(ax, r.size)
            applied += 1
        }
        Log.debug("native: \(label) "
            + "frames=\(frames.count) applied=\(applied) "
            + "rect=\(rect)")
    }

    public func closeWindow(_ id: WindowID) {
        // pid comes from `catalog.windowMap[id]` — recorded at
        // reconcile time, so no fresh CGWindowList sweep is needed.
        // Failures here all surface in the errors stream so
        // `facet status` lastError tells the user *why* the
        // right-click "Close window" appeared to do nothing —
        // a debug-log-only failure would be invisible.
        guard let pid = catalog.pid(for: id) else {
            let msg = "closeWindow \(id.serverID): not in catalog "
                + "(window may have just opened — try again)"
            Log.debug("native: \(msg)")
            errorContinuation.yield(msg)
            return
        }
        guard let ax = AXGeom.window(
                for: CGWindowID(id.serverID), pid: pid_t(pid)) else {
            let msg = "closeWindow \(id.serverID): AX element "
                + "unavailable (app may have died, or has no AX)"
            Log.debug("native: \(msg)")
            errorContinuation.yield(msg)
            return
        }
        let pressed = AXGeom.closeButton(ax)
        Log.debug("native: closeWindow \(id.serverID) "
            + "pressed=\(pressed)")
        if !pressed {
            errorContinuation.yield(
                "closeWindow \(id.serverID): close button "
                + "missing or refused (app dialog intercepted?)")
        }
        // Best-effort eviction from catalog — the next event /
        // poll reconcile will fix it anyway if the app intercepted
        // (e.g. unsaved-changes dialog) and the window survives.
        if pressed { catalog.drop(id) }
        eventContinuation.yield(.refreshNeeded)
    }

    public func perform(_ action: WindowAction) {
        // BSP: toggleFloat, toggleOrientation. Stack:
        // cycleStackNext, cycleStackPrev. Everything else
        // (master_stack / scrolling / toggleStack /
        // toggleFullscreen) is out of Phase γ scope and no-ops.
        let rect = activeDisplayRect()
        switch action {
        case .toggleFloat:
            guard let id = focusedWindow() else { return }
            catalog.toggleFloat(id, focused: id, in: rect)
            Log.debug("native: perform toggleFloat "
                + "\(id.serverID) → "
                + "isFloating=\(catalog.isFloating(id))")
            applyLayout(workspace: catalog.activeIndex, rect: rect)
            eventContinuation.yield(.refreshNeeded)
        case .toggleOrientation:
            // bsp: rotate the focused window's parent split.
            // tall: flip the master axis (Tall ↔ Wide).
            switch catalog.mode(of: catalog.activeIndex) {
            case "tall":
                _ = catalog.toggleMasterOrientation(
                    workspace: catalog.activeIndex)
                Log.debug("native: perform toggleOrientation (tall flip)")
                applyLayout(workspace: catalog.activeIndex, rect: rect)
                eventContinuation.yield(.refreshNeeded)
            case "bsp":
                guard let id = focusedWindow() else { return }
                catalog.toggleOrientation(of: id)
                Log.debug("native: perform toggleOrientation "
                    + "\(id.serverID)")
                applyLayout(workspace: catalog.activeIndex, rect: rect)
                eventContinuation.yield(.refreshNeeded)
            default:
                break
            }
        case .cycleStackNext, .cycleStackPrev:
            // Cycle is per-active-WS; no need for `focusedWindow`
            // — the catalog owns "who's the current top" via the
            // stack-order array, not via OS focus.
            let direction: WorkspaceCatalog.CycleDirection =
                action == .cycleStackNext ? .next : .prev
            let newTop = catalog.cycleStack(
                workspace: catalog.activeIndex,
                direction: direction)
            Log.debug("native: perform \(action) → newTop="
                + "\(newTop?.serverID.description ?? "nil")")
            if newTop != nil {
                applyStack(workspace: catalog.activeIndex,
                           rect: rect)
                eventContinuation.yield(.refreshNeeded)
            }
        case .promoteToMaster:
            // Tall / master-stack: move the focused window to the
            // master slot (index 0 of the WS's shared order).
            guard let id = focusedWindow() else { return }
            let moved = catalog.promoteToMaster(
                id, workspace: catalog.activeIndex)
            Log.debug("native: perform promoteToMaster "
                + "\(id.serverID) moved=\(moved)")
            if moved {
                applyLayout(workspace: catalog.activeIndex, rect: rect)
                eventContinuation.yield(.refreshNeeded)
            }
        case .growMaster, .shrinkMaster:
            // Master-ratio nudge — only meaningful for the master
            // engines; other modes ignore the knob.
            guard hasMasterKnob(catalog.activeIndex) else { return }
            let delta: CGFloat = action == .growMaster ? 0.05 : -0.05
            if catalog.adjustMasterRatio(
                workspace: catalog.activeIndex, delta: delta) {
                applyLayout(workspace: catalog.activeIndex, rect: rect)
                eventContinuation.yield(.refreshNeeded)
            }
        case .incMaster, .decMaster:
            guard hasMasterKnob(catalog.activeIndex) else { return }
            let delta = action == .incMaster ? 1 : -1
            if catalog.adjustMasterCount(
                workspace: catalog.activeIndex, delta: delta) {
                applyLayout(workspace: catalog.activeIndex, rect: rect)
                eventContinuation.yield(.refreshNeeded)
            }
        // out-of-scope / future cases — no-op, but listed explicitly
        // so the compiler enforces a handling decision on every
        // future enum addition.
        case .toggleFullscreen,
             .swapMasterStack,
             .toggleStack,
             .centerColumn, .snapStrip:
            break
        }
    }

    /// Whether the WS's mode reads the master ratio / count knobs
    /// (tall / centered-master). Other modes ignore them, so master
    /// adjustments no-op there.
    private func hasMasterKnob(_ n1Based: Int) -> Bool {
        let m = catalog.mode(of: n1Based)
        return m == "tall" || m == "centered-master"
    }

    /// Apply the workspace's mode-specific layout (tile / stack /
    /// no-op). Single dispatch site — every callsite that mutates
    /// the catalog and might need to push fresh frames through AX
    /// (refresh / switch / move / setMode / retile / perform)
    /// funnels through here.
    private func applyLayout(workspace n1Based: Int, rect: CGRect) {
        let mode = catalog.mode(of: n1Based)
        switch mode {
        case "bsp":   applyTile(workspace: n1Based, rect: rect)
        case "stack": applyStack(workspace: n1Based, rect: rect)
        default:
            if LayoutRegistry.engine(named: mode) != nil {
                applyEngine(workspace: n1Based, rect: rect)
            }
        }
    }

    public func windowMenu(mode: String, floating: Bool,
                           isMaster: Bool,
                           windowCount: Int) -> [WindowMenuItem] {
        // Menu items per layout mode (Phase γ), gated by the window's
        // actual state so master vs non-master (and a lone stack
        // window) get the right menu — no dead items. Floating windows
        // only get Unfloat + Close (tiling actions don't apply).
        var items: [WindowMenuItem] = []
        if mode == "bsp", !floating {
            items.append(.init("Toggle orientation",
                               [.toggleOrientation]))
        }
        // Cycling needs at least two windows to rotate between.
        if mode == "stack", !floating, windowCount >= 2 {
            items.append(.init("Next stack window",
                               [.cycleStackNext]))
            items.append(.init("Previous stack window",
                               [.cycleStackPrev]))
        }
        if (mode == "tall" || mode == "centered-master"), !floating {
            // "Promote to master" is meaningless for the window that
            // already holds the master slot.
            if !isMaster {
                items.append(.init("Promote to master",
                                   [.promoteToMaster]))
            }
            items.append(.init("Wider master", [.growMaster]))
            items.append(.init("Narrower master", [.shrinkMaster]))
            items.append(.init("More masters", [.incMaster]))
            items.append(.init("Fewer masters", [.decMaster]))
        }
        if mode == "tall", !floating {
            items.append(.init("Flip wide / tall",
                               [.toggleOrientation]))
        }
        items.append(.init(floating ? "Unfloat" : "Float",
                           [.toggleFloat]))
        items.append(.init("Close window", [], close: true))
        return items
    }

    // MARK: - Anchor hide / show (AX side-effects)

    /// Move the window to a 1×41 px sliver in the bottom-right
    /// corner of the display it currently sits on. macOS's clamp
    /// guarantees 41 px of title-bar stays on-screen (memory:
    /// native-window-hide-methods), so we can't fully hide via
    /// public APIs — anchor minimises the visible footprint while
    /// keeping the window recoverable from Mission Control if
    /// facet crashes (memory: facet-buddha-palm-principle).
    private func parkAnchor(_ ref: WindowRef) {
        guard catalog.shouldParkAnchor(ref.id) else { return }
        guard
            let ax = AXGeom.window(for: CGWindowID(ref.id.serverID),
                                   pid: pid_t(ref.pid)),
            let pos = AXGeom.position(ax),
            let size = AXGeom.size(ax)
        else { return }
        let center = CGPoint(x: pos.x + size.width / 2,
                             y: pos.y + size.height / 2)
        let screen = Displays.containing(center)
        let hidden = CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)
        AXGeom.setPosition(ax, hidden)
        catalog.markAnchorParked(ref.id, originalPosition: pos)
    }

    /// Reverse of `parkAnchor`: place the window back at its
    /// pre-park position. No-ops when the window isn't currently
    /// parked (defensive against double-restore on rapid switch).
    private func restoreAnchor(_ ref: WindowRef) {
        guard let orig = catalog.consumeAnchorRestore(ref.id) else { return }
        guard let ax = AXGeom.window(
                for: CGWindowID(ref.id.serverID), pid: pid_t(ref.pid))
        else { return }
        AXGeom.setPosition(ax, orig)
    }

    // AX helpers (window lookup, position / size, display match)
    // live in FacetAccessibility.AXGeom / .Displays.
}
