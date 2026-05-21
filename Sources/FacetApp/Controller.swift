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
import FacetAdapterRift

@MainActor
final class Controller: NSObject {

    // MARK: - Wiring

    let backend: any WindowBackend
    private let panelHost: PanelHost
    private let sidebarView: SidebarView

    // MARK: - State

    /// Latest workspaces snapshot — held so the grid view (step 6f)
    /// can render immediately on first show without round-tripping
    /// the backend.
    private(set) var lastWorkspaces: [Workspace] = []
    private var userHidden = false
    /// Pauses refresh/apply while the user is mid-grip-drag, so a
    /// layout pass can't stomp the panel height the next mouseDragged
    /// is about to read (memory: grid-branch-grip-intermittent).
    private var isGripResizing = false
    private var refreshPending = false

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

    init(backend: any WindowBackend) {
        self.backend = backend
        let view = SidebarView(
            frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: 400),
            backend: backend)
        self.sidebarView = view
        self.panelHost = PanelHost(view: view)
        super.init()
        view.controller = self
        panelHost.grip.controller = self
    }

    // MARK: - Lifecycle

    /// Start the controller: subscribe to backend events, schedule
    /// the fallback poll, run an initial refresh. Idempotent only
    /// in the sense that calling it twice will leak the previous
    /// event task — don't.
    func start() {
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
        refresh()
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
        if isGripResizing { return }
        let bk = backend
        cliQueue.async {
            let wss = bk.workspaces()
            // Fill in titles the backend left blank (AX, off-main).
            let titles = AXTitles.resolve(wss)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.apply(wss, titles)
                }
            }
        }
    }

    private func apply(_ wss: [Workspace],
                       _ titles: [WindowID: String] = [:]) {
        // Keep the snapshot fresh even when hidden so the grid (step
        // 6f) can render immediately without a backend round-trip.
        lastWorkspaces = wss
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

    // MARK: - Visibility

    func setHidden(_ hide: Bool) {
        userHidden = hide
        if hide {
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
        // Implemented in step 6f (preview pool + WindowPreview
        // wired alongside grid orchestration since both consume the
        // same capture pipeline).
    }

    func exitActive(restore: Bool) {
        // Implemented in step 6g (keyboard-nav --active mode,
        // NSApp activation policy, prevApp restore).
    }
}
