// Top-level orchestrator. Wires:
//   - a ``WindowBackend`` (rift adapter today)
//   - the tree view (``SidebarView``) + its panel chrome
//     (``PanelHost``)
//   - the event stream (``backend.events`` → AsyncStream Task →
//     debounced refresh)
//   - the periodic poll fallback (catches backends that don't emit
//     events, e.g. rift before subscribe lands)
//   - ``AXTitles`` resolve to fill in titles the backend left blank
//   - the focus retry state machine (``Focus.withRetry`` /
//     ``Focus.assert``)
//
// Conforms to ``TreeController`` so ``SidebarView`` / ``GripView``
// can talk to it without knowing about any of the above.
//
// Things explicitly NOT here:
//   - grid view lifecycle              → step 6f
//   - keyboard-nav (--active) + search → step 6g
//   - distributed-notification CLI IPC → step 6h
//
// ``previewTargetChanged`` / ``exitActive`` are stubbed here and
// wired up in those follow-up steps.

import AppKit
import FacetCore
import FacetView
import FacetViewTree
import FacetViewGrid
import FacetAdapterRift

@MainActor
final class Controller: NSObject {

    // MARK: - Wiring

    let backend: any WindowBackend
    private let config: FacetConfig
    private let panelHost: PanelHost
    private let sidebarView: SidebarView

    // MARK: - State

    /// Latest workspaces snapshot — held so the grid view can render
    /// immediately on first show without round-tripping the backend.
    private(set) var lastWorkspaces: [Workspace] = []
    private var userHidden = false
    /// Pauses refresh/apply while the user is mid-grip-drag, so a
    /// layout pass can't stomp the panel height the next mouseDragged
    /// is about to read (memory: grid-branch-grip-intermittent).
    private var isGripResizing = false
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

    // MARK: - Grid overview

    private var gridOverlay: GridOverlay?
    private var gridView: GridView?
    private var gridBackdrop: NSView?
    private var gridKbMonitor: Any?
    /// Remembered while the grid is up so we can restore exactly the
    /// pre-show visibility state on dismiss.
    private var treeWasHidden = false
    var isGridVisible: Bool { gridOverlay != nil }

    // MARK: - Active mode (kb-nav)

    private var kbMonitor: Any?
    /// Frontmost app at the moment ``enterActive`` was called, so
    /// ``exitActive(restore: true)`` can hand focus back.
    private var prevApp: NSRunningApplication?
    private let searchDelegate = SearchFieldDelegate()

    // MARK: - Subscription / polling

    private var eventTask: Task<Void, Never>?
    private var pollTimer: Timer?
    /// Catches backends that don't emit events for some changes
    /// (workspace renames, layout-mode switches via external CLI).
    /// 2 s mirrors ws-tabs's `fallbackPoll`.
    private let pollInterval: TimeInterval = 2.0
    /// Debounce window for event-driven refreshes — coalesces a
    /// burst of events into a single backend query.
    private let refreshDebounce: TimeInterval = 0.05

    // MARK: - Init

