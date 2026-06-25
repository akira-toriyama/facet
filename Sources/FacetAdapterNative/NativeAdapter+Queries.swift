// Queries — catalog refresh (`refreshCatalog`), new-window
// classification, CGWindowList enumeration, display / scale probes,
// and the focused-window read. Extracted unchanged from
// NativeAdapter.swift (#182 phase 4) — same-module extension, no
// logic change. Stored state stays on the primary declaration
// (NativeAdapter.swift).

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import FacetAccessibility
import FacetCore

extension NativeAdapter {
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
        // P6: the highest-frequency catalog mutator. `workspaces()` (its
        // sole caller) is always invoked on cliQueue — fail fast otherwise.
        dispatchPrecondition(condition: .onQueue(cliQueue))
        let preMacDesktopID = activeMacDesktopID
        // Per-mac-desktop: if the user switched mac desktops,
        // park the current catalog and swap in the destination
        // mac desktop's. Done here (off-main, same context as every other
        // catalog mutation) rather than from the main-thread mac-desktop
        // observer, so catalog access stays single-threaded.
        swapCatalogIfMacDesktopChanged()
        let macDesktopSwapped = activeMacDesktopID != preMacDesktopID
        // Unmanaged mac desktop (no `[[desktop.N.section]]` in opt-in mode):
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
            // Hands-off desktop carries no orphans either — clear the mirror so
            // a stale prior-desktop orphan can't leak into the panel.
            syncOrphanMirror(in: [], focused: nil, populateTags: false)
            return
        }
        seedCatalogFromConfig()
        let live = enumerateCGWindows()
        // raise-on-open bookkeeping: flag genuinely-new windows by their
        // FIRST appearance in this `.optionAll` enumeration (see
        // `seenWindowIDs`). Done before classify so the verdict for a new
        // float can be paired with "is it actually new" at commit time.
        // Skipped entirely when the feature is off.
        let raiseMode = config.effectiveRaiseOnOpen
        if raiseMode != .off {
            let liveIDs = Set(live.map(\.id))
            if didBootstrap {
                freshlyOpenedIDs.formUnion(liveIDs.subtracting(seenWindowIDs))
            }
            seenWindowIDs.formUnion(liveIDs)
            freshlyOpenedIDs.formIntersection(liveIDs)   // drop closed-before-commit
        }
        let focused = focusedWindow()
        let rect = activeDisplayRect()
        // Phase γ.3 + F: classify first-sight windows — auto-float
        // (sheets / dialogs / palettes + config float rules) and
        // ignore (config `action="ignore"` → kept fully unmanaged).
        let (autoFloat, ignore, deferred, tagMasks, probedAX) =
            classifyNewWindows(live: live)
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
                                       requireConfirm: true,
                                       tags: tagMasks)
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
        // Heal mac-desktop drift BEFORE the reflow / snapshot below so
        // both the tiling and the tree reflect the cleaned membership.
        healOffDesktopDrift(live: live)
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
        // [[rule]] adopt-rules (#282/#286 Phase 3): a NEW window matching a
        // rule's `match` gets that rule's `apply` ops set on adoption — the
        // declarative successor to the retired `[[assign]]` (#191). Evaluated
        // POST-adoption (NOT in the classify gate) so a malformed rule can
        // never disturb role-auto-float; MULTI-MATCH (a window accumulates
        // every matching rule's ops, in declaration order); matched against the
        // window's PRE-apply snapshot (rules don't chain on tags they add).
        // Runs BEFORE the reconcile/retile below AND before the lens-inherit
        // block, so the facets land in one pass. Global — not gated on the
        // section model (adopt-apply is useful in by-workspace mode too).
        if !result.addedIDs.isEmpty, !compiledRules().isEmpty {
            for id in result.addedIDs {
                guard let w = liveByID[id], let slot = catalog.windowMap[id]
                else { continue }
                let tagged = w.withTags(slot.tags.sorted())
                let wsName = slot.workspace.map { catalog.workspaceName($0) }
                for op in ruleApplyOps(for: tagged, inWorkspaceNamed: wsName) {
                    applyRuleOp(op, to: id, focused: focused, in: rect)
                }
            }
        }
        // EX-3.3 (canon ④⑨ "新規窓 = 開いた世界の apply を継ぐ・必ず見える"): a
        // window launched while a section-lens is active inherits that lens's
        // FORWARD `apply` ops so it JOINS the lens — the `applySectionLensReconcile`
        // immediately below then shows it in the cross-workspace union instead
        // of parking it. The full forward set is applied (tags + floating/sticky/
        // master), so a window auto-joining lands in the same facet state as one
        // dragged into the section; `setWorkspace` is the one op stripped — the
        // window keeps `workspace = activeIndex` (D-A: never an orphan-on-birth —
        // orphans arise only from an explicit DnD move). Only the freshly-adopted
        // ids are touched (not existing windows), and the catalog setters are
        // idempotent + run BEFORE the reconcile/retile below so the facets land in
        // one pass (no float-then-tile flicker). An apply-less / wholly-stripped
        // pure-condition lens that a new window doesn't match leaves it in its
        // home WS (declared gap).
        if !result.addedIDs.isEmpty {
            let inheritOps = activeSectionLensApplyForward()
            if !inheritOps.isEmpty {
                for id in result.addedIDs {
                    for op in inheritOps {
                        switch op {
                        case .addTag(let t):
                            _ = catalog.addTagToWindow(id, name: t)
                        case .setFloating(let b):
                            _ = catalog.setFloating(id, b, focused: focused, in: rect)
                        case .setSticky(let b):
                            _ = catalog.setSticky(id, b, focused: focused, in: rect)
                        case .setMaster(let b):
                            _ = catalog.setMaster(id, b, workspace: catalog.activeIndex)
                        // removeTag is never config-authored; setWorkspace is
                        // stripped upstream (keep `workspace = activeIndex`).
                        case .removeTag, .setWorkspace:
                            break
                        }
                    }
                }
                Log.debug("native: new-window lens-inherit ops=\(inheritOps.count) "
                    + "windows=\(result.addedIDs.count)")
            }
        }
        // Section-lens (EX-1 cross-workspace model, D3): continuous re-park.
        // Re-evaluate the active section-lens across ALL workspaces on the
        // current mac desktop (`applySectionLensReconcile` → `sectionLensVisibleIDsAll`)
        // and park any member that's now out of the lens (a window just opened
        // into any WS while a lens is active) / restore one that re-entered.
        // Runs BEFORE `retileAfterReconcile` so a newly-parked window is
        // already detached + excluded from `nonFloatingMembers` when the
        // re-tile computes frames — no tile-then-park flicker. Syncs the
        // main-readable mirror too (covers a mac-desktop swap that restored a
        // desktop whose lens persists). No-op when no lens is active.
        applySectionLensReconcile(live: live, rect: rect)
        syncSectionLensMirror()
        // Event-driven re-tile of the active WS (with open/close reflow
        // animation when applicable). See `retileAfterReconcile`.
        retileAfterReconcile(addedIDs: result.addedIDs,
                             removedIDs: result.removedIDs,
                             hidden: hideResult.hidden,
                             revealed: hideResult.revealed,
                             macDesktopSwapped: macDesktopSwapped, rect: rect)
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
        let sectionModelLive =
            config.isSectionModelActive(ordinal: activeMacDesktopOrdinal)
        workspaceList = catalog.snapshot(
            live: live,
            focused: displayFocus,
            activeRect: rect,
            // Section model (PR8): populate `Window.tags` so a lens
            // `match='tag~=X'` / `apply:addTag(X)` round-trips. Gated on the
            // active mac desktop being section-managed — by-workspace / tag
            // degrade unaffected (passes false → `tags: []`).
            populateTags: sectionModelLive)
        // EX-3 迷子: refresh the orphan mirror with the SAME live / focus /
        // section-model gate the snapshot used. `snapshot` drops orphans (no
        // `Workspace`), so the views' lens sections get them from this mirror
        // via `Controller.apply` → `FilterProjection.project(…, orphans:)`.
        syncOrphanMirror(in: live, focused: displayFocus,
                         populateTags: sectionModelLive)
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
        // raise-on-open: surface a genuinely freshly-opened float once.
        // Runs LAST in the pass — after `redirectedFocus` — so a same-cycle
        // close→focus-redirect can't re-bury the new float.
        surfaceFreshlyOpenedFloats(addedIDs: result.addedIDs,
                                   autoFloat: autoFloat, probedAX: probedAX,
                                   liveByID: liveByID, ignore: ignore,
                                   raiseMode: raiseMode)
    }

    // MARK: - refreshCatalog stages
    //
    // Cohesive stages hoisted out of `refreshCatalog` (P8-4). Each is
    // called only from there, so — like every catalog touch — it runs on
    // `cliQueue`; the `dispatchPrecondition` guard stays on the public
    // entry path (`refreshCatalog`), NOT duplicated onto these internal
    // helpers. Behaviour is unchanged from the inlined blocks.

    /// Seed the per-WS default layout mode + the workspace set from config.
    /// Called every refresh: `defaultMode` is a cheap value-type set so a
    /// config hot-reload takes; `seed` is idempotent (first-call only), so
    /// the catalog's runtime set stays authoritative.
    private func seedCatalogFromConfig() {
        // nil-ordinal seed-taint recovery: a prior refresh may have seeded
        // THIS (per-mac-desktop) catalog while the active-space ordinal was
        // unresolved — launched / switched into a fullscreen space
        // (`MacDesktops.ordinal` skips `type != 0`) or a transient SLS
        // mismatch. That path seeds `defaultWorkspaceCount` UNNAMED slots,
        // and `seed`'s idempotence guard then blocks the correction for the
        // rest of the session (the catalog is parked by mac-desktop id and
        // restored tainted). Once a real ordinal resolves AND this desktop's
        // section model is active, discard the degenerate (all-empty) catalog
        // so the fresh `seed` below lands the configured (emoji) names. Gated
        // on a REAL ordinal — SkyLight-unavailable single-desktop mode
        // (`id == 0` → ordinal nil) keeps its unnamed slots — and on all-empty
        // names, so a runtime rename / add (which makes a name non-empty) is
        // never clobbered.
        if let ordinal = activeMacDesktopOrdinal,
           catalog.holdsOnlyUnnamedSlots,
           config.isSectionModelActive(ordinal: ordinal) {
            Log.debug("native: recovering nil-ordinal seed-taint — "
                + "re-seeding desktop ordinal=\(ordinal)")
            catalog = WorkspaceCatalog()
        }
        // Seed the per-WS default layout mode from config (`[layout]
        // default`). Layout mode is otherwise session-only, so without
        // this every restart / per-mac-desktop catalog resets to the
        // hardcoded "float" and the user's windows stop tiling until
        // they re-issue `facet workspace --layout …`. Set every refresh
        // (cheap, value-type field) so a config hot-reload takes too.
        catalog.defaultMode = config.effectiveDefaultLayout
        // Seed the live workspace set from config the first time this
        // (per-mac-desktop) catalog is used. Idempotent — once seeded, the
        // catalog's set is authoritative and runtime add/remove/rename/
        // move own it (config stays the read-only seed).
        catalog.seed(configs: config.effectiveWorkspaceList(
            forMacDesktopOrdinal: activeMacDesktopOrdinal))
    }

    /// Heal (mac-desktop drift): a window can leak into this catalog's WS
    /// when it was swept in during a native macOS mac-desktop switch (the
    /// destination mac desktop's windows flip `isOnscreen=true` before
    /// `swapCatalogIfMacDesktopChanged` sees the new active-mac-desktop id,
    /// so the two-tick gate adds them to the wrong catalog). Prevention is
    /// racy and トミー accepts the leak; instead we recompute hard here.
    /// Read each managed window's TRUE mac desktop (read-only SkyLight) and
    /// evict any that isn't on the active mac desktop — it'll be re-adopted
    /// by its real mac desktop's catalog on visit. Only runs when SkyLight
    /// is live (`activeMacDesktopID != 0`); an empty query result leaves the
    /// window untouched, so a transient SkyLight miss can't evict a real
    /// window. Must run BEFORE applyLayout / snapshot so both the tiling and
    /// the tree reflect the cleaned membership.
    private func healOffDesktopDrift(live: [Window]) {
        guard activeMacDesktopID != 0 else { return }
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
        // Sanity gate: an on-screen managed window is, by definition, on
        // the active mac desktop right now — so if the SLS query is sound,
        // at least one must report it. If NONE do, the query is
        // untrustworthy (selector / id-format drift across an OS update)
        // and evicting on its word could wrongly remove every real window.
        // Bail in that case — a no-op heal is harmless; a false
        // mass-eviction is not.
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

    /// Re-tile the active WS after reconcile. Event-driven (D): re-tile on
    /// every refresh, not only on add/remove — cheap when nothing drifted
    /// (`applyFrames`' frame-match skip reads only), self-heals geometry
    /// after a native WS switch / resize / external nudge the old lazy
    /// retile missed. float WS is a no-op. Task 4 PR2 — open / close reflow
    /// animation: when a real add / remove / hide / reveal happened on the
    /// current mac desktop (NOT a catalog-swap shockwave from a mac-desktop
    /// switch) and the user opted in, glide the tiled windows to their new
    /// sizes via `animateRetile`; newly-added / revealed windows snap (skip
    /// the glide from a wild initial position). Falls through to the instant
    /// `applyLayout` whenever animation isn't applicable.
    private func retileAfterReconcile(addedIDs: [WindowID],
                                      removedIDs: [WindowID],
                                      hidden: [WindowID], revealed: [WindowID],
                                      macDesktopSwapped: Bool, rect: CGRect) {
        let shouldAnimateOpenClose = config.effectiveAnimationEventDriven
            && !macDesktopSwapped
            && (!addedIDs.isEmpty || !removedIDs.isEmpty
                || !hidden.isEmpty || !revealed.isEmpty)
        if shouldAnimateOpenClose {
            // A revealed window snaps into its tile like a newly-opened
            // one (no glide from its off-screen resting frame); the
            // windows reflowing to fill a hidden window's freed slot
            // glide normally.
            let snapNew = Set(addedIDs).union(revealed)
            if !animateRetile(workspace: catalog.activeIndex, rect: rect,
                              skipAnimation: snapNew) {
                applyLayout(workspace: catalog.activeIndex, rect: rect)
            }
        } else {
            applyLayout(workspace: catalog.activeIndex, rect: rect)
        }
    }

    // MARK: - Section-lens evaluation (tag-unification Phase 1)

    /// A0's single id→section seam: resolve a stable section id
    /// (`"section:<declOrder>:<label>"`) to its `DesktopSection` on the active
    /// mac desktop, or `nil` when the id no longer resolves (out of range, not
    /// a lens, label-suffix mismatch — a stale hot-reload). `declOrder` indexes
    /// the SAME `effectiveMacDesktopSectionConfigs[ord]` array `FilterProjection`
    /// enumerated to mint the id, so the lookup round-trips exactly. Read the
    /// live config every call so a hot-reload is picked up immediately.
    func lensSection(forID id: String) -> DesktopSection? {
        guard let ord = activeMacDesktopOrdinal,
              let configs = config.effectiveMacDesktopSectionConfigs[ord]
        else { return nil }
        return ApplyResolver.section(forSectionID: id, in: configs)
    }

    /// The DesktopSection of the ACTIVE section-lens (`catalog.activeSectionLens`
    /// holds its id, A0), or `nil` when no lens is active / its id no longer
    /// resolves. The single read all the lens-config queries below share.
    func activeLensSection() -> DesktopSection? {
        catalog.activeSectionLens.flatMap(lensSection(forID:))
    }

    /// Per-section layout for the ACTIVE lens, or nil when no lens is active /
    /// its `layout` field is absent / empty. `applyLayout` passes the result to
    /// `LensLayout.resolve` so a nil / stateful name falls back to the global
    /// default without tiling breaking.
    func lensLayout() -> String? {
        activeLensSection()?.layout
    }

    /// EX-3.3: the FORWARD `apply` ops in the ACTIVE section-lens (canon ④⑨ — a
    /// window launched while this lens is active inherits these so it joins the
    /// lens in the SAME facet state as one dragged in). Everything the section's
    /// `apply` carries EXCEPT `setWorkspace`, which is stripped so the new window
    /// keeps `workspace = activeIndex` (D-A: never an orphan-on-birth). This
    /// mirrors the DnD forward set (`ApplyResolver` strips `setWorkspace`;
    /// `removeTag` is never config-authored). `[]` when no lens is active or the
    /// section has an empty / wholly-stripped `apply` (a pure-condition lens —
    /// the new window can't be made to match, declared gap). Resolved against the
    /// LIVE config so a hot-reload is honoured (mirrors `lensLayout()` /
    /// `sectionLensFilter()`).
    func activeSectionLensApplyForward() -> [ApplyOp] {
        guard let section = activeLensSection() else { return [] }
        return section.apply.filter {
            if case .setWorkspace = $0 { return false }
            return true
        }
    }

    /// The active `[[rule]]` adopt-rules with their `match` compiled to a
    /// `FacetFilter` (#282/#286 Phase 3). Parsed once and cached
    /// (`compiledRulesCache`, dropped on hot-reload); a rule whose `match` is
    /// malformed is logged LOUD + dropped (non-fatal — the rest still run).
    /// cliQueue-only.
    func compiledRules() -> [(rule: Rule, filter: FacetFilter)] {
        if let c = compiledRulesCache { return c }
        let compiled: [(rule: Rule, filter: FacetFilter)] =
            config.effectiveRules.compactMap { rule in
                guard case .success(let filter) = FacetFilter.parse(rule.match) else {
                    Log.line("[[rule]] match=\"\(rule.match)\" — malformed filter; "
                        + "rule skipped")
                    return nil
                }
                return (rule, filter)
            }
        compiledRulesCache = compiled
        return compiled
    }

    /// The accumulated `[[rule]]` apply ops for a window (#282/#286 Phase 3) —
    /// EVERY matching rule's `apply`, in declaration order (multi-match). Pure
    /// over the compiled rules + the window's pre-apply snapshot, so rules
    /// don't chain on tags they themselves add. The `refreshCatalog` adopt path
    /// executes the result via `applyRuleOp`.
    func ruleApplyOps(for window: Window, inWorkspaceNamed wsName: String?) -> [ApplyOp] {
        var ops: [ApplyOp] = []
        for (rule, filter) in compiledRules()
        where LensMembership.matches(window, inWorkspaceNamed: wsName, filter: filter) {
            ops.append(contentsOf: rule.apply)
        }
        return ops
    }

    /// Execute one `[[rule]]` adopt op on a freshly-adopted window (cliQueue,
    /// pre-reconcile). Mirrors the section apply executor + the lens-inherit
    /// loop, but HONOURS `setWorkspace` (a rule may place the window): the
    /// named workspace is resolved at runtime and skipped + logged if absent
    /// (workspaces are auto-named — a rule never creates one). `removeTag` is
    /// never config-authored.
    private func applyRuleOp(_ op: ApplyOp, to id: WindowID,
                             focused: WindowID?, in rect: CGRect) {
        switch op {
        case .addTag(let t):
            _ = catalog.addTagToWindow(id, name: t)
        case .setFloating(let b):
            _ = catalog.setFloating(id, b, focused: focused, in: rect)
        case .setSticky(let b):
            _ = catalog.setSticky(id, b, focused: focused, in: rect)
        case .setMaster(let b):
            _ = catalog.setMaster(
                id, b,
                workspace: catalog.windowMap[id]?.workspace ?? catalog.activeIndex)
        case .setWorkspace(let name):
            guard let idx = catalog.index(ofName: name) else {
                Log.line("[[rule]] setWorkspace=\"\(name)\" — no such workspace; skipped")
                return
            }
            // Honour the MoveOutcome like the public `moveWindow(toWorkspaceIndex:)`:
            // a move to an INACTIVE workspace returns `.park`, and the window only
            // leaves the screen when `applyHide` anchor-parks it — `retileAfterReconcile`
            // tiles `activeIndex` only, so without this the moved window would ghost
            // on the current desktop until the next manual switch.
            switch catalog.moveWindow(id, to: idx, in: rect) {
            case .park(let ref):    applyHide(toPark: [ref], toRestore: [])
            case .restore(let ref): applyHide(toPark: [], toRestore: [ref])
            case .rejected, .stateOnly: break
            }
        case .removeTag:
            break
        }
    }

    /// Resolved stateless layout for the section-lens labelled `label` (EX-0.3).
    /// Combines the runtime override (`catalog.activeSectionLensLayout`) with the
    /// section's configured `layout` field: override wins when set, else the
    /// config layout, with `LensLayout.resolve` providing the stateless clamp +
    /// globalDefault fallback. The SINGLE source of truth consumed by both
    /// `applyLayout` and `targetFrames` (via `sectionLensUnionFrames`) so the
    /// instant and animated paths can't disagree. Called only when a section
    /// lens is active (`catalog.activeSectionLens != nil`).
    func resolvedLensLayout() -> String {
        LensLayout.resolve(catalog.activeSectionLensLayout ?? lensLayout(),
                           globalDefault: config.effectiveDefaultLayout)
    }

    /// The active section-lens's compiled filter, or nil when no lens is
    /// active / its id no longer maps to a lens section / its `match` won't
    /// parse. The catalog holds the id (authority); this resolves it to the
    /// section's `match` against the LIVE config (so a hot-reload is picked up)
    /// and compiles it, caching by the raw string so the WHERE-clause is
    /// parsed once across reconciles rather than every tick.
    private func sectionLensFilter() -> FacetFilter? {
        guard let match = activeLensSection()?.match
        else { return nil }
        if let c = sectionLensCompiled, c.match == match { return c.filter }
        guard case .success(let filter) = FacetFilter.parse(match) else {
            sectionLensCompiled = nil
            return nil
        }
        sectionLensCompiled = (match, filter)
        return filter
    }

    /// Cross-workspace evaluator (EX-0.1 / EX-1 exclusive lens). Returns the
    /// set of ALL managed windows — across every workspace on the current mac
    /// desktop — whose live `Window` passes the active section-lens `match`.
    /// Each window is evaluated against its OWN home-workspace name so a lens
    /// `match='workspace=Dev'` resolves correctly even for windows in inactive
    /// workspaces.
    ///
    /// `nil` when no lens is active.
    func sectionLensVisibleIDsAll(live: [Window]) -> Set<WindowID>? {
        guard let filter = sectionLensFilter() else { return nil }
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: Set<WindowID> = []
        for (id, slot) in catalog.windowMap {
            guard let w = byID[id] else { continue }
            // Overlay the catalog's tag NAMES onto the live (tag-less) window so
            // a `tag~=X` lens resolves in this gather/park path exactly as the
            // snapshot overlays them for the tree DISPLAY — otherwise a
            // tag-based section lens (the shape every DnD-to-lens + new-window
            // inherit produces, EX-3) would show the window in the tree but
            // never physically gather/park it. workspace name is overlaid too
            // (nil → "" for an orphan, so `not workspace` matches it).
            let tagged = w.withTags(slot.tags.sorted())
            // nil workspace name = NO assignment (orphan) so `not workspace`
            // matches; an assigned window passes its name (even "" when
            // unnamed) so `not workspace` excludes it.
            let wsName = slot.workspace.map { catalog.workspaceName($0) }
            if LensMembership.matches(tagged, inWorkspaceNamed: wsName,
                                      filter: filter) {
                out.insert(id)
            }
        }
        return out
    }

    /// Section-lens continuous re-park (D3). Re-evaluate the active lens over
    /// the active workspace and apply the park/restore delta — catches a
    /// window opened into the active WS while a lens is active (it should be
    /// hidden) or one whose match flipped. Idempotent: an unchanged verdict
    /// yields an empty plan and no AX. When a newly-parked window was holding
    /// focus (e.g. raise-on-open surfaced it), redirect focus off the
    /// now-off-screen sliver. No-op when no lens is active.
    private func applySectionLensReconcile(live: [Window], rect: CGRect) {
        guard catalog.activeSectionLens != nil,
              let visible = sectionLensVisibleIDsAll(live: live)
        else { return }
        let plan = catalog.applySectionLens(visibleIDs: visible, in: rect)
        guard !plan.isEmpty else { return }
        Log.debug("native: section-lens re-park "
            + "parked=\(plan.toPark.count) restored=\(plan.toRestore.count)")
        applyHide(toPark: plan.toPark, toRestore: plan.toRestore)
        if let f = focusedWindow(), plan.toPark.contains(where: { $0.id == f }) {
            applySectionLensAutoFocus(visibleIDs: visible)
        }
    }

    /// raise-on-open: surface a genuinely freshly-opened floating window
    /// once. Gate = `freshlyOpenedIDs` (first appeared in the enumeration
    /// this session) ∩ this cycle's float commits (`addedIDs ∩ autoFloat`).
    /// NOT `addedIDs` alone: a PRE-EXISTING float merely adopted on a first
    /// mac-desktop visit or at startup also joins `addedIDs`, but was
    /// enumerated long before (so it's not in `freshlyOpenedIDs`) and is
    /// left untouched — no raise on a bare desktop switch. Unlike the
    /// `kAXWindowCreated` hint, this catches a freshly-LAUNCHED app's first
    /// float (no observer race, no TTL). A window commits once and is
    /// dropped from the pending set on commit, so this fires exactly once
    /// per real open. `probedAX` holds the AX element from this cycle's
    /// classify probe (no extra round-trip); `liveByID` is the map built in
    /// the caller.
    private func surfaceFreshlyOpenedFloats(addedIDs: [WindowID],
                                            autoFloat: Set<WindowID>,
                                            probedAX: [WindowID: AXUIElement],
                                            liveByID: [WindowID: Window],
                                            ignore: Set<WindowID>,
                                            raiseMode: RaiseOnOpen) {
        guard raiseMode != .off else { return }
        var activated: Set<Int> = []
        for id in addedIDs
        where autoFloat.contains(id) && freshlyOpenedIDs.contains(id) {
            guard let ax = probedAX[id] else { continue }
            let w = liveByID[id]
            switch raiseMode {
            case .raise:
                AX.raise(ax)
                Log.debug("native: raise-on-open(raise) "
                    + "wsid=\(id.serverID) app=\(w?.appName ?? "-")")
            case .activate:
                if let pid = w?.pid, activated.insert(pid).inserted {
                    AX.activateApp(pid: pid)
                    Log.debug("native: raise-on-open(activate) "
                        + "pid=\(pid) app=\(w?.appName ?? "-")")
                }
            case .off:
                break
            }
        }
        // Drop ids we're done with so the pending set stays small:
        // committed windows (raised if float, else just tracked) and
        // `ignore` verdicts (raised-level overlays / config ignore —
        // they never commit, so they'd otherwise linger until close).
        freshlyOpenedIDs.subtract(addedIDs)
        freshlyOpenedIDs.subtract(ignore)
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
    func swapCatalogIfMacDesktopChanged() {
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
            deferred: Set<WindowID>, tags: [WindowID: Set<String>],
            probedAX: [WindowID: AXUIElement])
    {
        let rules = config.effectiveExclusionRules
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        // New windows start with no tags (the `tags` map stays empty). A
        // window opened while a `type="lens"` section is active inherits that
        // lens's forward `apply` later in `refreshCatalog`
        // (`activeSectionLensApplyForward`), so no per-window seed is needed here.
        // The probe below is built for the `[[exclude]]` action lookup, the
        // sole consumer of the resolved AX role/subrole now that `[[assign]]`
        // is retired (#191).
        let tagMasks: [WindowID: Set<String>] = [:]
        var autoFloat: Set<WindowID> = []
        var ignore: Set<WindowID> = []
        var deferred: Set<WindowID> = []
        var probed = 0
        // AX element of each window we resolved this pass, RETURNED so a
        // float can be surfaced (`[window] raise-on-open`) at its
        // reconcile commit point without a second AX round-trip. Only
        // normal/unknown level windows are probed, so raised-level floats
        // (overlays / wallpaper) have no entry here and are never raised —
        // exactly the scope we want.
        var probedAX: [WindowID: AXUIElement] = [:]
        // Only on-screen windows are classified. Off-screen windows
        // (other mac desktops, Cmd+H'd, minimized) are never adopted by
        // `reconcile` anyway — its snapshot skips them at the
        // `!isOnscreen` gate before they reach `windowMap`. Probing them
        // here is pure waste: the AX role of an off-screen window doesn't
        // resolve, so each one burns a `maxAutoFloatProbes` slot only to
        // `defer(unresolved)` every cycle. With many mac desktops that
        // backlog (100+ off-screen windows) starves the *active* desktop's
        // freshly-opened windows out of the 16-probe budget — a new
        // Calendar never gets a slot and stays unmanaged until a restart
        // frees the budget (memory probe-budget-starvation-bug). Gating on
        // `isOnscreen` ties the probe budget to the active desktop's window
        // count (bounded by one screen), independent of how many mac
        // desktops exist; each off-screen window is still classified once
        // its desktop becomes active and the window reads on-screen.
        for w in live
        where catalog.windowMap[w.id] == nil
            && !catalog.examinedIDs.contains(w.id)
            && w.isOnscreen
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
                    probedAX[w.id] = ax
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
        // Per-cycle classify summary (FACET_DEBUG). The on/off-screen
        // candidate split is the canary for the probe-budget starvation
        // the `isOnscreen` gate fixes: `cand.offscreen` must stay at
        // probed=0 (skipped) so the 16-slot budget always reaches the
        // active desktop's on-screen windows. Guarded so the O(n) tallies
        // cost nothing when debug is off. Memory:
        // probe-budget-starvation-bug.
        if debugMode {
            let cand = live.filter {
                catalog.windowMap[$0.id] == nil
                    && !catalog.examinedIDs.contains($0.id)
            }
            Log.debug("native: classify live=\(live.count) "
                + "cand=\(cand.count) "
                + "onscreen=\(cand.filter { $0.isOnscreen }.count) "
                + "offscreen=\(cand.filter { !$0.isOnscreen }.count) "
                + "probed=\(probed) deferred=\(deferred.count) "
                + "float=\(autoFloat.count) ignore=\(ignore.count)")
        }
        return (autoFloat, ignore, deferred, tagMasks, probedAX)
    }

    /// Display rect to anchor tile / stack math against.
    /// Determined by the focused window's centre point (or the
    /// origin when nothing is focused — startup, mid-switch).
    /// Always returns `Displays.visibleFrame` (full display
    /// *minus menu bar / Dock*), the correct rect for tile
    /// geometry.
    ///
    /// `visibleFrame` is `@MainActor` because it talks to `NSScreen`.
    /// P6: the catalog is cliQueue-confined, so EVERY caller of this runs
    /// on `cliQueue` (the command mutators, the refresh/reconcile chain,
    /// the slide setup) — not on main. It therefore always takes the
    /// `DispatchQueue.main.sync` branch to read `visibleFrame`. That is
    /// the ONE `cliQueue → main` sync hop in the codebase, and it is
    /// deadlock-free by the project's threading rule: `main → cliQueue` is
    /// ALWAYS `.async` (never `.sync`), so main is never blocked waiting on
    /// cliQueue and is always free to service this hop. Cost: ~1 ms per
    /// call. (The `Thread.isMainThread` fast-path below stays as a cheap
    /// guard for any future main-thread caller, but in practice never
    /// fires now.) Do NOT add a `main → cliQueue` `.sync` anywhere — it
    /// would close the cycle and deadlock here.
    func activeDisplayRect(probe probeOverride: CGPoint? = nil) -> CGRect {
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
    func activeScale(near rect: CGRect) -> CGFloat {
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
    func enumerateCGWindows() -> [Window] {
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
}
