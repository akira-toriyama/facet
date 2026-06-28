// CLI ↔ GUI IPC + the symmetric view / workspace / window dispatch
// family — the DNC observer (``installCLIControl``) that receives
// `facet` client-mode commands, the `dispatch*` routing it fans out
// to, and runtime re-theming (``applyThemeOverride``). Extracted unchanged
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
                case let s where s.hasPrefix("theme:"):
                    self.applyThemeOverride(
                        String(s.dropFirst("theme:".count)))

                // Symmetric view ops — canonical-only, no aliases.
                case let s where s.hasPrefix("view:"):
                    // Payload: NAME[+loading:MS][+geom:X,Y,W,H][+edge:E]
                    let rest = String(s.dropFirst("view:".count))
                    let parts = rest.split(separator: "+")
                    let name = String(parts.first ?? "")
                    let mods = parts.dropFirst().map(String.init)
                    let geom: NSRect? = mods
                        .first(where: { $0.hasPrefix("geom:") })
                        .flatMap { Self.parseGeom($0) }
                    let loadingMs: Int? = mods
                        .first(where: { $0.hasPrefix("loading:") })
                        .flatMap { Int($0.dropFirst("loading:".count)) }
                    let edge: RailEdge? = mods
                        .first(where: { $0.hasPrefix("edge:") })
                        .flatMap { RailEdge(rawValue: String($0.dropFirst("edge:".count))) }
                    self.dispatchView(name, geom: geom,
                                      loadingMs: loadingMs, edge: edge)
                case let s where s.hasPrefix("hide:"):
                    self.dispatchHide(
                        String(s.dropFirst("hide:".count)))
                case let s where s.hasPrefix("toggle:"):
                    self.dispatchToggle(
                        String(s.dropFirst("toggle:".count)))

                case let s where s.hasPrefix("workspace:"):
                    self.dispatchWorkspaceTarget(
                        String(s.dropFirst("workspace:".count)))

                // Section/lens model: activate / clear the ACTIVE lens (a
                // `type="lens"` section, keyed by its label). The label can
                // hold any character (incl. `:`), so the whole remainder is
                // the label — no further parsing.
                case let s where s.hasPrefix("lens-section:"):
                    // CLI / hotkey path → autoFocus so focus lands in the
                    // new visible set (the in-panel tree toggle passes false).
                    self.setActiveLens(
                        String(s.dropFirst("lens-section:".count)),
                        autoFocus: true)
                case "lens-clear":
                    self.setActiveLens(nil, autoFocus: true)

                // Unified section addressing: `facet section --focus N|LABEL`
                // → resolve the tree-order index / label to its ActiveSection.
                case let s where s.hasPrefix("section-focus:"):
                    self.dispatchSectionFocus(
                        String(s.dropFirst("section-focus:".count)))

                // §E: `facet section --rename N LABEL` → runtime (session-only)
                // display-label rename. Wire = `section-rename:<index>:<label>`.
                // The index is a colon-free Int; the label may contain ':', so
                // `decodeSectionRename` splits ONCE and keeps the label verbatim
                // (same wire form as `window-retag`, but the label half is loose).
                case let s where s.hasPrefix("section-rename:"):
                    guard let (n, label) = decodeSectionRename(s) else {
                        Log.debug("section-rename: malformed \"\(s)\"")
                        self.setError("section --rename: malformed")
                        self.scheduleReconcile(after: 0.05)
                        break
                    }
                    self.renameSection(indexN1Based: n, to: label)

                case "workspace-add":
                    self.runBackendCommand { bk in bk.addWorkspace(); return nil }

                case let s where s.hasPrefix("workspace-remove:"):
                    let raw = String(s.dropFirst("workspace-remove:".count))
                    self.runBackendCommand { bk in
                        bk.removeWorkspace(at: raw.isEmpty ? nil : Int(raw))
                        return nil
                    }

                case let s where s.hasPrefix("workspace-rename:"):
                    let name = String(s.dropFirst("workspace-rename:".count))
                    self.runBackendCommand { bk in
                        bk.renameWorkspace(at: nil, to: name); return nil
                    }

                case let s where s.hasPrefix("workspace-move:"):
                    let to = Int(s.dropFirst("workspace-move:".count)) ?? 0
                    self.runBackendCommand { bk in
                        bk.moveActiveWorkspace(to: to); return nil
                    }

                case let s where s.hasPrefix("window-move:"):
                    let n = Int(s.dropFirst("window-move:".count)) ?? 0
                    self.dispatchWindowMove(n)

                case let s where s.hasPrefix("window-move-follow:"):
                    let n = Int(
                        s.dropFirst("window-move-follow:".count)) ?? 0
                    self.dispatchWindowMove(n, follow: true)

                case let s where s.hasPrefix("window-mark:"):
                    let name = String(s.dropFirst("window-mark:".count))
                    self.runBackendCommand { bk in
                        bk.markFocusedWindow(name) ? nil
                            : "window --mark \(name): no focused window"
                    }

                case let s where s.hasPrefix("window-focus-mark:"):
                    let name = String(
                        s.dropFirst("window-focus-mark:".count))
                    self.runBackendCommand { bk in
                        bk.focusMark(name) ? nil
                            : "window --focus-mark \(name): no such mark"
                    }

                case let s where s.hasPrefix("window-unmark:"):
                    let name = String(s.dropFirst("window-unmark:".count))
                    self.runBackendCommand { bk in
                        bk.unmark(name) ? nil
                            : "window --unmark \(name): no such mark"
                    }

                case let s where s.hasPrefix("window-toggle-tag:"):
                    let name = String(
                        s.dropFirst("window-toggle-tag:".count))
                    self.runBackendCommand { bk in
                        bk.toggleTagOnFocusedWindow(name) ? nil
                            : "window --toggle-tag \(name): "
                                + "no focused window"
                    }

                case let s where s.hasPrefix("window-tag:"):
                    let name = String(s.dropFirst("window-tag:".count))
                    self.runBackendCommand { bk in
                        bk.addTagToFocusedWindow(name) ? nil
                            : "window --tag \(name): "
                                + "no focused window"
                    }

                case let s where s.hasPrefix("window-untag:"):
                    let name = String(s.dropFirst("window-untag:".count))
                    self.runBackendCommand { bk in
                        bk.removeTagFromFocusedWindow(name) ? nil
                            : "window --untag \(name): "
                                + "no such tag / no focused window"
                    }

                case let s where s.hasPrefix("window-retag:"):
                    // Payload OLD:NEW — neither half can contain ':'
                    // (parseTagName forbids it), so one split is
                    // unambiguous (same wire form as tag-rename). The
                    // 4-way result drives a precise error (#228).
                    let body = String(s.dropFirst("window-retag:".count))
                    let parts = body
                        .split(separator: ":", maxSplits: 1,
                               omittingEmptySubsequences: false)
                        .map(String.init)
                    let shown = body.replacingOccurrences(of: ":", with: " ")
                    if parts.count != 2 {
                        self.setError("window --retag \(shown): malformed")
                        self.scheduleReconcile(after: 0.05)
                    } else {
                        self.runBackendCommand { bk in
                            switch bk.retagFocusedWindow(
                                old: parts[0], new: parts[1]) {
                            case .retagged:
                                return nil
                            case .noFocus:
                                return "window --retag \(shown): "
                                    + "no focused window"
                            // EX-4: tags are a free-form Set<String> (no
                            // vocabulary, no cap), so `retagWindow` only ever
                            // returns `.retagged`/`.noFocus` now — these two
                            // are unreachable but kept so the switch stays
                            // exhaustive over `WindowRetagResult`.
                            case .oldUndefined:
                                return "window --retag \(shown): "
                                    + "no such tag \(parts[0])"
                            case .vocabFull:
                                return "window --retag \(shown): "
                                    + "vocabulary full"
                            }
                        }
                    }

                case let s where s.hasPrefix("scratchpad-stash:"):
                    let name = String(s.dropFirst("scratchpad-stash:".count))
                    self.runBackendCommand { bk in
                        bk.stashScratchpad(name) ? nil
                            : "scratchpad --stash \(name): no focused window"
                    }

                case let s where s.hasPrefix("scratchpad-toggle:"):
                    let name = String(s.dropFirst("scratchpad-toggle:".count))
                    self.runBackendCommand { bk in
                        bk.toggleScratchpad(name) ? nil
                            : "scratchpad --toggle \(name): no such shelf"
                    }

                case let s where s.hasPrefix("scratchpad-release:"):
                    let name = String(s.dropFirst("scratchpad-release:".count))
                    self.runBackendCommand { bk in
                        bk.releaseScratchpad(name) ? nil
                            : "scratchpad --release \(name): no such shelf"
                    }

                case let s where s.hasPrefix("set-layout:"):
                    let name = String(s.dropFirst("set-layout:".count))
                    self.dispatchSetLayout(name)

                case "retile":
                    self.dispatchRetile()

                case "workspace-balance":
                    self.runBackendCommand { bk in
                        bk.balanceActiveWorkspace(); return nil
                    }

                case let s where s.hasPrefix("workspace-rotate:"):
                    let deg = Int(
                        s.dropFirst("workspace-rotate:".count)) ?? 0
                    self.runBackendCommand { bk in
                        bk.rotateActiveWorkspace(degrees: deg); return nil
                    }

                case let s where s.hasPrefix("workspace-mirror:"):
                    let axis: MirrorAxis =
                        s.dropFirst("workspace-mirror:".count) == "vertical"
                        ? .vertical : .horizontal
                    self.runBackendCommand { bk in
                        bk.mirrorActiveWorkspace(axis); return nil
                    }

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

    /// CLI `facet --view tree --loading MS`: paint the tree
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
        // The chord `--view tree --loading` path opens the tree to mask a
        // mac-desktop switch and used to leave it passive forever (the
        // `--loading` early-return in `dispatchView` skips `enterActive`).
        // Arm a deferred activate: `apply()` flips the tree into keyboard
        // nav the moment the skeleton gives way to the new mac desktop's
        // real content — after the switch settles, never during it.
        loadingWantsActive = true
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
    private func dispatchView(_ name: String, geom: NSRect?,
                              loadingMs: Int? = nil, edge: RailEdge? = nil) {
        // Views are mutually exclusive: requesting any non-grid view
        // drops the full-screen grid overlay first. This is also how
        // the grid closes on a mac-desktop switch — the chord ctrl+→
        // binding fires `--view tree --loading` just *before* the
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
            // `--loading` paints a pre-switch skeleton and returns — a
            // background mask that never takes key (so it can't steal
            // focus mid mac-desktop switch). A normal show opens the
            // tree directly in keyboard-nav mode (enterActive: key +
            // `.regular`) so the arrows / Enter / s / t work the moment
            // it appears — the old `--active` flag is folded in here.
            // Acting on a window drops key first (handleClick / Enter
            // call exitActive) so same-app focus survives (#66).
            if let ms = loadingMs { showLoading(durationMs: ms); return }
            enterActive()
        case "grid":
            // Geom is ignored (grid is always full-screen); the
            // overlay is always key/active by nature.
            showGrid()
        case "rail":
            // Geom is a no-op — the rail is a passive overview bar
            // (never key). ``+edge`` (CLI ``--edge``) picks which
            // screen edge it docks against; nil falls back to the
            // ``[rail] edge`` config default.
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

    /// P6: run a catalog-touching backend command on the serial `cliQueue`
    /// — the single catalog serialization point — then surface any error +
    /// schedule a reconcile back on main. `body` runs on cliQueue and
    /// returns the error message to show (nil = success). This is the DNC
    /// dispatch twin of the grid / rail / tag-panel paths, which already
    /// wrap their backend calls in `cliQueue.async`; before P6 the DNC
    /// switch was the one surface that mutated the catalog on the main
    /// thread, racing the cliQueue reconcile.
    func runBackendCommand(reconcileAfter: TimeInterval = 0.05,
                           _ body: @escaping @Sendable (any WindowBackend) -> String?) {
        let bk = backend
        cliQueue.async {
            let err = body(bk)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let err { self.setError(err) }
                    self.scheduleReconcile(after: reconcileAfter)
                }
            }
        }
    }

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
            let wsName = String(s.dropFirst("name:".count))
            runBackendCommand { bk in
                bk.switchWorkspace(named: wsName, autoFocus: true); return nil
            }
        default:       dispatchWorkspace(Int(arg) ?? 0)
        }
    }

    /// One addressable section in tree order: its display label, the
    /// `ActiveSection` it activates (nil = an unassigned section — §G — which
    /// has no workspace/lens behind it), plus the stable `ProjectedSection.id`
    /// (nil only on the degrade-workspace path, which addresses by index). §G:
    /// an unassigned hit (`section == nil`) FOCUSES ITS FIRST WINDOW via the
    /// `sectionID` rather than erroring — see `dispatchSectionFocus`.
    private struct SectionAddr {
        let label: String
        let section: ActiveSection?
        let sectionID: String?
    }

    /// The ordered, addressable section list AS THE TREE RENDERS IT. Section
    /// model → the projected sections (already reorder-applied in `apply()`);
    /// degrade (no `[[desktop.N.section]]`) → the displayed workspaces with the
    /// session reorder override applied, each a workspace section. Mirrors
    /// `Controller.reorderSection`'s two-mode handling so `--focus N` matches
    /// the numbers the user sees.
    private func addressableSections() -> [SectionAddr] {
        if !lastSections.isEmpty {
            return lastSections.map { ps in
                switch ps.sectionType {
                case .workspace:
                    // sourceWorkspaceIndex is 0-based (== Workspace.index);
                    // ActiveSection is 1-based → +1 (mirrors Controller+Grid).
                    return SectionAddr(label: ps.label,
                        section: ps.sourceWorkspaceIndex.map { .workspace($0 + 1) },
                        sectionID: ps.id)
                case .lens:
                    // A0: identity = the stable id; `--focus index:N` activates
                    // by id. `label:NAME` addressing stays label-based (display).
                    return SectionAddr(label: ps.label, section: .lens(ps.id),
                                       sectionID: ps.id)
                case .unassigned:
                    // §G: no workspace/lens behind it → `section: nil`, but the
                    // stable id lets `dispatchSectionFocus` focus its FIRST
                    // WINDOW instead of erroring (the unified focus helper).
                    return SectionAddr(label: ps.label, section: nil,
                                       sectionID: ps.id)
                }
            }
        }
        let key = currentMacDesktopOrdinal() ?? -1
        return SectionOrder.applyWorkspaces(macDesktopSectionOrder[key],
                                            to: lastWorkspaces)
            .map { SectionAddr(label: $0.name,
                               section: .workspace($0.index + 1), sectionID: nil) }
    }

    /// `facet section --focus`: resolve a 1-based tree-order index (`index:N`)
    /// or a section label (`label:LABEL`) to its `ActiveSection` and activate
    /// it. Runs on main (DNC). An unknown index / label, or an unassigned
    /// section (no workspace/lens behind it), is loud-but-non-fatal
    /// (`setError`, no change) per facet's typo stance.
    private func dispatchSectionFocus(_ arg: String) {
        let list = addressableSections()
        let hit: SectionAddr?
        if arg.hasPrefix("index:") {
            let n = Int(arg.dropFirst("index:".count)) ?? 0
            guard n >= 1, n <= list.count else {
                let hint = list.isEmpty ? "no sections" : "1..\(list.count)"
                setError("section --focus \(n): out of range (\(hint))")
                scheduleReconcile(after: 0.05)
                return
            }
            hit = list[n - 1]
        } else if arg.hasPrefix("label:") {
            let label = String(arg.dropFirst("label:".count))
            guard let h = list.first(where: { $0.label == label }) else {
                setError("section --focus \(label): no such section")
                scheduleReconcile(after: 0.05)
                return
            }
            hit = h
        } else {
            return      // malformed payload (shouldn't happen)
        }
        guard let hit else { return }
        guard let section = hit.section else {
            // §G: an unassigned section has no workspace/lens to activate, but
            // it DOES hold orphan windows — focus its first one (the unified
            // focus helper, shared with the grid/rail .unassigned picks + the
            // tree header click). A truly non-focusable nil (no id — the
            // degrade path never emits one) keeps the loud error.
            if let id = hit.sectionID {
                focusFirstWindow(inSectionID: id)
                return
            }
            setError("section --focus \"\(hit.label)\": unassigned sections "
                + "aren't focusable (no workspace or lens behind them)")
            scheduleReconcile(after: 0.05)
            return
        }
        activateSection(section, autoFocus: true)
    }

    /// §G unified focus helper: focus the FIRST window of the section with
    /// stable id `id` (an `.unassigned` receptacle in practice — its orphan
    /// windows have no workspace/lens to switch to). Looks the section up in
    /// `lastSections`, takes `.windows.first`, and reveals + focuses it via the
    /// SAME window path the tree window-row click uses (`revealWindow` then
    /// `focusWindow(postSwitch: false)`) — NO workspace switch, ActiveSection
    /// unchanged (per plan: an orphan's home WS is the active one, or none).
    /// Backs THREE surfaces: `dispatchSectionFocus` (CLI), the grid/rail
    /// `.unassigned` pick routing, and the tree header click. A missing /
    /// empty section is loud-but-non-fatal (nothing to focus).
    func focusFirstWindow(inSectionID id: String) {
        guard let sec = lastSections.first(where: { $0.id == id }),
              let w = sec.windows.first else {
            setError("section is empty — nothing to focus")
            scheduleReconcile(after: 0.05)
            return
        }
        // Mirror SidebarView+Drag.handleClick's window case EXACTLY — a lens is
        // a pure VIEW (t-0021) that moves nothing, so only two states remain (an
        // unassigned orphan can be in either):
        //   • HIDDEN (Cmd+H'd / minimized, `isOnscreen == false`): `revealWindow`
        //     un-hides AND focuses. NOT an unconditional `revealWindow` — that
        //     whole-app `unhide()`s an already-visible orphan.
        //   • on-screen: just focus (`postSwitch: false` → `Focus.withRetry`).
        // No workspace switch in any branch — ActiveSection unchanged (plan §4).
        Log.debug("focusFirstWindow: section=\(id) → window \(w.id.serverID)")
        if w.isOnscreen == false {
            let bk = backend
            cliQueue.async { bk.revealWindow(w.id) }
        } else {
            focusWindow(w, postSwitch: false)
        }
    }

    /// §E: rename the section at 1-based tree-order index `n` to `label`,
    /// the runtime (session-only) twin of `--focus N`. Runs on main (DNC).
    /// Branch on the addressed section's kind (same tree order `--focus`
    /// resolves through):
    ///   • workspace → route to `backend.renameWorkspace(at:to:)` (the catalog
    ///     owns workspace names — `""` reverts to the number).
    ///   • lens → a DISPLAY-only override on `sectionLabelOverride` (id-keyed,
    ///     never the backend): a non-empty `label` SETS it; an empty / all-
    ///     whitespace `label` DELETES the key (revert to the config label —
    ///     storing `""` would blank the header). Re-render via `apply`.
    ///   • unassigned → §G: SAME session-only override path as lens (id =
    ///     `"unassigned:<declOrder>"`, a valid override key — `applyLabelOverrides`
    ///     relabels `.unassigned` too). Non-empty SETS, empty REVERTS to the
    ///     config label.
    /// Section-model OFF (degrade — `lastSections` empty) → every slot is a
    /// workspace; resolve `n` against the reorder-applied workspace list (the
    /// same numbers `--focus` + `sectionHeaderDisplay`'s degrade branch show)
    /// and route to `renameWorkspace`. An out-of-range `n` is loud-but-non-fatal.
    /// E2 GUI deferred-commit entry (section model): rename the section with
    /// the STABLE `sectionID` captured when the inline editor opened. The editor
    /// is long-lived (the user types), so `lastSections` can reorder / gain /
    /// lose a section — or be replaced by a mac-desktop swap — between open and
    /// commit. Re-resolve the id to its CURRENT 1-based position right here (and
    /// confirm the mac desktop captured at open still matches) before delegating
    /// to the positional `renameSection`, so a shifted slot can't be renamed.
    /// Gone id / desktop changed → loud `setError`, no rename. Mirrors how the
    /// lens-layout path targets by `sec.id` (identity = id, campaign rule).
    func renameSection(sectionID: String, capturedOrdinal: Int?, to label: String) {
        guard currentMacDesktopOrdinal() == capturedOrdinal else {
            setError("section rename: mac desktop changed — cancelled")
            scheduleReconcile(after: 0.05)
            return
        }
        guard let pos0 = lastSections.firstIndex(where: { $0.id == sectionID }) else {
            setError("section rename: section no longer exists — cancelled")
            scheduleReconcile(after: 0.05)
            return
        }
        renameSection(indexN1Based: pos0 + 1, to: label)
    }

    /// E2 GUI deferred-commit entry (degrade — `lastSections` empty): rename the
    /// workspace identified by its STABLE 0-based `Workspace.index` captured at
    /// open. Re-resolve to the CURRENT 1-based display position in the
    /// reorder-applied list at commit (and confirm the captured mac desktop is
    /// still on screen) so a reorder / swap between open and commit can't
    /// mistarget. Gone / desktop changed → loud, no rename.
    func renameSection(workspaceIndex idx: Int, capturedOrdinal: Int?, to label: String) {
        guard currentMacDesktopOrdinal() == capturedOrdinal else {
            setError("section rename: mac desktop changed — cancelled")
            scheduleReconcile(after: 0.05)
            return
        }
        let key = currentMacDesktopOrdinal() ?? -1
        let wss = SectionOrder.applyWorkspaces(
            macDesktopSectionOrder[key], to: lastWorkspaces)
        guard let pos0 = wss.firstIndex(where: { $0.index == idx }) else {
            setError("section rename: workspace no longer exists — cancelled")
            scheduleReconcile(after: 0.05)
            return
        }
        renameSection(indexN1Based: pos0 + 1, to: label)
    }

    func renameSection(indexN1Based n: Int, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        // Degrade path: no section model here → all workspaces.
        guard !lastSections.isEmpty else {
            let key = currentMacDesktopOrdinal() ?? -1
            let wss = SectionOrder.applyWorkspaces(
                macDesktopSectionOrder[key], to: lastWorkspaces)
            guard n >= 1, n <= wss.count else {
                let hint = wss.isEmpty ? "no sections" : "1..\(wss.count)"
                setError("section --rename \(n): out of range (\(hint))")
                scheduleReconcile(after: 0.05)
                return
            }
            let pos1 = wss[n - 1].index + 1     // 1-based wire position
            Log.debug("renameSection: degrade n=\(n) → workspace \(pos1) "
                + "→ \"\(trimmed)\"")
            runBackendCommand { bk in
                bk.renameWorkspace(at: pos1, to: trimmed); return nil
            }
            return
        }
        guard n >= 1, n <= lastSections.count else {
            setError("section --rename \(n): out of range "
                + "(1..\(lastSections.count))")
            scheduleReconcile(after: 0.05)
            return
        }
        let sec = lastSections[n - 1]
        switch sec.sectionType {
        case .workspace:
            // sourceWorkspaceIndex is 0-based (== Workspace.index); the backend
            // wants a 1-based position (mirrors `addressableSections`). nil is
            // defensive (a workspace section always carries one).
            guard let src = sec.sourceWorkspaceIndex else {
                setError("section --rename \(n): no workspace behind it")
                scheduleReconcile(after: 0.05)
                return
            }
            let pos1 = src + 1
            Log.debug("renameSection: n=\(n) workspace \(pos1) → \"\(trimmed)\"")
            runBackendCommand { bk in
                bk.renameWorkspace(at: pos1, to: trimmed); return nil
            }
        case .lens, .unassigned:
            // §G: lens AND unassigned share the SAME session-only display-label
            // override (`applyLabelOverrides` relabels both; the ids
            // `"section:…"` / `"unassigned:…"` are equally valid override keys).
            // The override READ (the projection seam in `apply()`) is gated
            // behind a non-nil mac-desktop ordinal, so it NEVER consults a -1
            // bucket. Writing under `?? -1` here would land the override in a
            // bucket the projection can't read → a silent no-op during a
            // transient SkyLight nil-ordinal blip, plus an orphaned -1 entry.
            // Refuse loudly instead: reaching here means the section model was
            // active (non-nil ordinal) moments ago, so a nil here is a transient
            // the user can simply retry. (The degrade path above keeps `?? -1` —
            // its `macDesktopSectionOrder` read DOES consult -1.)
            guard let key = currentMacDesktopOrdinal() else {
                setError("section --rename \(n): mac desktop unknown (try again)")
                scheduleReconcile(after: 0.05)
                return
            }
            if trimmed.isEmpty {
                // Empty → revert to the config label by DELETING the override
                // key (storing "" would blank the header).
                sectionLabelOverride[key]?.removeValue(forKey: sec.id)
                if sectionLabelOverride[key]?.isEmpty == true {
                    sectionLabelOverride.removeValue(forKey: key)
                }
                Log.debug("renameSection: n=\(n) section id=\(sec.id) → revert config")
            } else {
                // Store the TRIMMED label so a padded label (`"  Web  "`)
                // renders identically for lens / unassigned / workspace sections —
                // the workspace branch passes `trimmed` too (the revert gesture is
                // already keyed on `trimmed.isEmpty` above).
                sectionLabelOverride[key, default: [:]][sec.id] = trimmed
                Log.debug("renameSection: n=\(n) section id=\(sec.id) → \"\(trimmed)\"")
            }
            apply(lastWorkspaces)       // re-render with the new display label
        }
    }

    /// Section/lens model (PR6): set the ACTIVE lens to the `type="lens"`
    /// section labelled `label`, or clear it with `nil`. Session-only +
    /// per-mac-desktop (reset on a swap, never persisted). Validated against
    /// the LIVE section config — an unknown label is loud-but-non-fatal
    /// (`setError`, no change), matching facet's typo philosophy. On a real
    /// change it re-renders so the lens's tree header lights up (`pal.primary`)
    /// — grid/rail narrowing by the active lens lands in PR7.
    ///
    /// Tag-unification Phase 1: the active section-lens is now a REAL hide,
    /// driven by the backend (the catalog is the authority). This validates
    /// the label against the LIVE section config (nice error messages),
    /// A0-resolves it to the stable section id, then hands the id to
    /// `activateLensID` (the id-core: optimistically lights the tree header +
    /// routes through `backend.activateSection` on `cliQueue`, where the catalog
    /// gathers the matching windows + parks the rest). `currentActiveSection` is
    /// the view's highlight mirror — set optimistically to `.lens(id)` and read
    /// back from the catalog on a mac-desktop swap / WS switch (`apply()`). A
    /// `nil` CLEAR returns the active section to the spatial workspace
    /// (`.workspace(N)`) and routes through `setSectionLens(nil)` (a clear is a
    /// deactivation, not a switch). `autoFocus`: the CLI / hotkey path passes
    /// `true`; the in-panel tree lens-header toggle passes `false`.
    func setActiveLens(_ label: String?, autoFocus: Bool = false) {
        guard let label else {
            if case .lens = currentActiveSection {
                currentActiveSection = .workspace(activeWSIndex(in: lastWorkspaces))
                runBackendCommand { bk in
                    bk.setSectionLens(nil, autoFocus: autoFocus); return nil
                }
                apply(lastWorkspaces)        // re-render: drop the highlight
            }
            return
        }
        // Read the ordinal FRESH (not the cached lastRenderedMacDesktopOrdinal):
        // validation must check the mac desktop on screen NOW, and syncing the
        // swap-detector to this same value below stops the apply() call from
        // mistaking this command for a swap and wiping the just-set lens.
        let ordinal = currentMacDesktopOrdinal()
        guard config.isSectionModelActive(ordinal: ordinal) else {
            setError("lens \(label): no section model on this mac desktop")
            scheduleReconcile(after: 0.05)      // surface lastError via status
            return
        }
        let lenses = lensSectionLabels(ordinal: ordinal)
        guard lenses.contains(label) else {
            let have = lenses.isEmpty ? "none" : lenses.joined(separator: ", ")
            setError("lens \(label): no such lens section (have: \(have))")
            scheduleReconcile(after: 0.05)      // surface lastError via status
            return
        }
        // A0: the human label is identity-decoupled now — resolve it to the
        // stable section id (1:1 while labels are unique), then activate by id.
        // A nil id is defensive (validated above, so it shouldn't happen).
        guard let id = lensID(forLabel: label, ordinal: ordinal) else {
            setError("lens \(label): no such lens section")
            scheduleReconcile(after: 0.05)
            return
        }
        activateLensID(id, ordinal: ordinal, autoFocus: autoFocus)
    }

    /// A0 id-core: activate the lens with the resolved stable `id` — no label
    /// lookup. The label-validating entry is `setActiveLens` (`facet lens NAME`
    /// / view picks); the CLI `--focus index:N` path reaches here via
    /// `activateSection(.lens(id))`. Idempotent — `.workspace(N) != .lens(id)`
    /// structurally, so a re-activation after a WS switch (which cleared the
    /// lens) is never swallowed (the EX-0.5 double-SSOT bug, fixed at the root
    /// by EX-1).
    func activateLensID(_ id: String, ordinal: Int?, autoFocus: Bool) {
        guard currentActiveSection != .lens(id) else { return }
        currentActiveSection = .lens(id)
        // Sync the swap-detector to the ordinal so the synchronous apply() below
        // (same desktop, no main-actor suspension) sees no ordinal change and
        // keeps the lens.
        hasRenderedMacDesktop = true
        lastRenderedMacDesktopOrdinal = ordinal
        runBackendCommand { bk in
            bk.activateSection(.lens(id), autoFocus: autoFocus); return nil
        }
        apply(lastWorkspaces)                // re-render: light up its header
    }

    /// EX-1 Controller-side activation throughline: route to the validated
    /// per-kind entry — lens → `setActiveLens` (label lookup, idempotent guard,
    /// section-model gate); workspace → `dispatchWorkspace` (P6 range check).
    /// Both ultimately reach `backend.activateSection`. The user-facing single
    /// `facet section` verb is EX-4; here it is the internal seam the CLI
    /// dispatch and (in EX-2) grid/rail clicks funnel through.
    func activateSection(_ section: ActiveSection, autoFocus: Bool = true) {
        switch section {
        // A0: `.lens` now carries the resolved stable id (e.g. from
        // `addressableSections` / `--focus index:N`), so route straight to the
        // id-core — no label round-trip. The label-validating entry is
        // `setActiveLens` (the CLI `facet lens NAME`); §A: grid/rail/tree view
        // picks now carry the stable id and call `activateLensID` directly.
        case .lens(let id):     activateLensID(id, ordinal: currentMacDesktopOrdinal(),
                                               autoFocus: autoFocus)
        case .workspace(let n): dispatchWorkspace(n, autoFocus: autoFocus)
        }
    }

    private func dispatchWorkspaceRelative(_ target: RelativeWorkspace) {
        // Same focus contract as the absolute path: no explicit window
        // pick, so the backend auto-focuses the destination's
        // last-touched window (memory [[facet-ws-switch-focus-management]]).
        runBackendCommand { bk in
            bk.switchWorkspaceRelative(target, autoFocus: true); return nil
        }
    }

    /// Switch to the Nth workspace (1-indexed from the user; the
    /// backend takes 0-indexed). Out-of-range silently no-ops (with
    /// a debug log) — the DNC receiver shouldn't exit the server
    /// just because a stale hotkey points past the current WS count.
    /// Idempotent: switching to the current WS is a backend no-op.
    /// `autoFocus` (default `true`) is forwarded to the throughline: the CLI
    /// `--focus N` path wants `true`; a caller that focuses its own target
    /// afterward (the tree window-row click) passes `false`.
    private func dispatchWorkspace(_ n: Int, autoFocus: Bool = true) {
        // Reflect the activation in the view mirror UP-FRONT so it never goes
        // stale when the backend clears a lens WITHOUT a `wsSwitched` read-back —
        // the same-index-clear path (`--focus` / click the ALREADY-active
        // workspace while a lens is active): the backend clears the lens, but
        // `apply()` sees no switch, so without this the mirror keeps a dead
        // `.lens(…)` and the next `lens NAME` is swallowed by the idempotent
        // guard (found in EX-1 host-verify — the EX-0.5 bug class via a new
        // path). In-range guard against the main-actor snapshot so a stale /
        // out-of-range `n` doesn't set a bogus `.workspace(N)`; the authoritative
        // range check + error stay inside the closure.
        if n >= 1, n <= lastWorkspaces.count {
            currentActiveSection = .workspace(n)
        }
        // P6: the range check reads `workspaces()` (which runs the catalog
        // reconcile) and the switch mutates it — both must happen in ONE
        // cliQueue block so a poll reconcile can't interleave between them.
        runBackendCommand { bk in
            let count = bk.workspaces().count
            guard n >= 1, n <= count else {
                let hint = count > 0 ? "1..\(count)" : "no workspaces available"
                return "workspace \(n) out of range (\(hint))"
            }
            // CLI `workspace --focus N`: no explicit window pick, so the
            // backend auto-focuses the last-touched window of the destination
            // (or activates Finder if empty) when `autoFocus`. See memory
            // [[facet-ws-switch-focus-management]]. EX-1: route through the
            // activateSection throughline (clears any active lens). NOT
            // optimistic — the highlight updates via the apply() read-back on
            // the reconcile (wsSwitched). `n` is 1-based (range-checked above).
            bk.activateSection(.workspace(n), autoFocus: autoFocus)
            return nil
        }
    }

    /// Move the currently-focused window to the Nth workspace
    /// (1-indexed from the user; backend takes 0-indexed). Silent
    /// no-op (debug log only) when no focused window or N is out
    /// of range — a stale hotkey on an empty mac desktop shouldn't
    /// take down the server.
    private func dispatchWindowMove(_ n: Int, follow: Bool = false) {
        // P6: range check + focused-window read + move (+ optional follow
        // switch) all in ONE cliQueue block, so the id is read at the same
        // serialization point the move consumes it and no reconcile slips
        // between the two backend calls.
        runBackendCommand { bk in
            let count = bk.workspaces().count
            guard n >= 1, n <= count else {
                let hint = count > 0 ? "1..\(count)" : "no workspaces available"
                return "window --move-to \(n) out of range (\(hint))"
            }
            guard let id = bk.focusedWindow() else {
                return "window --move-to \(n): no focused window"
            }
            bk.moveWindow(id, toWorkspaceIndex: n - 1)
            // send-and-follow: switch the active workspace to the
            // destination so focus follows the window over. autoFocus
            // lands on the just-moved window (now the last-touched
            // member there). Without --follow the window departs and
            // the user stays put.
            if follow {
                bk.switchWorkspace(toIndex: n - 1, autoFocus: true)
            }
            return nil
        }
    }

    private func dispatchToggle(_ name: String) {
        switch name {
        // Toggling ON opens the tree active (same entry as `--view
        // tree`); OFF hides it. Mirrors the show path so a toggle
        // hotkey lands in keyboard nav, not a passive panel.
        case "tree": if userHidden { enterActive() } else { setHidden(true) }
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
            setError("workspace --layout \(name): no active workspace")
            return
        }
        let idx = active.index
        runBackendCommand { bk in
            bk.setLayoutMode(workspaceIndex: idx, mode: name); return nil
        }
    }

    /// `facet workspace --retile`: ask the backend to re-apply the active
    /// workspace's layout. A backend that delegates tiling to the OS
    /// would treat this as a no-op.
    private func dispatchRetile() {
        runBackendCommand { bk in bk.retileActiveWorkspace(); return nil }
    }

    /// `facet window --toggle-float` / `--toggle-orientation`:
    /// thin wrapper around `backend.perform`. The "no focused
    /// window" guard lives in the backend (NativeAdapter exits
    /// early when `focusedWindow()` is nil); we just log the
    /// dispatch here for `FACET_DEBUG` tracing.
    private func dispatchWindowAction(_ action: WindowAction) {
        Log.debug("dispatchWindowAction \(action)")
        runBackendCommand { bk in bk.perform(action); return nil }
    }

    /// Live re-theme from `facet --theme ...`. Runtime-only — the change
    /// does NOT persist across restarts, and it OVERRIDES the per-view
    /// `[tree]/[grid]/[rail].theme` keys (every surface shows `name`) until
    /// the user edits a theme key in config (then config wins) or issues
    /// another `--theme`. config.toml is the single source of truth; to
    /// make a pick stick, edit ``[theme] name`` in the user's config.
    func applyThemeOverride(_ name: String) {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Log.debug("applyThemeOverride name=\(key)")
        themeOverride = key
        resolveSurfacePalettes()
        reapplyThemes()
    }
}
