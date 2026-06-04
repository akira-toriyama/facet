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

/// NSObject shim so a `CADisplayLink` (target/selector only on macOS)
/// can drive `NativeAdapter.slideTick`, which isn't an NSObject. The
/// adapter owns the shim; the back-ref is weak.
private final class SlideTicker: NSObject {
    weak var adapter: NativeAdapter?
    init(_ adapter: NativeAdapter) { self.adapter = adapter; super.init() }
    // `Any` (not CADisplayLink) so the signature stays available on
    // macOS 13; the link arg is unused. The 14+ display link calls it.
    @objc func tick(_ sender: Any) { adapter?.slideTick() }
}

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
    public let layoutModes = ["bsp", "stack", "float"] + LayoutRegistry.names

    // MARK: - State (delegated to catalog)

    /// Self-managed workspace state for the **currently active**
    /// mac desktop. All mutations go through here so the
    /// state machine stays pure and testable; this file only
    /// applies the AX side-effects the catalog hands back.
    private var catalog = WorkspaceCatalog()

    /// Per-mac-desktop catalogs that aren't currently active.
    /// facet keeps an independent set of virtual workspaces per
    /// mac desktop (memory: facet-per-native-space-ws). On a
    /// mac-desktop switch the active `catalog` is parked here under its
    /// mac desktop id and the destination mac desktop's catalog is swapped in
    /// (lazily created on first visit). Window state is session-only
    /// (facet never persists), so on restart each mac desktop's catalog
    /// rebuilds from its live windows.
    private var parkedCatalogs: [UInt64: WorkspaceCatalog] = [:]

    /// SkyLight id of the mac desktop `catalog` belongs to. `0`
    /// when SkyLight is unavailable — then facet runs a single
    /// shared catalog (pre-per-mac-desktop behaviour) and never swaps.
    private var activeMacDesktopID: UInt64 = 0

    /// 1-based Mission-Control ordinal of the active mac desktop
    /// (user mac desktops only). Selects the `[desktop.N]` workspace config;
    /// `nil` → fall back to `defaultWorkspaceCount` unnamed slots.
    /// Refreshed on every mac-desktop swap. May briefly go stale if the
    /// user reorders mac desktops in Mission Control without switching —
    /// a cosmetic name/count mismatch only
    /// (memory: facet-per-native-space-ws).
    private var activeMacDesktopOrdinal: Int?

    /// Snapshot of the last `workspaces()` build, returned as-is on
    /// the next call. Rebuilt every `refreshCatalog()` invocation.
    private var workspaceList: [Workspace] = []

    /// Held so `refreshCatalog` can read the configured workspace
    /// list each tick. Note: this captures the config at adapter
    /// init time; `Controller.reloadConfig()` re-reads
    /// `config.toml` but does NOT push the fresh value back to
    /// the adapter, so `[desktop.N]` table edits during a session
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
    /// user's `[desktop.N]` sections. The (default = 5) fallback in
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
            // Focus changes get their own event so the Controller can
            // fast-path the reconcile (shorter debounce) — they drive the
            // directly-felt ④ shake + ⑤ active-window border.
            if case .focusChanged = event {
                eventContinuation.yield(.focusChanged)
            } else {
                eventContinuation.yield(.refreshNeeded)
            }
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
        let preMacDesktopID = activeMacDesktopID
        // Per-mac-desktop: if the user switched mac desktops,
        // park the current catalog and swap in the destination
        // mac desktop's. Done here (off-main, same context as every other
        // catalog mutation) rather than from the main-thread mac-desktop
        // observer, so catalog access stays single-threaded.
        swapCatalogIfMacDesktopChanged()
        let macDesktopSwapped = activeMacDesktopID != preMacDesktopID
        // Unmanaged mac desktop (no `[desktop.N]` in opt-in mode):
        // facet stays completely hands-off — adopt no windows, park
        // nothing, and return an empty workspace list so the
        // Controller hides the panel (its empty-list guard in
        // `apply`). Windows on the desktop are left exactly as the
        // user arranged them.
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal) else {
            if !workspaceList.isEmpty {
                Log.debug("native: desktop ordinal="
                    + "\(activeMacDesktopOrdinal.map(String.init) ?? "-") "
                    + "unmanaged -> hands-off, panel hidden")
            }
            workspaceList = []
            return
        }
        // Seed the per-WS default layout mode from config (`[layout]
        // default`). Layout mode is otherwise session-only, so without
        // this every restart / per-mac-desktop catalog resets to the
        // hardcoded "float" and the user's windows stop tiling until
        // they re-issue `facet workspace --layout=…`. Set every refresh
        // (cheap, value-type field) so a config hot-reload takes too.
        catalog.defaultMode = config.effectiveDefaultLayout
        // Seed the live workspace set from config the first time this
        // (per-mac-desktop) catalog is used. Idempotent — once seeded, the
        // catalog's set is authoritative and runtime add/remove/rename/
        // move own it (config stays the read-only seed).
        catalog.seed(configs: config.effectiveWorkspaceList(
            forMacDesktopOrdinal: activeMacDesktopOrdinal))
        let live = enumerateCGWindows()
        let focused = focusedWindow()
        let rect = activeDisplayRect()
        // Phase γ.3 + F: classify first-sight windows — auto-float
        // (sheets / dialogs / palettes + config float rules) and
        // ignore (config `action="ignore"` → kept fully unmanaged).
        let (autoFloat, ignore, deferred) = classifyNewWindows(live: live)
        // Drop expired trusted-new hints, then hand the survivors to
        // reconcile so a genuinely-new window joins on first on-screen
        // sight (skips the two-tick gate). Non-trusted windows — incl.
        // mac-desktop switch `isOnscreen` flips of existing windows — still
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
                                       deferred: deferred,
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
                + "total=\(live.count)"
                + (macDesktopSwapped ? " (desktop-swap)" : ""))
        }
        if result.removed > 0 { recentCloseAt = Date() }
        // Heal (mac-desktop drift): a window can leak into this
        // catalog's WS when it was swept in during a native macOS
        // mac-desktop switch (the destination mac desktop's windows flip
        // `isOnscreen=true` before `swapCatalogIfMacDesktopChanged` sees
        // the new active-mac-desktop id, so the two-tick gate adds them to
        // the wrong catalog). Prevention is racy and トミー accepts the
        // leak; instead we recompute hard here. Read each managed
        // window's TRUE mac desktop (read-only SkyLight) and evict any
        // that isn't on the active mac desktop — it'll be re-adopted by its
        // real mac desktop's catalog on visit. Only runs when SkyLight is
        // live (`activeMacDesktopID != 0`); an empty query result leaves the
        // window untouched, so a transient SkyLight miss can't evict a
        // real window. Must run BEFORE applyLayout / snapshot so both
        // the tiling and the tree reflect the cleaned membership.
        if activeMacDesktopID != 0 {
            // Cache each window's mac-desktop query for this reconcile (the
            // sanity gate + the eviction filter would otherwise double-
            // query the on-screen windows).
            var macDesktopCache: [WindowID: [UInt64]] = [:]
            func windowMacDesktops(_ id: WindowID) -> [UInt64] {
                if let c = macDesktopCache[id] { return c }
                let s = MacDesktops.ids(forWindow: id.serverID)
                macDesktopCache[id] = s
                return s
            }
            // Sanity gate: an on-screen managed window is, by
            // definition, on the active mac desktop right now — so if the
            // SLS query is sound, at least one must report it. If NONE
            // do, the query is untrustworthy (selector / id-format
            // drift across an OS update) and evicting on its word could
            // wrongly remove every real window. Bail in that case —
            // a no-op heal is harmless; a false mass-eviction is not.
            let trustworthy = live.contains { w in
                w.isOnscreen && catalog.windowMap[w.id] != nil
                    && windowMacDesktops(w.id).contains(activeMacDesktopID)
            }
            if trustworthy {
                let foreign = catalog.windowMap.keys.filter { id in
                    let s = windowMacDesktops(id)
                    return !s.isEmpty && !s.contains(activeMacDesktopID)
                }
                for id in foreign { catalog.drop(id) }
                if !foreign.isEmpty {
                    Log.debug("native: heal evicted \(foreign.count) "
                        + "off-desktop window(s) from desktop=\(activeMacDesktopID)")
                }
            } else if !catalog.windowMap.isEmpty {
                Log.debug("native: heal skipped "
                    + "(SLS desktop query untrustworthy, desktop=\(activeMacDesktopID))")
            }
        }
        // Hide-reclaim: a managed window the user Cmd+H'd / minimized
        // reads `isOnscreen=false` (facet's own anchor-sliver park stays
        // on-screen), so reclaim its tile slot — detach from the layout,
        // keep the WS assignment, re-attach at the tail when it returns.
        // Runs AFTER the off-desktop heal so only same-desktop hides remain;
        // its result feeds the open/close reflow below (hide = close,
        // reveal = open). Memory: `facet-hide-reclaim-decisions`.
        let liveByID = Dictionary(live.map { ($0.id, $0) },
                                  uniquingKeysWith: { a, _ in a })
        let hideResult = catalog.reconcileHidden(
            liveByID: liveByID, focused: focused, activeRect: rect)
        if !hideResult.hidden.isEmpty || !hideResult.revealed.isEmpty {
            Log.debug("native: hide-reclaim "
                + "hidden=\(hideResult.hidden.count) "
                + "revealed=\(hideResult.revealed.count)")
        }
        // D (event-driven re-tile): re-tile the active WS on every
        // refresh, not only when windows were added/removed. Cheap
        // when nothing drifted (applyFrames' frame-match skip reads
        // only, no AX write) and self-heals geometry after a native
        // WS switch / resize / external nudge that the old lazy
        // retile (add/remove only) missed. float WS is a no-op (no
        // engine). Supersedes the Phase γ lazy-retile invariant.
        //
        // Task 4 PR2 — open / close reflow animation: when a real
        // add or remove happened on the current mac desktop (NOT a
        // catalog-swap shockwave from a mac-desktop switch) and the user
        // opted in, route through `animateRetile` so the existing
        // tiled windows glide to their new sizes. Newly-added
        // windows skip animation — they snap to their tile slot to
        // avoid the "glide from the app's wild initial position"
        // jank (Q4.3 = b). In-flight slides retarget via the
        // existing `cancelSlideForRetarget`. Fall through to the
        // instant `applyLayout` whenever animation isn't applicable
        // (master off, sub-key off, reduce-motion, no diff, or the
        // pass coincided with a mac-desktop swap).
        let shouldAnimateOpenClose = config.effectiveAnimationEventDriven
            && !macDesktopSwapped
            && (!result.addedIDs.isEmpty || !result.removedIDs.isEmpty
                || !hideResult.hidden.isEmpty || !hideResult.revealed.isEmpty)
        if shouldAnimateOpenClose {
            cancelSlideForRetarget()
            // A revealed window snaps into its tile like a newly-opened
            // one (no glide from its off-screen resting frame); the
            // windows reflowing to fill a hidden window's freed slot
            // glide normally.
            let snapNew = Set(result.addedIDs).union(hideResult.revealed)
            if !animateRetile(workspace: catalog.activeIndex, rect: rect,
                              skipAnimation: snapNew) {
                applyLayout(workspace: catalog.activeIndex, rect: rect)
            }
        } else {
            applyLayout(workspace: catalog.activeIndex, rect: rect)
        }
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
        // windows (Cmd+H'd apps, windows on other mac desktops,
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

    /// Park the active mac desktop's catalog and swap in the destination
    /// mac desktop's (lazily created) when the user has switched mac
    /// desktops. No-op when SkyLight is unavailable
    /// (`activeMacDesktopID` stays 0 → one shared catalog) or the mac desktop
    /// is unchanged. Called only from `refreshCatalog` so all
    /// catalog access stays on a single thread. The destination mac
    /// desktop's windows are picked up by the normal reconcile that
    /// follows (its on-screen windows enter that catalog's WS1);
    /// other mac desktops' windows read `isOnscreen=false` and are
    /// ignored, so no cross-mac-desktop leakage occurs.
    private func swapCatalogIfMacDesktopChanged() {
        let live = MacDesktops.activeID()
        guard live != 0, live != activeMacDesktopID else { return }
        parkedCatalogs[activeMacDesktopID] = catalog
        let restored = parkedCatalogs.removeValue(forKey: live)
        catalog = restored ?? WorkspaceCatalog()
        activeMacDesktopID = live
        activeMacDesktopOrdinal = MacDesktops.ordinal(for: live)
        Log.debug("native: mac-desktop -> \(live) "
            + "ordinal=\(activeMacDesktopOrdinal.map(String.init) ?? "-") "
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
    /// mac-desktop switch `isOnscreen` flip of an existing one, so
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
    ///      popover) is ignored. A tile-eligible (normal/unknown-level)
    ///      window whose role can't be resolved yet — the probe raced a
    ///      still-creating window, the per-call cap was hit, OR it's a
    ///      window-server-only phantom with no backing `AXUIElement`
    ///      (System Settings' background helpers: `CGWindowList` reports
    ///      them, the app's `kAXWindows` list omits them) — is DEFERRED,
    ///      not tiled, not examined, BEFORE the exclude rules run (step
    ///      1b). A real window resolves to `AXStandardWindow` within a
    ///      poll or two and is classified then; a transient popup (VSCode
    ///      autocomplete, Chrome dropdown) or a CGS-only phantom never
    ///      resolves and so never joins the layout. (This defer is what
    ///      keeps `master-left` from breaking when an app spawns
    ///      short-lived normal-level windows — the old lean-MANAGED
    ///      default tiled them for a frame and reflowed.)
    /// User `[[exclude]]` rules win over the heuristic (incl. the
    /// `manage` force-tile escape hatch), but only once the window has
    /// resolved to a real AX element — so a float/ignore rule matching on
    /// bundle-id alone can't resurrect a phantom the gate would defer. Only unseen + unexamined
    /// windows are classified. Tile-eligible windows are left out of
    /// all three returned sets so `reconcile` manages them normally;
    /// `deferred` ids are skipped this tick and re-probed next time.
    private func classifyNewWindows(live: [Window])
        -> (autoFloat: Set<WindowID>, ignore: Set<WindowID>,
            deferred: Set<WindowID>)
    {
        let rules = config.effectiveExclusionRules
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        var autoFloat: Set<WindowID> = []
        var ignore: Set<WindowID> = []
        var deferred: Set<WindowID> = []
        var probed = 0
        for w in live
        where catalog.windowMap[w.id] == nil
            && !catalog.examinedIDs.contains(w.id)
        {
            // 1. Cheap level gate (SkyLight read, no AX). nil = SkyLight
            //    down → unknown; defer to the AX gate rather than
            //    excluding on a missing signal.
            let level = MacDesktops.windowLevel(forWindow: w.id.serverID)
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

            // 1b. Tile-eligible level but no AX role yet → DEFER, ahead
            //    of the exclude rules. The window is either still
            //    creating (probe raced), the per-call probe cap was hit,
            //    OR it's a window-server-only PHANTOM with no backing
            //    `AXUIElement` — e.g. System Settings' background helper
            //    windows, which `CGWindowListCopyWindowInfo` reports but
            //    the app's `kAXWindows` list omits (verified: AX reports
            //    1 window, CGWindowList 7). Deferring BEFORE the rules is
            //    what stops such a phantom being float-/ignore-TRACKED on
            //    bundle-id alone (the `com.apple.systempreferences` float
            //    rule used to match every phantom and, via the
            //    `kAXWindowCreated` fast-add, adopt one as a lingering
            //    `hidden` row). A real window resolves its AX role within
            //    a poll or two and is classified then; a phantom never
            //    resolves and so is never adopted. Raised-level windows
            //    skipped the probe deliberately (step 1) and fall through
            //    to the rules + level verdict below unchanged.
            if normalOrUnknownLevel, role == nil {
                deferred.insert(w.id)
                Log.debug("native: gate=defer(unresolved) "
                    + "wsid=\(w.id.serverID) app=\(w.appName)")
                continue
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
            // role is guaranteed non-nil here: a tile-eligible window
            // with an unresolved AX role was already DEFERRED at step 1b
            // (above the exclude rules), and a raised-level window was
            // ignored by the level verdict (step 3). So a definite
            // non-window role remains (AXHelpTag / menu / popover …).
            ignore.insert(w.id)
            Log.debug("native: gate=ignore(role=\(role ?? "-")) "
                + "wsid=\(w.id.serverID) app=\(w.appName)")
        }
        return (autoFloat, ignore, deferred)
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
    private func activeDisplayRect(probe probeOverride: CGPoint? = nil) -> CGRect {
        // `probeOverride` lets a caller name the display directly (the live
        // resize follow passes the dragged window's centre) so we skip the
        // focused-window AX dance — that frontmost lookup + position/size
        // read per ~30fps tick was a real drag-jank source.
        let probe: CGPoint
        if let probeOverride {
            probe = probeOverride
        } else if let id = focusedWindow(),
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
        // Smart gaps: a lone tiled window goes full-bleed — skip the
        // outer inset when the active WS holds ≤ 1 tiled window. (Inner
        // gap is already a no-op with no neighbour to pull apart.)
        if config.effectiveSmartGaps,
           catalog.nonFloatingMembers(of: catalog.activeIndex).count <= 1 {
            return full
        }
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
    /// temporarily go off-screen (different mac desktop,
    /// minimized to Dock, Cmd+H'd). Without this split, a mac desktop
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
        // Frontmost-app → AX focused-window → CGWindowID; lives in
        // the shared `AX.frontmostFocusedCGID` helper.
        guard let cgID = AX.frontmostFocusedCGID() else { return nil }
        return WindowID(serverID: Int(cgID))
    }

    /// Window-server-fresh focused window via private SkyLight
    /// (`SkyLightFocus`), falling back to the AX path when the symbols
    /// aren't available. Used by the focus fast-path — it commits more
    /// promptly than `NSWorkspace.frontmostApplication`.
    public func frontWindowFast() -> WindowID? {
        if let cgID = SkyLightFocus.frontmostFocusedCGID() {
            return WindowID(serverID: Int(cgID))
        }
        return focusedWindow()
    }

    // MARK: - 枠 E: workspace-switch slide animation (Phase 1)

    /// In-flight slide clock + its settle. Touched on main only.
    private var slideTimer: Timer?
    private var slideFinish: (() -> Void)?
    /// Resolved AX elements + from/to origins for the in-flight slide.
    /// Resolved ONCE (not per frame): the per-frame AX window lookup was
    /// the main smoothness drag. Read through `self` in the timer block
    /// so the non-Sendable AX element stays behind the class's
    /// `@unchecked Sendable` boundary.
    private var slideAnims: [(ax: AXUIElement, slide: WindowSlide)] = []
    private var slideStart: Date?
    private var slideDuration: TimeInterval = 0
    /// Easing for the in-flight animation; set when the driver starts.
    private var slideCurve: (Double) -> Double = SlideCurve.easeOutCubic
    /// True while the in-flight slide is a retile (no park bookkeeping),
    /// so an interrupt can drop it and retarget from current positions.
    private var slideIsRetile = false
    /// CADisplayLink (macOS 14+) driving the slide; `AnyObject?` keeps
    /// the stored type available on macOS 13. nil = Timer fallback.
    private var displayLink: AnyObject?
    private lazy var slideTicker = SlideTicker(self)

    /// Focus-shake clock (④). Self-contained — kept off the slide state
    /// machine (no park bookkeeping) so a cosmetic vibration can't
    /// disturb a WS-switch / retile. Touched on main only.
    private var shakeTimer: Timer?
    private var shakeStart: Date?
    private var shakeAx: AXUIElement?
    /// The window being shaken — `applyFrames` skips it so a reconcile
    /// (off-main) can't write it back to base mid-bounce and fight the
    /// on-main shake clock. Cleared when the shake settles.
    private var shakeID: WindowID?
    private var shakeBase: CGPoint = .zero
    /// Shake feel — px amplitude + seconds, captured at the start of each
    /// shake from the caller's live config (so `[shake]` edits hot-reload;
    /// the adapter's own `config` is a frozen `let`).
    private var shakeAmp: CGFloat = 0
    private var shakeDur: TimeInterval = 0.2
    /// Direction for the next switch's slide: +1 forward, -1 back, nil =
    /// derive from the index delta. `switchWorkspaceRelative` sets it so
    /// next/prev always slide the intuitive way even when they wrap
    /// (e.g. last → first reads as "forward", not the long way back).
    private var slideDirectionHint: CGFloat?

    /// AX element for a managed window (pid via the catalog).
    private func axWin(id: WindowID) -> AXUIElement? {
        guard let pid = catalog.pid(for: id) else { return nil }
        return AXGeom.window(for: CGWindowID(id.serverID), pid: pid_t(pid))
    }
    private func axWin(_ ref: WindowRef) -> AXUIElement? {
        AXGeom.window(for: CGWindowID(ref.id.serverID), pid: pid_t(ref.pid))
    }

    /// Visible tiled targets for a workspace (bsp tree / engine / stack
    /// top). Floating windows aren't here — they restore to their
    /// recorded original position (handled in `animateSwitch`).
    private func targetFrames(for n1Based: Int, in rect: CGRect)
        -> [WindowID: CGRect]
    {
        let mode = catalog.mode(of: n1Based)
        switch mode {
        case "bsp":
            return catalog.tiledFrames(for: n1Based, in: rect)
        case "stack":
            guard let top = catalog.stackOrder(of: n1Based).first
            else { return [:] }
            return [top: rect]
        default:
            guard LayoutRegistry.engine(named: mode) != nil else { return [:] }
            return catalog.engineFrames(for: n1Based, in: rect)
        }
    }

    /// Stop the per-frame driver (display link / timer). Doesn't settle.
    private func stopSlideClock() {
        if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
            link.invalidate()
        }
        displayLink = nil
        slideTimer?.invalidate()
        slideTimer = nil
    }

    /// Run the in-flight slide's settle now (on normal completion, or a
    /// hard finish that must apply the final state + park bookkeeping).
    private func finishSlideIfRunning() {
        guard let finish = slideFinish else { return }
        stopSlideClock()
        slideStart = nil
        slideFinish = nil
        finish()
    }

    /// Interrupt the in-flight slide for a *new* transition. A retile
    /// carries no park bookkeeping, so just drop it — the windows stay
    /// where they are mid-slide and the new animation redirects from
    /// their current positions (no jump to the old target). A switch
    /// must still settle (its outgoing windows have to be recorded
    /// parked before the catalog mutates again).
    private func cancelSlideForRetarget() {
        guard slideFinish != nil else { return }
        if slideIsRetile {
            stopSlideClock()
            slideAnims = []
            slideStart = nil
            slideFinish = nil
        } else {
            finishSlideIfRunning()
        }
    }

    /// One animation frame: advance progress and write each window's
    /// origin. Runs on the main runloop (CADisplayLink on macOS 14+,
    /// else a 120 Hz timer). fileprivate so the SlideTicker shim can
    /// call it; a late tick after settle no-ops on the nil slideStart.
    fileprivate func slideTick() {
        guard let begin = slideStart else { return }
        let raw = min(1.0, -begin.timeIntervalSinceNow / slideDuration)
        let e = slideCurve(raw)
        // AX is thread-safe per element; we vouch for the fan-out.
        nonisolated(unsafe) let anims = slideAnims
        // Many windows: fan out the per-frame writes so the serial sum
        // doesn't blow the frame budget. Few windows: stay serial.
        // setSize only when the tween actually resizes (WS-switch slides
        // keep size constant — pure translation).
        func write(_ a: (ax: AXUIElement, slide: WindowSlide)) {
            let fr = a.slide.frame(atEased: e)
            AXGeom.setPosition(a.ax, fr.origin)
            if a.slide.resizes { AXGeom.setSize(a.ax, fr.size) }
        }
        if anims.count >= 6 {
            DispatchQueue.concurrentPerform(iterations: anims.count) { i in
                write(anims[i])
            }
        } else {
            for a in anims { write(a) }
        }
        if raw >= 1.0 { finishSlideIfRunning() }
    }

    /// Curve + duration for the in-flight animation. `FACET_ANIM_CURVE`
    /// (spring | silky | snappy | cubic) is a dev override for A/B'ing
    /// the feel; default = ease-out cubic at the configured duration.
    private func resolveAnimPreset()
        -> (curve: (Double) -> Double, duration: TimeInterval)
    {
        let env = ProcessInfo.processInfo.environment
        // Curve: env (dev A/B) → config → default. "random" → pick one
        // per transition.
        var name = env["FACET_ANIM_CURVE"] ?? config.effectiveAnimationCurve
        if name == "random" {
            name = ["cubic", "spring", "silky", "snappy"].randomElement() ?? "cubic"
        }
        // Duration: env override → config (if set, clamped) → per-curve default.
        func ms(_ perCurveMs: Double) -> TimeInterval {
            if let e = Double(env["FACET_ANIM_MS"] ?? "") { return e / 1000 }
            if let c = config.animationDurationMs {
                return Double(min(800, max(80, c))) / 1000
            }
            return perCurveMs / 1000
        }
        switch name {
        case "spring":
            // FACET_SPRING_ZETA: lower = bouncier (more overshoot).
            let z = Double(env["FACET_SPRING_ZETA"] ?? "") ?? 0.5
            return ({ SlideCurve.spring($0, zeta: z) }, ms(420))
        case "silky":  return (SlideCurve.easeInOutCubic, ms(420))
        case "snappy": return (SlideCurve.easeOutQuint, ms(220))
        default:       return (SlideCurve.easeOutCubic, ms(280))
        }
    }

    /// Start the per-frame driver for an already-populated `slideAnims`.
    /// Prefers a vsync CADisplayLink (macOS 14+); Timer fallback on 13.
    /// `settle` runs once on completion (or interrupt via
    /// finishSlideIfRunning).
    private func startSlideDriver(_ settle: @escaping () -> Void) {
        stopShake(settleToBase: false)   // a slide supersedes a focus shake
        let preset = resolveAnimPreset()
        slideCurve = preset.curve
        slideStart = Date()
        slideDuration = preset.duration
        slideFinish = settle
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            let link = screen.displayLink(target: slideTicker,
                                          selector: #selector(SlideTicker.tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) {
                [weak self] _ in self?.slideTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            slideTimer = timer
        }
    }

    // MARK: - Focus shake (④)

    /// Briefly vibrate `id` in place as a focus cue. Position-only — the
    /// layout tree is never consulted, so neighbours can't move/resize;
    /// the window returns to its exact origin. No-op under Reduce Motion,
    /// while a WS-switch / retile slide is running (don't fight it), or if
    /// the window / its position can't be resolved.
    public func animateShake(_ id: WindowID, amplitude: CGFloat, durationMs: Double) {
        if amplitude <= 0 { return }  // `[shake] amplitude = 0` disables it
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
        if slideStart != nil { return }
        guard let ax = axWin(id: id), let base = AXGeom.position(ax) else { return }
        stopShake(settleToBase: true)        // settle any prior shake first
        shakeAmp = amplitude
        shakeDur = max(0.01, durationMs / 1000)
        shakeAx = ax
        shakeID = id
        shakeBase = base
        shakeStart = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in self?.shakeTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        shakeTimer = timer
    }

    private func shakeTick() {
        guard let begin = shakeStart, let ax = shakeAx else {
            stopShake(settleToBase: false); return
        }
        let raw = -begin.timeIntervalSinceNow / shakeDur
        guard raw < 1.0 else {
            AXGeom.setPosition(ax, shakeBase)   // land exactly at base
            stopShake(settleToBase: false)
            return
        }
        let dx = WindowShake.offset(at: raw, amplitude: shakeAmp)
        AXGeom.setPosition(ax, CGPoint(x: shakeBase.x + dx, y: shakeBase.y))
    }

    private func stopShake(settleToBase: Bool) {
        if settleToBase, let ax = shakeAx { AXGeom.setPosition(ax, shakeBase) }
        shakeTimer?.invalidate(); shakeTimer = nil
        shakeStart = nil; shakeAx = nil; shakeID = nil
    }

    /// Phase 1 of 枠 E: slide the directional filmstrip on a workspace
    /// switch. Incoming windows enter from one edge (sized off-screen
    /// first, so visible motion is pure translation); outgoing exit the
    /// opposite edge; the index delta picks the direction. The real
    /// park/tile bookkeeping happens in the settle closure (run on
    /// completion or on interrupt). Returns false when nothing is
    /// visible to move, so the caller falls back to the instant path.
    private func animateSwitch(toPark: [WindowRef], toRestore: [WindowRef],
                               oldActive: Int, newActive: Int,
                               directionHint: CGFloat?,
                               rect: CGRect, autoFocus: Bool) -> Bool {
        // Honour the system "Reduce motion" setting — fall back to the
        // instant path so motion-sensitive users aren't animated at.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return false
        }
        let screen = Displays.containing(CGPoint(x: rect.midX, y: rect.midY))
        let dir: CGFloat = directionHint ?? (newActive > oldActive ? 1 : -1)
        let enterDx = dir * screen.width   // incoming start offset (off entry edge)
        let scale = activeScale(near: rect)

        // Incoming: tiled/engine/stack targets + floating-at-original.
        var targets = targetFrames(for: newActive, in: rect)
        for ref in toRestore where targets[ref.id] == nil {
            guard let orig = catalog.originalPositions[ref.id],
                  let ax = axWin(ref), let sz = AXGeom.size(ax) else { continue }
            targets[ref.id] = CGRect(origin: orig, size: sz)
        }
        slideAnims = []
        for (id, raw) in targets {
            guard let ax = axWin(id: id) else { continue }
            let f = raw.roundedToPhysicalPixels(scale: scale)
            // We own this window's geometry now — clear its parked flag.
            catalog.clearParkedState(of: id)
            AXGeom.setSize(ax, f.size)                       // off-screen resize
            // from/to share the final size → pure translation (no setSize
            // per frame), sliding in from off the entry edge.
            let start = CGRect(x: f.origin.x + enterDx, y: f.origin.y,
                               width: f.width, height: f.height)
            AXGeom.setPosition(ax, start.origin)
            slideAnims.append((ax, WindowSlide(id: id, from: start, to: f)))
        }

        // Outgoing: capture true current frame, slide off the far edge.
        var outOrigin: [WindowID: CGPoint] = [:]
        for ref in toPark {
            guard catalog.shouldParkAnchor(ref.id), let ax = axWin(ref),
                  let p = AXGeom.position(ax), let sz = AXGeom.size(ax) else { continue }
            outOrigin[ref.id] = p
            let from = CGRect(origin: p, size: sz)
            let to = CGRect(x: p.x - enterDx, y: p.y, width: sz.width, height: sz.height)
            slideAnims.append((ax, WindowSlide(id: ref.id, from: from, to: to)))
        }

        guard !slideAnims.isEmpty else { return false }

        // Settle: authoritative final state + park bookkeeping. Runs once
        // (on completion or interrupt). Uses the *captured* outgoing
        // origins so a later switch-back restores to the real position,
        // not the slid-off-screen one.
        let settle: () -> Void = { [weak self] in
            guard let self else { return }
            self.slideAnims = []
            self.applyLayout(workspace: newActive, rect: rect)
            for ref in toPark {
                guard let orig = outOrigin[ref.id], let ax = self.axWin(ref)
                else { continue }
                let scr = Displays.containing(orig)
                self.catalog.markAnchorParked(ref.id, originalPosition: orig)
                AXGeom.setPosition(ax, CGPoint(x: scr.maxX - 1, y: scr.maxY - 1))
            }
            if autoFocus { self.applyAutoFocus(newActiveWS: newActive) }
            self.eventContinuation.yield(.refreshNeeded)
        }

        slideIsRetile = false
        startSlideDriver(settle)
        Log.debug("native: animateSwitch \(oldActive)->\(newActive) "
            + "anims=\(slideAnims.count) dir=\(Int(dir))")
        return true
    }

    /// Phase 2 of 枠 E: animate a same-mode re-tile / layout change as an
    /// in-place reflow — every visible window tweens its full frame
    /// (position + size) from where it sits now to its new tiled frame.
    /// All windows stay on-screen (no off-screen trick), so this is the
    /// resize-bearing path. Returns false (caller does the instant apply)
    /// when reduce-motion is set or nothing actually moves.
    ///
    /// `extra` adds one off-layout window (e.g. just-floated) to the
    /// same animation cycle so its move stays coordinated with the
    /// retile of the remaining tiled windows.
    ///
    /// `skipAnimation` snaps the listed ids straight to their tile
    /// frame instead of including them in the slide. Used by the
    /// open-reflow gate so a brand-new window appears at its tile
    /// slot (rather than gliding from the app's wild initial
    /// position); the surrounding windows still animate.
    private func animateRetile(workspace n1Based: Int, rect: CGRect,
                               extra: (id: WindowID, target: CGRect)? = nil,
                               skipAnimation: Set<WindowID> = []) -> Bool
    {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return false
        }
        let scale = activeScale(near: rect)
        let targets = targetFrames(for: n1Based, in: rect)
        slideAnims = []
        func append(_ id: WindowID, _ to: CGRect) {
            guard let ax = axWin(id: id), let p = AXGeom.position(ax),
                  let sz = AXGeom.size(ax) else { return }
            let snapped = to.roundedToPhysicalPixels(scale: scale)
            let from = CGRect(origin: p, size: sz)
            if abs(from.minX - snapped.minX) < 1,
               abs(from.minY - snapped.minY) < 1,
               abs(from.width - snapped.width) < 1,
               abs(from.height - snapped.height) < 1 {
                return
            }
            slideAnims.append((ax, WindowSlide(id: id, from: from, to: snapped)))
        }
        for (id, raw) in targets where !skipAnimation.contains(id) {
            append(id, raw)
        }
        if let extra { append(extra.id, extra.target) }
        guard !slideAnims.isEmpty else { return false }
        let settle: () -> Void = { [weak self] in
            guard let self else { return }
            self.slideAnims = []
            self.applyLayout(workspace: n1Based, rect: rect)
            if let extra {
                // Floating windows live outside the layout — settle their
                // final frame explicitly so a missed mid-tween write can't
                // leave them subtly off.
                if let ax = self.axWin(id: extra.id) {
                    AXGeom.setPosition(ax, extra.target.origin)
                    AXGeom.setSize(ax, extra.target.size)
                }
            }
            self.eventContinuation.yield(.refreshNeeded)
        }
        slideIsRetile = true
        startSlideDriver(settle)
        Log.debug("native: animateRetile WS \(n1Based) anims=\(slideAnims.count)"
            + (extra != nil ? " (+extra)" : ""))
        return true
    }

    /// 枠 E: animate a stack cycle as a one-window slide — the old top
    /// exits one edge, the next window enters from the opposite edge
    /// (the others stay parked); direction picks the axis. Always applies
    /// the cycle; settles via applyStack (newTop fills, others park), and
    /// falls back to an instant applyStack when it can't animate.
    private func animateStackCycle(direction: WorkspaceCatalog.CycleDirection,
                                   rect: CGRect) {
        let active = catalog.activeIndex
        let oldTop = catalog.stackOrder(of: active).first
        let newTop = catalog.cycleStack(workspace: active, direction: direction)
        Log.debug("native: animateStackCycle \(direction) "
            + "old=\(oldTop?.serverID.description ?? "nil") "
            + "new=\(newTop?.serverID.description ?? "nil")")
        guard let newTop, let oldTop, newTop != oldTop,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let oldAx = axWin(id: oldTop), let newAx = axWin(id: newTop),
              let oldPos = AXGeom.position(oldAx), let oldSize = AXGeom.size(oldAx)
        else {
            applyStack(workspace: active, rect: rect)
            eventContinuation.yield(.refreshNeeded)
            return
        }
        let r = rect.roundedToPhysicalPixels(scale: activeScale(near: rect))
        let dx = (direction == .next ? 1 : -1) * rect.width
        slideAnims = []
        // Old top: slide off the near edge (size constant → translation).
        slideAnims.append((oldAx, WindowSlide(
            id: oldTop,
            from: CGRect(origin: oldPos, size: oldSize),
            to: CGRect(x: oldPos.x - dx, y: oldPos.y,
                       width: oldSize.width, height: oldSize.height))))
        // New top: un-park, place off the far edge at full size, slide in.
        catalog.clearParkedState(of: newTop)
        AXGeom.setSize(newAx, r.size)
        let start = CGRect(x: r.minX + dx, y: r.minY,
                           width: r.width, height: r.height)
        AXGeom.setPosition(newAx, start.origin)
        slideAnims.append((newAx, WindowSlide(id: newTop, from: start, to: r)))

        let settle: () -> Void = { [weak self] in
            guard let self else { return }
            self.slideAnims = []
            self.applyStack(workspace: active, rect: rect)
            self.eventContinuation.yield(.refreshNeeded)
        }
        slideIsRetile = false   // park bookkeeping in settle → settle on interrupt
        startSlideDriver(settle)
    }

    // MARK: - Commands

    public func switchWorkspace(toIndex index: Int, autoFocus: Bool) {
        // No facet workspaces on an unmanaged mac desktop.
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        // A slide already running? Finish it before mutating the catalog.
        cancelSlideForRetarget()
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
        let rect = activeDisplayRect()
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

    // MARK: - Dynamic workspace commands (A: runtime WS set)

    public func switchWorkspace(named name: String, autoFocus: Bool) {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        guard let pos = catalog.index(ofName: name) else {
            Log.debug("native: switchWorkspace(named: \"\(name)\") → no match")
            return
        }
        switchWorkspace(toIndex: pos - 1, autoFocus: autoFocus)
    }

    public func addWorkspace() {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        let pos = catalog.addWorkspace()
        Log.debug("native: addWorkspace → position \(pos) "
            + "(count=\(catalog.workspaceCount))")
        eventContinuation.yield(.refreshNeeded)
    }

    public func removeWorkspace(at position: Int?) {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
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
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
        else { return }
        let target = position ?? catalog.activeIndex
        catalog.renameWorkspace(target, to: name)
        Log.debug("native: renameWorkspace(\(target)) → \"\(name)\"")
        eventContinuation.yield(.refreshNeeded)
    }

    public func moveActiveWorkspace(to position: Int) {
        guard config.isMacDesktopManaged(ordinal: activeMacDesktopOrdinal)
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
            // Sticky windows are park-exempt and stay on-screen
            // everywhere — never park or restore them.
            if catalog.isSticky(id) { continue }
            // Stashed scratchpad windows are the opposite: they must
            // STAY parked off-screen regardless of which WS is active —
            // restoring one when its home WS activates would un-hide the
            // shelf. (A settled scratchpad window isn't stashed, so it
            // parks / restores normally as a floating window.)
            if catalog.isStashed(id) { continue }
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
        cancelSlideForRetarget()
        // BSP → Stack migration parks all but the focused window
        // at the anchor sliver. The catalog's setMode discards
        // layoutTrees / stackOrders entries, so we rely on
        // applyStack post-flip to park non-top members. Symmetric
        // for Stack → BSP.
        let oldMode = catalog.mode(of: target)
        let applied = catalog.setMode(workspace: target,
                                      to: mode, in: rect)
        Log.debug("native: setLayoutMode WS \(target) -> \(applied)")
        if target == catalog.activeIndex {
            // 枠 E Phase 2: animate the reflow only between all-visible
            // layouts. stack parks members (windows appear / disappear),
            // which the slide engine doesn't handle yet — instant there.
            let parks = oldMode == "stack" || applied == "stack"
            if config.effectiveAnimationsEnabled, !parks,
               animateRetile(workspace: target, rect: rect) {
                return
            }
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
        cancelSlideForRetarget()
        let rect = activeDisplayRect()
        // 枠 E Phase 2: animate the in-place reflow. animateRetile owns
        // its settle (applyLayout + refresh); fall through to instant
        // when off / reduce-motion / nothing moved.
        if config.effectiveAnimationsEnabled,
           animateRetile(workspace: catalog.activeIndex, rect: rect) {
            return
        }
        applyLayout(workspace: catalog.activeIndex, rect: rect)
        eventContinuation.yield(.refreshNeeded)
    }

    public func balanceActiveWorkspace() {
        // Master knobs are the only per-WS layout state that drifts;
        // bsp split ratios are fixed at 0.5 today. No knob → nothing
        // to reset. Skip the re-tile when already at the baseline.
        guard hasMasterKnob(catalog.activeIndex) else {
            Log.debug("native: balance noop "
                + "(WS \(catalog.activeIndex) has no master knob)")
            return
        }
        guard catalog.resetParams(workspace: catalog.activeIndex) else {
            Log.debug("native: balance noop (already at baseline)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func rotateActiveWorkspace(degrees: Int) {
        guard catalog.rotateTree(workspace: catalog.activeIndex,
                                 degrees: degrees) else {
            Log.debug("native: rotate noop "
                + "(WS \(catalog.activeIndex) not bsp / unchanged)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func mirrorActiveWorkspace(_ axis: MirrorAxis) {
        let treeAxis: LayoutTree.Axis =
            axis == .horizontal ? .horizontal : .vertical
        guard catalog.mirrorTree(workspace: catalog.activeIndex,
                                 axis: treeAxis) else {
            Log.debug("native: mirror noop "
                + "(WS \(catalog.activeIndex) not bsp / unchanged)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func swapWindows(_ a: WindowID, _ b: WindowID) {
        guard catalog.swapWindows(a, b,
                                  workspace: catalog.activeIndex) else {
            Log.debug("native: swap noop "
                + "a=\(a.serverID) b=\(b.serverID)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func insertWindow(_ moved: WindowID, beside target: WindowID,
                             edge: InsertEdge) {
        guard catalog.insertWindow(moved, beside: target, edge: edge,
                                   workspace: catalog.activeIndex) else {
            Log.debug("native: insert noop "
                + "moved=\(moved.serverID) target=\(target.serverID)")
            return
        }
        reflowActive(rect: activeDisplayRect())
    }

    public func resizeWindow(_ id: WindowID, to frame: CGRect,
                             reflowDragged: Bool) {
        // Name the display from the dragged window's centre — it's on the
        // active display, and this avoids the focused-window AX probe every
        // live tick.
        let rect = activeDisplayRect(
            probe: CGPoint(x: frame.midX, y: frame.midY))
        let frozen = catalog.applyResize(id, to: frame,
                                         workspace: catalog.activeIndex, in: rect,
                                         innerGap: config.effectiveInnerGap)
        if reflowDragged {
            // Settle (gesture end / one-shot): a full reflow re-applies the
            // new ratio to everyone, snapping the dragged window onto its
            // freshly-computed slot (≈ where the user left it). Run even
            // when no ratio moved so a native resize the layout can't
            // follow (an out-of-scope grid / stack mode, or a window edge
            // dragged against a screen boundary) snaps the window back to
            // its slot rather than being left at its off-layout size.
            reflowActive(rect: rect)
        } else if let frozen {
            // PR-2 live tick: re-tile only the OPPOSITE subtree. Freeze the
            // dragged window AND its same-subtree mates — the OS is still
            // drawing the native resize, and those mates sit off the divider
            // anchored to the dragged window's (excluded) frame, so re-tiling
            // them to their computed slots would open a gap. Instant (no
            // animation) so the opposite side tracks the drag.
            applyLayout(workspace: catalog.activeIndex, rect: rect, skip: frozen)
        } else {
            Log.debug("native: resize noop id=\(id.serverID)")
        }
    }

    public func windowFrame(_ id: WindowID) -> CGRect? {
        // Prefer the window server (CGWindowList): a single-id description
        // is fast and DOESN'T round-trip to the window's app — which
        // matters during a live resize, when the dragged app (Chrome等) is
        // busy and its AX answers slowly, the main per-tick jank source.
        // kCGWindowBounds is top-left global coords, the same Quartz space
        // as the catalog's tile frames. Fall back to AX if the server has
        // no entry (rare). Read off-main (Controller dispatches on cliQueue).
        let cgID = CGWindowID(id.serverID)
        if let info = CGWindowListCreateDescriptionFromArray(
                [cgID] as CFArray) as? [[String: Any]],
           let b = info.first?[kCGWindowBounds as String] as? [String: Any],
           let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
           let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        guard let ax = axWin(id: id),
              let pos = AXGeom.position(ax),
              let size = AXGeom.size(ax) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    public func predictedDrop(dragged a: WindowID, target b: WindowID,
                              zone: IntentZone) -> DropPrediction {
        let rect = activeDisplayRect()
        // Pre-drop computed layout (same math as the commit), then apply
        // the drop to a COPY of the catalog (a value type) and recompute.
        // Diffing the two gives the EXACT set of windows the drop moves —
        // no live-position / sub-pixel noise.
        let before = computedTileFrames(catalog, in: rect)
        var copy = catalog
        let ws = copy.activeIndex
        let changed: Bool
        switch zone {
        case .center:
            changed = copy.swapWindows(a, b, workspace: ws)
        case .edge(let edge):
            changed = copy.insertWindow(a, beside: b, edge: edge, workspace: ws)
        }
        guard changed else { return .none }
        let after = computedTileFrames(copy, in: rect)
        let moved = Set(after.keys.filter { after[$0] != before[$0] })
        return DropPrediction(frames: after, moved: moved)
    }

    /// The active workspace's tiled-window frames as the commit would
    /// place them — engine / tree geometry plus the same inner gap
    /// `applyFrames` applies, so a predicted outline lands exactly on the
    /// gapped on-screen window.
    private func computedTileFrames(_ cat: WorkspaceCatalog,
                                    in rect: CGRect) -> [WindowID: CGRect] {
        let ws = cat.activeIndex
        let raw = cat.mode(of: ws) == "bsp"
            ? cat.tiledFrames(for: ws, in: rect)
            : cat.engineFrames(for: ws, in: rect)
        return applyInnerGap(raw, in: rect, gap: config.effectiveInnerGap)
    }

    public func markFocusedWindow(_ name: String) -> Bool {
        guard let id = focusedWindow() else {
            Log.debug("native: mark \"\(name)\" — no focused window")
            return false
        }
        catalog.setMark(name, to: id)
        Log.debug("native: mark \"\(name)\" -> \(id.serverID)")
        eventContinuation.yield(.refreshNeeded)   // repaint the badge
        return true
    }

    public func focusMark(_ name: String) -> Bool {
        guard let id = catalog.window(forMark: name),
              let slot = catalog.windowMap[id] else {
            Log.debug("native: focus-mark \"\(name)\" — unset / gone")
            return false
        }
        // Cross-WS jump: switch first (un-parks + tiles the target WS,
        // suppressing default focus), then assert the marked window —
        // the same two-step the tree-click path uses. Same WS → assert
        // straight away.
        if slot.workspace != catalog.activeIndex {
            switchWorkspace(toIndex: slot.workspace - 1, autoFocus: false)
        }
        guard let win = enumerateCGWindows().first(where: { $0.id == id })
        else {
            Log.debug("native: focus-mark \"\(name)\" — window vanished")
            return false
        }
        Focus.assert(win, backend: self)
        Log.debug("native: focus-mark \"\(name)\" -> \(id.serverID) "
            + "WS \(slot.workspace)")
        return true
    }

    public func unmark(_ name: String) -> Bool {
        guard catalog.removeMark(name) else {
            Log.debug("native: unmark \"\(name)\" — no such mark")
            return false
        }
        Log.debug("native: unmark \"\(name)\"")
        eventContinuation.yield(.refreshNeeded)   // repaint — badge gone
        return true
    }

    // MARK: - Scratchpad shelf (stash / toggle / release)

    public func stashScratchpad(_ name: String) -> Bool {
        guard let id = focusedWindow() else {
            Log.debug("native: scratchpad --stash=\"\(name)\" — no focus")
            return false
        }
        let rect = activeDisplayRect()
        guard catalog.stashWindow(name, id: id) else {
            Log.debug("native: scratchpad --stash=\"\(name)\" — "
                + "\(id.serverID) not managed")
            return false
        }
        // Hide it off-screen (the catalog already detached + force-
        // floated it), then reflow so the neighbours fill the freed slot.
        if let slot = catalog.windowMap[id] {
            parkAnchor(WindowRef(id: id, pid: slot.pid))
        }
        Log.debug("native: scratchpad --stash=\"\(name)\" -> \(id.serverID)")
        reflowActive(rect: rect)
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    public func toggleScratchpad(_ name: String) -> Bool {
        guard let id = catalog.window(forScratchpad: name),
              let slot = catalog.windowMap[id] else {
            Log.debug("native: scratchpad --toggle=\"\(name)\" — unset / gone")
            return false
        }
        let rect = activeDisplayRect()
        let ref = WindowRef(id: id, pid: slot.pid)
        if catalog.isScratchpadVisibleHere(name) {
            // Visible on the current WS → re-park it onto the shelf.
            _ = catalog.restashScratchpad(name)
            parkAnchor(ref)
        } else {
            // Stashed, or settled on another WS → summon it onto the
            // current WS. `restoreAnchor` no-ops when not parked.
            _ = catalog.summonScratchpad(name)
            restoreAnchor(ref)
            if let win = enumerateCGWindows().first(where: { $0.id == id }) {
                Focus.assert(win, backend: self)   // focus doesn't auto-jump
            }
        }
        Log.debug("native: scratchpad --toggle=\"\(name)\" -> "
            + "\(id.serverID) stashed=\(catalog.isStashed(id))")
        reflowActive(rect: rect)
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    public func releaseScratchpad(_ name: String) -> Bool {
        guard let id = catalog.window(forScratchpad: name),
              let slot = catalog.windowMap[id] else {
            Log.debug("native: scratchpad --release=\"\(name)\" — no such shelf")
            return false
        }
        let rect = activeDisplayRect()
        let ref = WindowRef(id: id, pid: slot.pid)
        // Drop the shelf + un-float + attach to the active WS's layout
        // first, then position it. A tiling WS re-tiles it from wherever
        // it sits, so just clear the stale park bookkeeping (no
        // intermediate jump to the recorded position). A float-mode WS
        // doesn't tile, so restore it to its pre-stash position on-screen.
        _ = catalog.releaseScratchpad(name, focused: id, in: rect)
        if catalog.mode(of: catalog.activeIndex) == "float" {
            restoreAnchor(ref)
        } else {
            catalog.clearParkedState(of: id)
        }
        Log.debug("native: scratchpad --release=\"\(name)\" -> \(id.serverID)")
        reflowActive(rect: rect)
        eventContinuation.yield(.refreshNeeded)
        return true
    }

    public func stashedScratchpads() -> [String] {
        catalog.stashedScratchpadNames()
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
    private func applyTile(workspace n1Based: Int, rect: CGRect,
                           skip: Set<WindowID> = []) {
        applyFrames(catalog.tiledFrames(for: n1Based, in: rect),
                    label: "tile WS \(n1Based)", rect: rect, skip: skip)
    }

    /// Apply a stateless `LayoutEngine`'s frames for `n1Based`. The
    /// engine path: catalog computes pure geometry, this pushes it
    /// through AX exactly like `applyTile`.
    private func applyEngine(workspace n1Based: Int, rect: CGRect,
                             skip: Set<WindowID> = []) {
        applyFrames(catalog.engineFrames(for: n1Based, in: rect),
                    label: "engine WS \(n1Based)", rect: rect, skip: skip)
    }

    /// Shared AX writer: set each window's position + size from a
    /// pre-computed frame map. Used by both the bsp tree path and
    /// the stateless-engine path.
    private func applyFrames(_ frames: [WindowID: CGRect],
                             label: String, rect: CGRect,
                             skip: Set<WindowID> = []) {
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
            // Live resize follow: the dragged window is being resized
            // natively by the user — skip it so we don't fight the OS.
            // Focus shake (④): the shaken window is being driven by the
            // on-main shake clock — skip it so this (possibly off-main)
            // reconcile can't write it back to base mid-bounce and fight
            // the shake; it settles to base when the shake ends anyway.
            if skip.contains(id) || id == shakeID { continue }
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

    public func revealWindow(_ id: WindowID) {
        // Tree-click on a hidden row. Probe BOTH restore paths — each
        // no-ops when not applicable — rather than tracking whether the
        // window was Cmd+H'd or Cmd+M'd. The catalog re-attaches it to
        // the layout on the next reconcile (the AX deminiaturize/shown
        // event already nudged one). Memory: `facet-hide-reclaim-decisions`.
        guard let pid = catalog.pid(for: id) else {
            Log.debug("native: revealWindow \(id.serverID): not in catalog")
            return
        }
        // 1) Cmd+H app-hide → unhide the owning app (macOS has no
        //    per-window un-hide, so this reveals all its windows).
        NSRunningApplication(processIdentifier: pid_t(pid))?.unhide()
        // 2) Cmd+M minimize → clear kAXMinimized on the window.
        if let ax = AXGeom.window(for: CGWindowID(id.serverID),
                                  pid: pid_t(pid)) {
            AXGeom.setMinimized(ax, false)
        }
        // 3) Focus the restored window (backend-confirmed retry, like
        //    every other focus path here).
        Focus.assert(
            Window(id: id, pid: pid, appName: "", title: "",
                   isFocused: false, isFloating: false, frame: nil),
            backend: self)
        Log.debug("native: revealWindow \(id.serverID) "
            + "(unhide + unminimize + focus)")
        eventContinuation.yield(.refreshNeeded)
    }

    /// Animate (or instantly apply) the active workspace's reflow after
    /// a user action (master / orientation / float). Mirrors the retile
    /// path — animate when on, else snap — and owns the refresh yield.
    private func reflowActive(rect: CGRect,
                              extra: (id: WindowID, target: CGRect)? = nil) {
        cancelSlideForRetarget()
        if config.effectiveAnimationsEnabled,
           animateRetile(workspace: catalog.activeIndex, rect: rect,
                         extra: extra) {
            return
        }
        if let extra, let ax = axWin(id: extra.id) {
            AXGeom.setPosition(ax, extra.target.origin)
            AXGeom.setSize(ax, extra.target.size)
        }
        applyLayout(workspace: catalog.activeIndex, rect: rect)
        eventContinuation.yield(.refreshNeeded)
    }

    /// The tiled neighbour of the focused window in `direction`, or nil
    /// at an edge / when there's nothing to step to (stack = one visible
    /// window, float = its own rects). Pure geometry (`nearestWindow`)
    /// over the active WS's tiled frames (②).
    private func directionalNeighbor(_ direction: Direction,
                                     rect: CGRect) -> WindowID? {
        guard let id = focusedWindow() else { return nil }
        let frames = targetFrames(for: catalog.activeIndex, in: rect)
        guard let here = frames[id] else { return nil }
        let others = frames.compactMap { kv -> (id: WindowID, frame: CGRect)? in
            kv.key == id ? nil : (id: kv.key, frame: kv.value)
        }
        return nearestWindow(to: here, among: others, direction: direction)
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
            let nowFloating = catalog.isFloating(id)
            Log.debug("native: perform toggleFloat "
                + "\(id.serverID) → isFloating=\(nowFloating)")
            // Task 2: a user-toggled float lands centered on the active
            // display (current size preserved). Auto-floats (AX role,
            // sheets / dialogs) are not user-triggered and skip this —
            // the app's chosen position is left alone.
            var extra: (id: WindowID, target: CGRect)? = nil
            if nowFloating, let ax = axWin(id: id),
               let sz = AXGeom.size(ax) {
                let target = CGRect(
                    x: rect.midX - sz.width / 2,
                    y: rect.midY - sz.height / 2,
                    width: sz.width, height: sz.height)
                extra = (id, target)
            }
            reflowActive(rect: rect, extra: extra)
        case .toggleSticky:
            // Pin / unpin the focused window across every WS in this
            // mac desktop. Setting: catalog force-floats + park-exempts
            // it (it stays at its current frame). Clearing: catalog
            // un-floats + re-homes it as a tiled window of the active WS
            // (Q4). Either way the active WS reflows: setting fills the
            // gap the window left, clearing tiles the returning window.
            guard let id = focusedWindow() else { return }
            var extra: (id: WindowID, target: CGRect)? = nil
            if catalog.isSticky(id) {
                catalog.clearSticky(id, focused: id, in: rect)
            } else {
                // Center a *tiled* window as it becomes sticky: it's
                // about to float and would otherwise overlap whatever
                // reflows into its freed slot — same rule as
                // toggle-float ("a tiled window turning floating lands
                // centered"). A window ALREADY floating (PiP / timer /
                // music) keeps its position — pinning shouldn't teleport
                // it (POLA).
                let wasFloating = catalog.isFloating(id)
                catalog.setSticky(id)
                if !wasFloating, let ax = axWin(id: id),
                   let sz = AXGeom.size(ax) {
                    let target = CGRect(
                        x: rect.midX - sz.width / 2,
                        y: rect.midY - sz.height / 2,
                        width: sz.width, height: sz.height)
                    extra = (id, target)
                }
            }
            // Log the *actual* post-state — setSticky no-ops for a
            // window not yet in `windowMap`, so the intended flag would
            // lie about the outcome.
            Log.debug("native: perform toggleSticky "
                + "\(id.serverID) → isSticky=\(catalog.isSticky(id))")
            reflowActive(rect: rect, extra: extra)
        case .toggleOrientation:
            // bsp-only: rotate the focused window's parent split. The
            // master engines pick their edge directly via
            // `--layout=master-EDGE` (M9-2), so there's no orientation
            // knob left to flip here.
            guard catalog.mode(of: catalog.activeIndex) == "bsp",
                  let id = focusedWindow() else { return }
            catalog.toggleOrientation(of: id)
            Log.debug("native: perform toggleOrientation "
                + "\(id.serverID)")
            reflowActive(rect: rect)
        case .cycleStackNext, .cycleStackPrev:
            // Cycle is per-active-WS; no need for `focusedWindow`
            // — the catalog owns "who's the current top" via the
            // stack-order array, not via OS focus.
            let direction: WorkspaceCatalog.CycleDirection =
                action == .cycleStackNext ? .next : .prev
            cancelSlideForRetarget()
            if config.effectiveAnimationsEnabled {
                // 枠 E: slide the old top out / next top in.
                animateStackCycle(direction: direction, rect: rect)
            } else {
                let newTop = catalog.cycleStack(
                    workspace: catalog.activeIndex, direction: direction)
                Log.debug("native: perform \(action) → newTop="
                    + "\(newTop?.serverID.description ?? "nil")")
                if newTop != nil {
                    applyStack(workspace: catalog.activeIndex, rect: rect)
                    eventContinuation.yield(.refreshNeeded)
                }
            }
        case .promoteToMaster:
            // master-stack: move the focused window to the
            // master slot (index 0 of the WS's shared order).
            guard let id = focusedWindow() else { return }
            let moved = catalog.promoteToMaster(
                id, workspace: catalog.activeIndex)
            Log.debug("native: perform promoteToMaster "
                + "\(id.serverID) moved=\(moved)")
            if moved {
                reflowActive(rect: rect)
            }
        case .growMaster, .shrinkMaster:
            // Master-ratio nudge — only meaningful for the master
            // engines; other modes ignore the knob.
            guard hasMasterKnob(catalog.activeIndex) else { return }
            let delta: CGFloat = action == .growMaster ? 0.05 : -0.05
            if catalog.adjustMasterRatio(
                workspace: catalog.activeIndex, delta: delta) {
                reflowActive(rect: rect)
            }
        case .incMaster, .decMaster:
            guard hasMasterKnob(catalog.activeIndex) else { return }
            let delta = action == .incMaster ? 1 : -1
            if catalog.adjustMasterCount(
                workspace: catalog.activeIndex, delta: delta) {
                reflowActive(rect: rect)
            }
        case .focusDir(let dir):
            // ② Directional focus: pick the tiled neighbour on that side
            // and assert focus (no layout change). Edge / stack (single
            // visible) → nearestWindow returns nil → no-op.
            guard let target = directionalNeighbor(dir, rect: rect),
                  let win = enumerateCGWindows().first(where: { $0.id == target })
            else { return }
            Focus.assert(win, backend: self)
        case .moveDir(let dir):
            // ② Directional move: swap the focused window with the tiled
            // neighbour on that side (yabai --swap). Edge → no-op.
            guard let id = focusedWindow(),
                  let target = directionalNeighbor(dir, rect: rect) else { return }
            swapWindows(id, target)
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

    /// Whether the WS's mode reads the master ratio / count knobs — true
    /// exactly for the master-stack engines (`master-left` …
    /// `master-center`), which is what `LayoutEngine.hasMaster` reports.
    /// Data-driven so new master engines need no edit here. Other modes
    /// (bsp / stack / grid / spiral / float) ignore the knobs, so master
    /// adjustments no-op there.
    private func hasMasterKnob(_ n1Based: Int) -> Bool {
        LayoutRegistry.engine(named: catalog.mode(of: n1Based))?.hasMaster ?? false
    }

    /// Apply the workspace's mode-specific layout (tile / stack /
    /// no-op). Single dispatch site — every callsite that mutates
    /// the catalog and might need to push fresh frames through AX
    /// (refresh / switch / move / setMode / retile / perform)
    /// funnels through here.
    private func applyLayout(workspace n1Based: Int, rect: CGRect,
                             skip: Set<WindowID> = []) {
        let mode = catalog.mode(of: n1Based)
        switch mode {
        case "bsp":   applyTile(workspace: n1Based, rect: rect, skip: skip)
        case "stack": applyStack(workspace: n1Based, rect: rect)
        default:
            if LayoutRegistry.engine(named: mode) != nil {
                applyEngine(workspace: n1Based, rect: rect, skip: skip)
            }
        }
    }

    public func windowMenu(mode: String, floating: Bool,
                           isMaster: Bool,
                           windowCount: Int,
                           isSticky: Bool) -> [WindowMenuItem] {
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
        if LayoutRegistry.engine(named: mode)?.hasMaster == true, !floating {
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
        // A sticky window is always floating, and float-exit =
        // sticky-exit, so "Unfloat" and "Unstick" would do the same
        // thing — show only the clearer "Unstick" and skip "Sticky"
        // (it already is). Any other window gets Float/Unfloat plus a
        // "Sticky" entry (setSticky force-floats a tiled window).
        if isSticky {
            items.append(.init("Unstick", [.toggleSticky]))
        } else {
            items.append(.init(floating ? "Unfloat" : "Float",
                               [.toggleFloat]))
            items.append(.init("Sticky", [.toggleSticky]))
        }
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
