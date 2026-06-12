// Preview / thumbnail plumbing — the background thumbnail-cache
// timer, the DnD / event-driven re-capture paths that keep the grid
// + rail cells fresh, and the sidebar hover-preview reconcile
// (popover / mirror placement). Extracted unchanged from
// Controller.swift (#182 phase 3) — same-module extension, no logic
// change. Stored state stays on the primary declaration
// (Controller.swift).

import AppKit
import FacetCore
import FacetView
import FacetViewTree
import FacetViewGrid
import FacetViewRail

extension Controller {

    // MARK: - Preview / thumbnail timer

    /// Tear down + recreate the thumbnail timer so the interval
    /// reflects the current config. ``nil`` interval = disabled (no
    /// background capture; cells fall back to icons momentarily on
    /// each grid open).
    func rescheduleThumbnailTimer() {
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
    func refreshThumbnailCache() {
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

    /// Re-capture the windows of the listed workspaces and feed them to
    /// the rail. After a move/swap the affected windows' frames change,
    /// so the snapshot-on-show cache is stale. Same shape as
    /// ``refreshGridThumbnails`` (rail uses the shared ``winPreview``).
    func refreshRailThumbnails(forWSIndices indices: [Int],
                               in wss: [Workspace]) {
        guard #available(macOS 14.0, *),
              let wp = winPreview as? WindowPreview,
              railView != nil
        else { return }
        let want = Set(indices)
        let ids: [WindowID] = wss
            .filter { want.contains($0.index) }
            .flatMap { $0.windows.map(\.id) }
        for id in ids { wp.invalidate(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard self != nil else { return }
            for id in ids {
                wp.request(id) { [weak self] img, _, gotID in
                    MainActor.assumeIsolated {
                        self?.railView?.setThumbnail(img, for: gotID)
                    }
                }
            }
        }
    }

    /// Re-capture the given windows and push the fresh image into
    /// whichever overview is open. Unlike ``refreshGridThumbnails`` /
    /// ``refreshRailThumbnails`` (single-shot DnD/swap call sites), this
    /// does NOT pre-invalidate — the event-driven caller already dropped
    /// the truly-stale entries, so ``request``'s 5 s TTL / inflight
    /// guards can short-circuit a burst of reconcile passes into one
    /// capture per window. No-op when neither overview is on screen (the
    /// tree refreshes lazily on the next hover off the invalidated
    /// cache, so it needs no push).
    @available(macOS 14.0, *)
    func pushFreshThumbnails(_ ids: [WindowID], _ wp: WindowPreview) {
        guard gridView != nil || railView != nil, !ids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard self != nil else { return }
            for id in ids {
                wp.request(id) { [weak self] img, _, gotID in
                    MainActor.assumeIsolated {
                        self?.gridView?.setThumbnail(img, for: gotID)
                        self?.railView?.setThumbnail(img, for: gotID)
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
                let mode = self.config.effectiveTreePreviewMode
                for t in now {
                    wp.request(t.window) { [weak self] img, _, gotID in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            let cur = self.sidebarView.previewTargets()
                            guard let nt = cur.first(where: {
                                $0.window == gotID
                            }) else { return }
                            let frame: NSRect
                            if mode == "mirror", let wf = nt.windowFrame {
                                frame = Self.cgFrameToAppKit(wf)
                            } else {
                                // Stack index = position in the current
                                // ordered list (WS-header hover yields
                                // several targets sharing one anchor).
                                let pos = cur.firstIndex(where: {
                                    $0.window == gotID
                                }) ?? 0
                                frame = Self.popoverFrame(
                                    anchor: nt.rowAnchor,
                                    image: img, stackIndex: pos)
                            }
                            self.previewPool.show(
                                gotID, img: img, screenFrame: frame)
                        }
                    }
                }
            }
        }
    }

    /// Mirror-mode: convert a Quartz (top-left origin) backend
    /// window frame to an AppKit (bottom-left, primary-screen
    /// origin) screen rect. Multi-display arrangements where the
    /// secondary screen sits above the primary aren't handled
    /// here — the conversion uses the primary screen's height
    /// only. (Same behaviour as the pre-popover code; if it
    /// matters, `tree.preview-mode = "popover"` sidesteps it.)
    static func cgFrameToAppKit(_ r: CGRect) -> NSRect {
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }?
            .frame.height) ?? NSScreen.main?.frame.height ?? r.maxY
        return NSRect(x: r.minX, y: primaryH - r.maxY,
                      width: r.width, height: r.height)
    }

    /// Place the preview popover next to a sidebar row.
    ///
    /// - Sizes the panel to the image aspect, capped at
    ///   `popoverMaxSize` so a 4K window doesn't fill the screen.
    /// - Prefers the right side of the row; auto-flips left if
    ///   that overflows the screen (e.g. sidebar parked on the
    ///   right edge).
    /// - For workspace-header hover the caller passes the same
    ///   anchor for every window of the WS and varies `stackIndex`
    ///   — popovers stack downward with a small gap.
    /// - Clamps to the anchor screen's `visibleFrame` (menu bar +
    ///   Dock excluded).
    static func popoverFrame(
        anchor: NSRect, image: NSImage?, stackIndex: Int
    ) -> NSRect {
        let maxSize = NSSize(width: 320, height: 220)
        let gap: CGFloat = 8
        let stackGap: CGFloat = 4

        let imgSize = image?.size ?? NSSize(width: 16, height: 10)
        let aspect = imgSize.width / max(imgSize.height, 1)
        var w = maxSize.width
        var h = w / aspect
        if h > maxSize.height {
            h = maxSize.height; w = h * aspect
        }

        var x = anchor.maxX + gap
        let stackDrop = CGFloat(stackIndex) * (h + stackGap)
        // AppKit screen coords: maxY = top of anchor. Place popover
        // top-aligned with the row's top, then push down for stack.
        var y = anchor.maxY - h - stackDrop

        let mid = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(mid) }
            ?? NSScreen.main
        if let vis = screen?.visibleFrame {
            if x + w > vis.maxX {
                x = anchor.minX - gap - w     // flip to left
            }
            x = max(vis.minX, min(vis.maxX - w, x))
            y = max(vis.minY, min(vis.maxY - h, y))
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }
}