    init(backend: any WindowBackend, config: FacetConfig) {
        self.backend = backend
        self.config = config
        let view = SidebarView(
            frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: 400),
            backend: backend)
        self.sidebarView = view
        self.panelHost = PanelHost(view: view)
        super.init()
        view.controller = self
        panelHost.grip.controller = self
        if #available(macOS 14.0, *) { winPreview = WindowPreview() }
        searchDelegate.onChange = { [weak self] q in
            MainActor.assumeIsolated {
                self?.sidebarView.setQuery(q)
            }
        }
        panelHost.searchBar.field.delegate = searchDelegate
    }

    // MARK: - Lifecycle

    /// Start the controller: subscribe to backend events, schedule
    /// the fallback poll, run an initial refresh. Idempotent only
    /// in the sense that calling it twice will leak the previous
    /// event task — don't.
    func start() {
        Log.debug("controller start")
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.backend.events {
                await MainActor.run { self.requestRefresh() }
            }
        }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: pollInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        rescheduleThumbnailTimer()
        installCLIControl()
        refresh()
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
                switch cmd {
                case "show":   self.setHidden(false)
                case "hide":   self.setHidden(true)
                case "active": self.enterActive()
                case "quit":   NSApp.terminate(nil)
                case let s where s.hasPrefix("style:"):
                    self.applyStyle(
                        String(s.dropFirst("style:".count)))
                case let s where s.hasPrefix("view:"):
                    // Unknown view names are silently ignored (no
                    // fallback to another view — matches the
                    // ``--theme`` validator's policy of staying
                    // out of the user's way).
                    switch String(s.dropFirst("view:".count)) {
                    case "grid": self.toggleGrid()
                    default:     break
                    }
                default:
                    // Bare `facet --toggle` (no qualifier): flip
                    // the panel's hidden state.
                    self.setHidden(!self.userHidden)
                }
            }
        }
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
        panelHost.grip.needsDisplay = true
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
        // Skip backend round-trip while the user is mid-grip-drag —
        // both this refresh's eventual `apply` and the grip's
        // `resizeBy` mutate `panel.frame` on the main thread. The
        // mouseUp re-runs refresh() so no backend snapshot is lost.
        if isGripResizing { Log.debug("refresh skipped (gripResizing)"); return }
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
        // Keep the snapshot fresh even when hidden so the grid can
        // render immediately without a backend round-trip.
        lastWorkspaces = wss
        if let g = gridView {
            g.workspaces = wss
            g.activeIndex = wss.first(where: { $0.isActive })?.index
            g.layoutCells()       // refresh open grid on backend events
        }
        if firstRealApply, #available(macOS 14.0, *) {
            refreshThumbnailCache()
        }
        if userHidden { return }
        if isGripResizing { return }
        guard !wss.isEmpty, NSScreen.main != nil else {
            panelHost.hide(); return
        }
        sidebarView.frame.size.width = panelHost.userWidth
        sidebarView.forceRedraw()
        let contentH = sidebarView.update(wss, titles: titles)
        panelHost.layout(contentHeight: contentH,
                         searching: sidebarView.searching)
        if !panelHost.isVisible { panelHost.show() }
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
                for t in now {
                    wp.request(t.window) { [weak self] img, _, gotID in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            let cur = self.sidebarView.previewTargets()
                            guard let nt = cur.first(where: {
                                $0.window == gotID
                            }), Set(cur.map(\.window)).contains(gotID)
                            else { return }
                            self.previewPool.show(
                                gotID, img: img, frame: nt.frame)
                        }
                    }
                }
            }
        }
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

        // Solid near-black backdrop (no vibrancy) — matches the TS3
        // captures. The slight transparency keeps a hint of desktop
        // visible during the fade so it reads as "overlay opening"
        // not "screen blanked."
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
            labelPosition: config.effectiveGridLabelPosition,
            labelSize: config.effectiveGridLabelSize)
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
            // out (matches the TS3 feel).
            switch pick {
            case .workspace(let ws):
                cliQueue.async { bk.switchWorkspace(toIndex: ws) }
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
                // Shift+Space = lift the WHOLE cell for swap (kb
                // counterpart of mouse Shift-drag). Cmd+Space is
                // reserved by Spotlight system-wide; Shift+Space
                // has the same "modifier escalates Space's scope"
                // feel without the system conflict.
                if shift { gv.kbLiftWorkspace() } else { gv.kbLift() }
                return nil
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
    // Monitoring, no CGEventTap (that path was the silent-failure
    // trap ws-tabs deleted with the old hotkey).

    func enterActive() {
        Log.debug("enterActive")
        setHidden(false)                           // ensure visible
        if kbMonitor == nil {
            kbMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] e in
                guard let self, self.sidebarView.kbNav else { return e }
                return self.handleKbKey(e) ? nil : e
            }
        }
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
        if let m = kbMonitor {
            NSEvent.removeMonitor(m); kbMonitor = nil
        }
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

        // -- Normal keyboard nav --
        switch e.keyCode {
        case 53:      _exitActiveImpl(restore: true);    return true
        case 36, 76:  sidebarView.kbActivate();          return true
        case 125:     sidebarView.kbMove(1);             return true
        case 126:     sidebarView.kbMove(-1);            return true
        case 124:     sidebarView.kbJumpWS(1);           return true
        case 123:     sidebarView.kbJumpWS(-1);          return true
        case 48:      sidebarView.kbJumpWS(shift ? -1 : 1)
                      return true
        case 49:      sidebarView.kbContextMenu();       return true
        default:      break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "n" where ctrl: sidebarView.kbMove(1);      return true
        case "p" where ctrl: sidebarView.kbMove(-1);     return true
        case "j":            sidebarView.kbMove(1);      return true
        case "k":            sidebarView.kbMove(-1);     return true
        case "l":            sidebarView.kbJumpWS(1);    return true
        case "h":            sidebarView.kbJumpWS(-1);   return true
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

    func hideGrid() {
        Log.debug("hideGrid")
        guard let overlay = gridOverlay else { return }
        if let m = gridKbMonitor {
            NSEvent.removeMonitor(m); gridKbMonitor = nil
        }
        gridView?.clearThumbnails()
        let restoreTree = !treeWasHidden
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

    // MARK: - Visibility

    func setHidden(_ hide: Bool) {
        Log.debug("setHidden hide=\(hide)")
        userHidden = hide
        if hide {
            _exitActiveImpl(restore: false)
            previewTimer?.invalidate(); previewPool.hideAll()
            panelHost.hide()
        } else {
            refresh()
        }
    }
}

// MARK: - TreeController conformance

extension Controller: TreeController {

    // -- Panel mechanics → delegate to PanelHost

    func movePanel(by delta: CGSize) {
        panelHost.movePanel(by: delta)
    }

    func persistPosition() {
        panelHost.persistPosition()
    }

    func gripResizeBegan() {
        isGripResizing = true
    }

    func gripResizeEnded() {
        isGripResizing = false
        panelHost.persistPosition()
        // Re-run a refresh so any events skipped during the drag
        // (gated by isGripResizing) land now.
        refresh()
    }

    func resizeBy(dx: CGFloat, dy: CGFloat) {
        panelHost.resizeBy(dx: dx, dy: dy)
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
