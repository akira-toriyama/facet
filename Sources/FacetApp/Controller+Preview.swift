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

    /// Touch the capture cache for every known window so captures stay
    /// fresh in the background. Cheap when within TTL (one dict lookup per
    /// window, no capture work).
    func refreshThumbnailCache() {
        let wp = winPreview
        for ws in lastWorkspaces {
            for win in ws.windows {
                wp.request(win.id) { _, _, _ in /* warm only */ }
            }
        }
    }

    /// Capture window `id` and push the resulting thumbnail into whichever
    /// overview is open (the other ref is `nil` → skipped). The request
    /// callback may fire off-main, so the body re-enters the main actor.
    /// Shared by `startOverviewCaptures` / `refreshOverviewThumbnails` /
    /// `pushFreshThumbnails`.
    func captureAndPushToOverview(_ id: WindowID, _ wp: any WindowCapturing) {
        wp.request(id) { [weak self] cg, frame, gotID in
            MainActor.assumeIsolated {
                let img = Self.nsThumb(cg, frame)
                self?.gridView?.setThumbnail(img, for: gotID)
                self?.railView?.setThumbnail(img, for: gotID)
            }
        }
    }

    /// Re-capture the given windows and push the fresh image into
    /// whichever overview is open. Unlike ``refreshOverviewThumbnails``
    /// (the single-shot DnD/swap call site), this does NOT
    /// pre-invalidate — the event-driven caller already dropped
    /// the truly-stale entries, so ``request``'s 5 s TTL / inflight
    /// guards can short-circuit a burst of reconcile passes into one
    /// capture per window. No-op when neither overview is on screen (the
    /// tree refreshes lazily on the next hover off the invalidated
    /// cache, so it needs no push).
    func pushFreshThumbnails(_ ids: [WindowID], _ wp: any WindowCapturing) {
        guard gridView != nil || railView != nil, !ids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            for id in ids { self.captureAndPushToOverview(id, wp) }
        }
    }

    // MARK: - Hover preview reconcile

    /// The SwiftUI tree's replacement for `SidebarView.previewTargets()`
    /// (whose row rects died with the render swap — the detached view has no
    /// window). Source row = hover (sill `onHover` → `treeHoverID`), else the
    /// keyboard cursor while nav is on — the legacy "most recent input wins"
    /// (hover exit clears `treeHoverID`, an arrow key moves the cursor).
    /// Anchors come from the LIVE row rects the list streams (`onRowRects`),
    /// so they are scroll-true like the old `rows[i].rect`.
    func treePreviewTargets()
        -> [(window: WindowID, rowAnchor: NSRect, windowFrame: CGRect?)]
    {
        let vm = panelHost.treeVM
        let src = treeHoverID ?? (sidebarView.kbNav ? vm.activateCursor() : nil)
        guard let src, let anchor = panelHost.rowScreenRect(src) else { return [] }
        switch src {
        case .window(_, let wid):
            guard let ws = lastWorkspaces.first(where: { w in
                w.windows.contains { $0.id == wid }
            }), !ws.isActive,
                  let winModel = ws.windows.first(where: { $0.id == wid })
            else { return [] }
            return [(wid, anchor, winModel.frame)]
        case .header(let sid):
            // A sourceless (isolate) header has no single workspace to
            // preview; only a workspace header previews its windows.
            guard let sec = vm.renderedSections.first(where: { $0.id == sid }),
                  let wi = sec.sourceWorkspaceIndex,
                  let ws = lastWorkspaces.first(where: { $0.index == wi }),
                  !ws.isActive
            else { return [] }
            return ws.windows.map {
                (window: $0.id, rowAnchor: anchor, windowFrame: $0.frame)
            }
        }
    }

    /// Debounced reconciliation of `PreviewOverlay`s with whatever
    /// the tree's hover / kb-cursor currently points at.
    func previewTargetChanged() {
        previewTimer?.invalidate()
        let wp = winPreview
        let targets = treePreviewTargets()
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
                let now = self.treePreviewTargets()
                let nowIDs = Set(now.map(\.window))
                guard nowIDs == ids else { return }
                let mode = self.config.effectiveTreePreviewMode
                for t in now {
                    wp.request(t.window) { [weak self] cg, capFrame, gotID in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            let cur = self.treePreviewTargets()
                            guard let nt = cur.first(where: {
                                $0.window == gotID
                            }) else { return }
                            let img = Self.nsThumb(cg, capFrame)
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

    /// Wrap a captured `CGImage` (from the `WindowCapturing` port) in an
    /// `NSImage` sized to the window's logical frame — the view layer's
    /// thumbnail / preview type. The size matters for the hover popover's
    /// aspect (`popoverFrame` reads `image.size`); cell thumbnails draw
    /// scaled to their rect so it's cosmetic there.
    static func nsThumb(_ cg: CGImage, _ frame: CGRect) -> NSImage {
        NSImage(cgImage: cg, size: frame.size)
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
