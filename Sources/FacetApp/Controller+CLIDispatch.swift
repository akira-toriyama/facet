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

                // Section/lens model (PR6) — distinct from the tag-bitmask
                // `lens:` above: activate / clear the ACTIVE lens (a
                // `type="lens"` section, keyed by its label). The label can
                // hold any character (incl. `:`), so the whole remainder is
                // the label — no further parsing.
                case let s where s.hasPrefix("lens-section:"):
                    self.setActiveLens(
                        String(s.dropFirst("lens-section:".count)))
                case "lens-clear":
                    self.setActiveLens(nil)

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
                                + "no focused window / not tag mode"
                    }

                case let s where s.hasPrefix("window-tag:"):
                    let name = String(s.dropFirst("window-tag:".count))
                    self.runBackendCommand { bk in
                        bk.addTagToFocusedWindow(name) ? nil
                            : "window --tag \(name): "
                                + "no focused window / not tag mode"
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
                                    + "no focused window / not tag mode"
                            case .oldUndefined:
                                return "window --retag \(shown): "
                                    + "no such tag \(parts[0])"
                            case .vocabFull:
                                return "window --retag \(shown): "
                                    + "vocabulary full (63 tags)"
                            }
                        }
                    }

                case let s where s.hasPrefix("tag-add:"):
                    let name = String(s.dropFirst("tag-add:".count))
                    self.runBackendCommand { bk in
                        bk.addTag(name) ? nil
                            : "tag --add \(name): not tag mode, "
                                + "or vocabulary full (63 tags)"
                    }

                case let s where s.hasPrefix("tag-remove:"):
                    let name = String(s.dropFirst("tag-remove:".count))
                    self.runBackendCommand { bk in
                        bk.removeTag(name) ? nil
                            : "tag --remove \(name): no such tag, "
                                + "or not tag mode"
                    }

                case let s where s.hasPrefix("tag-rename:"):
                    // Payload OLD:NEW — neither half can contain ':'
                    // (the CLI's parseTagName forbids it), so one split
                    // is unambiguous.
                    let body = String(s.dropFirst("tag-rename:".count))
                    let parts = body
                        .split(separator: ":", maxSplits: 1,
                               omittingEmptySubsequences: false)
                        .map(String.init)
                    let shown = body.replacingOccurrences(of: ":", with: " ")
                    self.runBackendCommand { bk in
                        (parts.count == 2
                            && bk.renameTag(parts[0], to: parts[1])) ? nil
                            : "tag --rename \(shown): no such tag, "
                                + "or the new name is already in use"
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

    /// grid / rail are workspace-only surfaces; under `[grouping]
    /// by="tag"` they must never appear (tag mode shows only the
    /// tree). The CLI rejects `--view/--hide/--toggle grid|rail`
    /// (exit 2) and `fatalConfigErrors` rejects a `default-view="grid"`
    /// startup, so a grid/rail op only reaches a dispatch method here
    /// via a stale chord or a hand-rolled DNC post that slipped past
    /// those gates. Returns true → the caller should no-op the op.
    /// `Log.line` (not `setError`) — it's a should-never-happen
    /// backstop, not a user-facing error worth a status toast.
    private func rejectsWorkspaceOnlyView(_ name: String) -> Bool {
        guard config.effectiveGrouping == .tag,
              name == "grid" || name == "rail" else { return false }
        Log.line("\(name) is a workspace-only view — ignored under "
            + "[grouping] by=\"tag\" (should have been rejected at the CLI)")
        return true
    }

    /// Open (or activate) ``name``. Idempotent — re-issuing the
    /// same view doesn't toggle it off; use ``dispatchToggle`` /
    /// ``dispatchHide`` for that.
    private func dispatchView(_ name: String, active: Bool, geom: NSRect?,
                              loadingMs: Int? = nil, edge: RailEdge? = nil) {
        guard !rejectsWorkspaceOnlyView(name) else { return }
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
            if let ms = loadingMs { showLoading(durationMs: ms); return }
            if active { enterActive() } else { setHidden(false) }
        case "grid":
            // ``+active`` is silently a no-op for grid — the
            // overlay is always key/active by nature. Geom is
            // likewise ignored (grid is always full-screen).
            showGrid()
        case "rail":
            // ``+active`` / geom are no-ops — the rail is a passive
            // overview bar (never key). ``+edge`` (CLI ``--edge``)
            // picks which screen edge it docks against; nil falls back
            // to the ``[rail] edge`` config default.
            showRail(edge: edge ?? config.effectiveRailEdge)
        default:
            Log.debug("dispatchView unknown=\(name) — ignored")
        }
    }

    private func dispatchHide(_ name: String) {
        guard !rejectsWorkspaceOnlyView(name) else { return }
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

    /// Route a `lens:` payload (M11-3 tag mode; #228 multi-tag). Parsing
    /// the `all` / `VERB:CSV` wire form lives in the pure, unit-tested
    /// `LensSpec.parse`; the backend resolves the names strictly and
    /// surfaces an unknown-tag error itself, so this just dispatches and
    /// schedules a repaint.
    private func dispatchLensTarget(_ arg: String) {
        guard let spec = LensSpec.parse(arg) else {
            Log.debug("dispatchLensTarget malformed=\(arg) — ignored")
            return
        }
        runBackendCommand { bk in bk.setLens(spec); return nil }
    }

    /// Section/lens model (PR6): set the ACTIVE lens to the `type="lens"`
    /// section labelled `label`, or clear it with `nil`. Session-only +
    /// per-mac-desktop (reset on a swap, never persisted). Validated against
    /// the LIVE section config — an unknown label is loud-but-non-fatal
    /// (`setError`, no change), matching facet's typo philosophy. On a real
    /// change it re-renders so the lens's tree header lights up (`pal.primary`)
    /// — grid/rail narrowing by the active lens lands in PR7.
    ///
    /// Unlike `dispatchLensTarget` (the tag-bitmask lens) this touches NO
    /// backend / catalog state — the active lens is pure view-layer state — so
    /// it runs entirely on the main actor with no `cliQueue` hop.
    func setActiveLens(_ label: String?) {
        guard let label else {
            if currentActiveLens != nil {
                currentActiveLens = nil
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
            setError("lens --section \(label): no section model on this "
                + "mac desktop")
            scheduleReconcile(after: 0.05)      // surface lastError via status
            return
        }
        let lenses = lensSectionLabels(ordinal: ordinal)
        guard lenses.contains(label) else {
            let have = lenses.isEmpty ? "none" : lenses.joined(separator: ", ")
            setError("lens --section \(label): no such lens section "
                + "(have: \(have))")
            scheduleReconcile(after: 0.05)      // surface lastError via status
            return
        }
        guard currentActiveLens != label else { return }   // idempotent
        currentActiveLens = label
        // Sync the swap-detector to the ordinal just validated against, so the
        // synchronous apply() below (same desktop, no main-actor suspension)
        // sees no ordinal change and keeps the lens.
        hasRenderedMacDesktop = true
        lastRenderedMacDesktopOrdinal = ordinal
        apply(lastWorkspaces)                // re-render: light up its header
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
    private func dispatchWorkspace(_ n: Int) {
        // P6: the range check reads `workspaces()` (which runs the catalog
        // reconcile) and the switch mutates it — both must happen in ONE
        // cliQueue block so a poll reconcile can't interleave between them.
        runBackendCommand { bk in
            let count = bk.workspaces().count
            guard n >= 1, n <= count else {
                let hint = count > 0 ? "1..\(count)" : "no workspaces available"
                return "workspace \(n) out of range (\(hint))"
            }
            // CLI `workspace --focus N`: no explicit window pick, so let
            // the backend auto-focus the last-touched window of the
            // destination (or activate Finder if empty). See memory
            // [[facet-ws-switch-focus-management]].
            bk.switchWorkspace(toIndex: n - 1, autoFocus: true)
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
        guard !rejectsWorkspaceOnlyView(name) else { return }
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
