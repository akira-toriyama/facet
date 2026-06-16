// Full-screen overview grid — one cell per workspace, arranged in
// `cols × rows`. Each cell mirrors the screen aspect so window
// mini-rects map cleanly. The view stays controller-free:
// orchestration plugs in via the four callback closures
// (``onDismiss`` / ``onPick`` / ``onMoveWindow`` / ``onSwap``).
// Controller decides what those mean.

import AppKit
import CoreGraphics
import Foundation
import FacetCore
import FacetView

public final class GridView: NSView {

    /// Per-surface palette (PR-B). The Controller wires the grid box at
    /// build time; `pal` reads route through it (the grid overlay's own
    /// `[grid].theme`), and the box is shared with the grid's `BorderFX`.
    public var paletteBox: PaletteBox! {
        didSet { borderFX.paletteBox = paletteBox }
    }
    var pal: ResolvedPalette { paletteBox.pal }

    // MARK: - Inputs (Controller-supplied)

    /// Snapshot taken at show time — we don't track live backend
    /// events while the overlay is up (snapshot-on-show, per
    /// design).
    public var workspaces: [Workspace] = []
    public var activeIndex: Int?
    /// Display's frame at show time. All window-rect math scales
    /// from this so the per-cell mini-screen matches what the
    /// backend reported, even if a display change happens mid-show.
    public var screenFrame: CGRect = .zero
    /// Layout / typography config. Controller updates this if the
    /// config file changes (TBD: M2 step 6 config-file integration).
    public var config: GridConfig = .standard

    /// Click-outside-cell dismiss + Esc — both go through the same
    /// callback so the Controller owns the actual hide / restore
    /// sequence.
    public var onDismiss: (() -> Void)?
    /// Click on a workspace cell (empty area) or on a window thumb
    /// inside one. The Controller decides what to do — typically
    /// switch workspace, optionally focus the picked window, then
    /// dismiss.
    public var onPick: ((GridPick) -> Void)?
    /// Backend for the shared context menu (③ — header layout picker +
    /// window-ops menu). Set by the Controller; held as the protocol.
    public var backend: (any WindowBackend)?
    /// Runs the non-close window-ops a context-menu pick chose (③).
    /// Controller wires it to its `runWindowOps`.
    public var onRunWindowOps: ((_ ops: [WindowAction],
                                 _ window: Window, _ ws: Int) -> Void)?
    /// Drop-commit callback (window-move). Controller owns the
    /// backend round-trip and the subsequent re-query. Same name +
    /// signature as `RailView.onMoveWindow` — both are the
    /// `OverviewView` move callback.
    public var onMoveWindow: ((_ src: Int, _ dst: Int,
                               _ pid: Int, _ id: WindowID) -> Void)?
    /// Workspace-swap commit callback (Phase 1f-4). Controller
    /// fires N+M ``moveWindow`` calls (srcIDs → dstWS, then
    /// dstIDs → srcWS) followed by an apply. The backend's
    /// workspace index is never touched, so the physical position
    /// of the cell in the grid stays put — only the windows trade.
    public var onSwap: ((_ srcWS: Int, _ dstWS: Int,
                         _ srcIDs: [WindowID],
                         _ dstIDs: [WindowID]) -> Void)?

    // MARK: - Per-cell snapshot

    /// One layout-pass snapshot per workspace cell — the shared
    /// `OverviewCell` (FacetCore). `isHero` is always `false` for the
    /// grid (rail-only). Holds everything `draw` and hit-testing need to
    /// agree on (no recomputation drift between paint and click).
    private var cells: [OverviewCell] = []

    // MARK: - Drag state

    // `OverviewDrag` / `OverviewDragKind` (FacetCore) carry the active
    // gesture: `.window` moves a thumb to another WS, `.workspace` drags a
    // cell's HEADER to swap its whole contents with the destination cell.
    // The backend's workspace index never changes; only the windows
    // trade. Theme A: the grabbed target (not a modifier key) decides.
    private var pendingDown: (point: NSPoint, hit: MiniWindowHit, ws: Int)?
    // Header band pressed: a workspace drag-or-switch candidate
    // (Theme A). Promoted to a `.workspace` swap drag past threshold,
    // else resolved as a WS switch on mouseUp.
    private var pendingHeaderDown: (point: NSPoint, ws: Int)?
    // Workspace whose header the pointer is hovering — brightens the
    // header band + grip (mirrors the tree header hover affordance).
    private var hoverHeaderWS: Int?
    // Workspace whose cell (anywhere) the pointer is over — outlines it
    // with a faint stroke, matching the rail's cell-hover (M9-5 #5).
    private var hoverWS: Int?
    private var drag: OverviewDrag?
    private var dragGhost: NSView?

    /// While dragging we suppress `layoutCells` callers from outside
    /// (refresh events) so the cell the user is dragging *out of*
    /// doesn't shift mid-gesture. Cells are reapplied on drop.
    public private(set) var layoutSuppressed = false

    // MARK: - FLIP reorder tweens

    /// Each thumb whose rect changed between `layoutCells` passes
    /// (after a drop or any refresh that moves a window) slides
    /// from its old rect to its new rect over
    /// `gridReorderDuration`. Keyed by WindowID. Cleared as each
    /// window's tween completes.
    struct ReorderTween { let from: NSRect; let to: NSRect; let start: Date }
    private var reordering: [WindowID: ReorderTween] = [:]
    private var reorderTimer: Timer?

    /// Tracks the in-flight window move (`OverviewPendingDrop`,
    /// FacetCore): consumed by the next ``layoutCells`` pass that can
    /// confirm the move landed (dropped id now lives in dstWS), gating
    /// the source thumb's reveal on the backend reflecting it (otherwise
    /// refresh ticks racing the round-trip briefly show a residual thumb
    /// in the source cell — 残像).
    private var lastDrop: OverviewPendingDrop?

    /// Workspace-swap analogue of ``lastDrop`` (`OverviewPendingSwap`,
    /// FacetCore): the expected post-swap window membership so
    /// ``layoutCells`` can gate the "clear drag + reveal cells" hand-off
    /// on the backend actually reporting both halves of the swap.
    private var lastSwap: OverviewPendingSwap?

    /// Max time we keep ``drag`` set waiting for the drop's apply.
    /// If the backend never reports the move (it could fail
    /// silently), we give up and reveal the source thumb so the UI
    /// doesn't stay frozen.
    private static let dropAckTimeout: TimeInterval = 1.0

    // MARK: - ScreenCaptureKit thumbnails

    /// `WindowID → captured image`. Populated by the Controller as
    /// captures land during a grid show; the shared `drawMiniThumb`
    /// consults this first and falls back to the app icon when
    /// missing (capture not yet done, or Screen Recording denied).
    /// Cleared on ``clearThumbnails`` to release memory.
    private var thumbnails: [WindowID: NSImage] = [:]

    // MARK: - Keyboard nav (Phase 1f-3)

    public var kbSelectedWS: Int?
    /// Window cursor within `kbSelectedWS`: `-1` = the WS-name/header
    /// slot (no window ring), `0…n-1` = a window. Opens at `-1` so the
    /// grid shows NO pre-selected window — matching the rail (which
    /// opens with a WS browse cursor only) and the grid's own
    /// arrow-browse, which also lands on `-1`. Tab picks a window.
    public var kbSelectedWindowIdx: Int = -1

    /// Plays the "selected cell zoom → full screen" transition on a
    /// Return commit; input is gated on `commitZoom.isActive` until it
    /// finishes (then the backend switch + close fire). Shared with the
    /// rail (`CommitZoom` in FacetView).
    private let commitZoom = CommitZoom(duration: overviewCommitZoomDuration)

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    // MARK: - Layout

    /// Columns actually used for layout. Capped at the workspace
    /// count so a mac desktop with fewer workspaces than the configured
    /// `cols` fills the width with larger cells (the row is centered
    /// by the existing `originX` math) instead of leaving a big empty
    /// gap on the right. Only shrinks: when `count >= cols` the
    /// configured value stands and rows wrap as before.
    private var effectiveCols: Int {
        max(1, min(config.cols, workspaces.count))
    }

    // MARK: - Border (shared BorderFX — a screen-edge neon frame)

    private let borderFX = BorderFX()
    private let borderLayer = CALayer()
    private var borderInstalled = false

    /// Apply the `[border]` config (Controller, on show / reload). The
    /// grid shows a screen-edge neon frame only while an effect is
    /// active — no border when off.
    public func applyBorder(effectName: String, glow: Bool, width: CGFloat,
                            cycleSeconds: CGFloat, cycleColors: Bool,
                            minWidth: CGFloat?, maxWidth: CGFloat?) {
        installBorderIfNeeded()
        borderFX.configure(effectName: effectName, glow: glow, width: width,
                           cycleSeconds: cycleSeconds, cycleColors: cycleColors,
                           minWidth: minWidth, maxWidth: maxWidth)
    }
    /// WS-switch flash (no-op when off).
    public func flashBorder() { borderFX.flash() }
    /// Stop the border timer when the overlay closes.
    public func stopBorder() { borderFX.stop() }

    private func installBorderIfNeeded() {
        guard !borderInstalled else { return }
        borderInstalled = true
        wantsLayer = true
        borderLayer.zPosition = 1000          // above the cells
        borderLayer.cornerRadius = 0          // square screen frame
        layer?.addSublayer(borderLayer)
        updateBorderFrame()
        borderFX.onRepaint = { [weak self] in
            guard let self else { return }
            self.borderLayer.isHidden = !self.borderFX.active
            if self.borderFX.active { self.borderFX.apply(to: self.borderLayer) }
        }
    }

    private func updateBorderFrame() {
        guard borderInstalled else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = bounds
        CATransaction.commit()
    }

    public func layoutCells() {
        // Drop-in-flight gate (runs *before* layoutSuppressed
        // check because a landed drop needs to release suppression
        // and rebuild).
        // - lastDrop set + not landed + within timeout → return
        // - lastDrop set + not landed + timed out → cleanup + reveal
        // - lastDrop set + landed → release suppression, proceed
        var droppedLanded = false
        if let ld = lastDrop {
            let landed = workspaces.contains { ws in
                ws.index == ld.dstWS
                    && ws.windows.contains { $0.id == ld.id }
            }
            if !landed {
                if Date().timeIntervalSince(ld.committedAt)
                    > Self.dropAckTimeout {
                    dragGhost?.removeFromSuperview(); dragGhost = nil
                    lastDrop = nil; drag = nil
                    layoutSuppressed = false
                } else {
                    return
                }
            } else {
                droppedLanded = true
                layoutSuppressed = false
            }
        }
        // Workspace-swap analogue: gate the hand-off on the backend
        // reporting all of `srcIDs` in `dstWS` AND all of `dstIDs`
        // in `srcWS`. Same dropAckTimeout safety net.
        var swapLanded = false
        if let ls = lastSwap {
            let srcCell = workspaces.first(where: { $0.index == ls.srcWS })
            let dstCell = workspaces.first(where: { $0.index == ls.dstWS })
            let landed: Bool = {
                guard let s = srcCell, let d = dstCell else { return false }
                let srcNow = Set(s.windows.map(\.id))
                let dstNow = Set(d.windows.map(\.id))
                return ls.srcIDs.allSatisfy(dstNow.contains)
                    && ls.dstIDs.allSatisfy(srcNow.contains)
            }()
            if !landed {
                if Date().timeIntervalSince(ls.committedAt)
                    > Self.dropAckTimeout {
                    dragGhost?.removeFromSuperview(); dragGhost = nil
                    lastSwap = nil; drag = nil
                    layoutSuppressed = false
                } else {
                    return
                }
            } else {
                swapLanded = true
                layoutSuppressed = false
            }
        }
        // While a drag is in flight we keep the existing cell rects
        // so the source thumb's position doesn't shift under the
        // cursor mid-gesture. The next pass after the drop applies
        // fresh cells with the moved window in its new home.
        if layoutSuppressed { return }
        // Snapshot the prior window rects so we can FLIP-animate
        // any id that ends up in a different rect after the
        // re-layout (drop, refresh, manual backend move, …).
        var oldRects: [WindowID: NSRect] = [:]
        for cell in cells {
            for w in cell.windows { oldRects[w.id] = w.rect }
        }
        cells.removeAll()
        guard !workspaces.isEmpty else {
            reordering.removeAll(); stopReorderTimer()
            needsDisplay = true; return
        }
        let cols = effectiveCols
        let rows = gridRowCount(wsCount: workspaces.count, cols: cols)
        let usableW = bounds.width  - 2 * gridOuterPad
        let usableH = bounds.height - 2 * gridOuterPad
        // Aspect from the screen we're being shown on (main display
        // for the Phase 1a MVP). Falls back to 16:9 if NSScreen.main
        // is nil — values just need to be self-consistent.
        let scr = window?.screen?.frame
            ?? NSScreen.main?.frame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let aspect = scr.width / max(1, scr.height)
        // Each row reserves a header band on the configured side.
        // Default "up" (Mission Control convention); "down" puts
        // the header below each cell (Stage Manager / dock).
        let labelPos = config.labelPosition
        // Proportional header: scale the band to the cell's nominal
        // height (cell height before the band is carved out) so the
        // header grows with big cells / shrinks with small ones,
        // clamped to a grabbable-yet-unobtrusive range. Derived from
        // the *nominal* height (not the final cellSize) to avoid a
        // circular dependency — the band reservation feeds cellSize.
        let nominalCellH = max(1, (usableH - gridCellGap * CGFloat(rows - 1))
                               / CGFloat(rows))
        let labelH = min(gridHeaderMaxH,
                         max(gridHeaderMinH,
                             (nominalCellH * gridHeaderRatio).rounded()))
        let labelBand = labelH + gridLabelGap
        let usableForCells = usableH - CGFloat(rows) * labelBand
        let cellSize = gridCellSize(usableW: usableW,
                                    usableH: max(1, usableForCells),
                                    cols: cols, rows: rows,
                                    screenAspect: aspect)
        let totalW = cellSize.width  * CGFloat(cols)
            + gridCellGap * CGFloat(cols - 1)
        let totalH = (cellSize.height + labelBand) * CGFloat(rows)
            + gridCellGap * CGFloat(rows - 1)
        let originX = (bounds.width  - totalW) / 2
        let originY = (bounds.height - totalH) / 2
        let useScreen = screenFrame.width > 0 ? screenFrame : scr
        for (i, ws) in workspaces.enumerated() {
            let r = i / cols, c = i % cols
            let rowSlotY = originY + CGFloat(r)
                * (cellSize.height + labelBand + gridCellGap)
            let x = originX + CGFloat(c) * (cellSize.width + gridCellGap)
            let y = labelPos == "down" ? rowSlotY
                                       : rowSlotY + labelBand
            let cellRect = NSRect(x: x, y: y,
                                  width: cellSize.width,
                                  height: cellSize.height)
            // Pre-compute window thumb rects in cell-local view
            // coords so hit-testing and drawing agree byte-for-byte.
            var hits: [MiniWindowHit] = []
            if useScreen.width > 0 {
                for win in ws.windows {
                    guard let f = win.frame else { continue }
                    let wr = gridScaledWindowRect(
                        windowFrame: f,
                        screenFrame: useScreen,
                        cellRect: cellRect)
                    guard wr.width >= 2, wr.height >= 2 else { continue }
                    hits.append(MiniWindowHit(
                        pid: win.pid,
                        id: win.id,
                        isFocused: win.isFocused,
                        rect: wr,
                        mark: win.mark))
                }
            }
            // Header band rect (matches the label draw position) —
            // hit target for header drag (swap) / click (switch).
            let headerY = labelPos == "down"
                ? cellRect.maxY + gridLabelGap - 2
                : cellRect.minY - labelH - gridLabelGap + 2
            let headerRect = NSRect(x: cellRect.minX, y: headerY,
                                    width: cellRect.width, height: labelH)
            cells.append(OverviewCell(
                wsIndex: ws.index,
                rect: cellRect,
                headerRect: headerRect,
                isActive: ws.isActive,
                label: gridLabel(name: ws.name, idx: ws.index),
                mode: ws.layoutMode,
                windows: hits))
        }
        // FLIP: any id whose rect changed since the snapshot above
        // gets a new tween. Same-rect (most cells, every refresh)
        // gets skipped — only actual moves animate.
        //
        // The just-dropped id is intentionally skipped here: the
        // ghost (still on screen at the release point) is animated
        // to its new rect separately, below. A FLIP tween would
        // double-render.
        let now = Date()
        var fresh: [WindowID: ReorderTween] = [:]
        // Workspace-swap landing: every id moved to the other cell.
        // Building FLIP tweens for all of them would slide a dozen
        // thumbs across the grid simultaneously. Suppress.
        let skipTweens = swapLanded
        for cell in cells {
            for w in cell.windows {
                if skipTweens { continue }
                if droppedLanded, lastDrop?.id == w.id { continue }
                guard let old = oldRects[w.id], old != w.rect
                else { continue }
                // Mid-flight tweens: continue from the current
                // interpolated rect so a second event doesn't snap
                // the slide back to the old start.
                let from = interpolatedRect(for: w.id) ?? old
                fresh[w.id] = ReorderTween(
                    from: from, to: w.rect, start: now)
            }
        }
        reordering = fresh
        if reordering.isEmpty { stopReorderTimer() }
        else                  { startReorderTimer() }

        // Hand-off: when the drop's apply lands, the ghost vanishes
        // and the real thumb appears at its new rect in the same
        // paint. No slide — sliding the ghost while the real thumb
        // was already present in the destination cell produced the
        // 'two Calendars' duplicate seen in v2 optimistic UI.
        if droppedLanded {
            dragGhost?.removeFromSuperview()
            dragGhost = nil
            lastDrop = nil
            drag = nil
        }
        // Workspace-swap landing: no FLIP slide for individual
        // windows (every id changed cells; per-id `from` would be a
        // stale cross-cell rect). Just remove the ghost.
        if swapLanded {
            dragGhost?.removeFromSuperview()
            dragGhost = nil
            lastSwap = nil
            drag = nil
        }
        needsDisplay = true
    }

    // MARK: - FLIP reorder helpers

    private func interpolatedRect(for id: WindowID) -> NSRect? {
        guard let t = reordering[id] else { return nil }
        let elapsed = Date().timeIntervalSince(t.start)
        let p = max(0.0, min(1.0, elapsed / gridReorderDuration))
        let eased = 1 - pow(1 - p, 2)             // ease-out quadratic
        return NSRect(
            x: t.from.minX + (t.to.minX - t.from.minX) * CGFloat(eased),
            y: t.from.minY + (t.to.minY - t.from.minY) * CGFloat(eased),
            width:  t.from.width  + (t.to.width  - t.from.width)  * CGFloat(eased),
            height: t.from.height + (t.to.height - t.from.height) * CGFloat(eased))
    }

    private func startReorderTimer() {
        if reorderTimer != nil { return }
        reorderTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.reordering = self.reordering.filter { _, t in
                    now.timeIntervalSince(t.start) < gridReorderDuration
                }
                self.needsDisplay = true
                if self.reordering.isEmpty { self.stopReorderTimer() }
            }
        }
    }

    private func stopReorderTimer() {
        reorderTimer?.invalidate()
        reorderTimer = nil
    }

    public override func layout() {
        super.layout(); layoutCells(); updateBorderFrame()
    }

    // MARK: - Draw

    public override func draw(_ dirty: NSRect) {
        // Commit zoom (②): the captured cell scales out to fill the
        // screen; then the switch + close fire. Nothing else draws then.
        if commitZoom.draw(in: bounds) { return }
        // Palette: very faint cell fills + strokes so window thumbs
        // do the visual work, accent reserved for active / drop-target.
        let activeColor = pal.primary
        let cellFill    = pal.muted.withAlphaComponent(0.08)
        let cellStroke  = pal.muted.withAlphaComponent(0.22)
        let labelColor  = pal.foreground.withAlphaComponent(0.85)
        let activeFill  = pal.primary.withAlphaComponent(0.10)
        let winFill     = pal.foreground.withAlphaComponent(0.18)
        let winFocused  = pal.primary.withAlphaComponent(0.32)
        let winStroke   = pal.foreground.withAlphaComponent(0.45)
        // Drop target: accent stroke + tint when a drag is over a
        // cell different from source. A workspace swap (header drag)
        // uses text-color instead so the user can tell at a glance
        // whether a plain window-move or a whole-cell-swap is in
        // flight.
        let dropTarget = drag?.dropTargetWS
        let dragSourceID = drag?.id
        let dragKind = drag?.kind
        let dragSourceWS = drag?.sourceWS
        for cell in cells {
            let path = NSBezierPath(roundedRect: cell.rect,
                xRadius: gridCellCornerRadius,
                yRadius: gridCellCornerRadius)
            let isDrop = (cell.wsIndex == dropTarget)
            let isSwapSource = (dragKind == .workspace
                                && cell.wsIndex == dragSourceWS)
            if isDrop {
                switch dragKind {
                case .workspace:
                    pal.foreground.withAlphaComponent(0.18).setFill()
                    path.fill()
                    pal.foreground.withAlphaComponent(0.85).setStroke()
                    path.lineWidth = 2
                    path.stroke()
                case .window, .none:
                    pal.primary.withAlphaComponent(0.28).setFill()
                    path.fill()
                    pal.primary.setStroke()
                    path.lineWidth = 2
                    path.stroke()
                }
            } else if isSwapSource {
                pal.foreground.withAlphaComponent(0.06).setFill()
                path.fill()
                pal.foreground.withAlphaComponent(0.40).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                (cell.isActive ? activeFill : cellFill).setFill()
                path.fill()
                // Active border wins; otherwise a hovered cell gets a
                // faint outline (M9-5 #5, rail parity), else the divider.
                if cell.isActive {
                    activeColor.withAlphaComponent(0.7).setStroke()
                    path.lineWidth = 1
                } else if drag == nil, hoverWS == cell.wsIndex {
                    pal.foreground.withAlphaComponent(0.7).setStroke()
                    path.lineWidth = 1.5
                } else {
                    cellStroke.setStroke()
                    path.lineWidth = 0.5
                }
                path.stroke()
            }
            // Keyboard selection cursor — outline the currently
            // selected cell while NOT lifted (during a lift the
            // drop-target highlight already shows where the ghost
            // will land). Accent-colored to match the rail (see
            // RailView.drawCell's hero/active/browse-target border
            // block): the active WS gets the primary accent, a browse
            // target (selected but not active) gets the secondary accent.
            if drag == nil, kbSelectedWS == cell.wsIndex {
                (cell.isActive ? pal.primary : pal.secondary).setStroke()
                let kc = NSBezierPath(
                    roundedRect: cell.rect.insetBy(dx: 1.5, dy: 1.5),
                    xRadius: gridCellCornerRadius,
                    yRadius: gridCellCornerRadius)
                kc.lineWidth = 1.5
                kc.stroke()
            }

            // Window mini-rects: rects + sizes were computed in
            // layoutCells; rendering reads the same state hit-test
            // uses (no drift between paint and click). Clip to the
            // cell shape so a stray rect can't bleed across.
            //
            // In-transit windows (FLIP reorder) are skipped here
            // and drawn after the per-cell loop without a clip —
            // they'd otherwise be sliced as they cross boundaries.
            if !cell.windows.isEmpty {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                for w in cell.windows {
                    if w.id == dragSourceID { continue }    // ghost stands in
                    if isSwapSource { continue }
                    if reordering[w.id] != nil { continue } // drawn unclipped below
                    drawMiniThumb(w, at: w.rect,
                                  fill: w.isFocused ? winFocused : winFill,
                                  stroke: winStroke,
                                  thumbnails: thumbnails, iconFallback: true,
                                  pal: pal)
                }
                // Window-level cursor: outline the keyboard-
                // selected window inside the selected cell so the
                // user sees WHICH window Space will lift. Drawn
                // inside the cell clip so it can't escape.
                if drag == nil, kbSelectedWS == cell.wsIndex,
                   let s = kbSelectedWindow(), s.cell.wsIndex == cell.wsIndex
                {
                    // Accent fill + ring (covers the window front, like
                    // the rail) so the selection is unmistakable.
                    let ko = NSBezierPath(
                        roundedRect: s.hit.rect.insetBy(dx: 1, dy: 1),
                        xRadius: 3, yRadius: 3)
                    pal.primary.withAlphaComponent(0.30).setFill(); ko.fill()
                    pal.primary.setStroke()
                    ko.lineWidth = 2.5
                    ko.stroke()
                }
                NSGraphicsContext.restoreGraphicsState()
            }

            // Workspace header bar — the swap drag handle. Theme A:
            // drag the header = swap this WS's contents with the drop
            // target; click = switch. A faint rounded fill + a grip
            // glyph read as grabbable (same model / affordance as the
            // tree header). `kbSelectedWindowIdx == -1` = the header
            // is the keyboard selection (Space lifts it for a swap).
            let hb = cell.headerRect
            let headerSel = (drag == nil && kbSelectedWS == cell.wsIndex
                             && kbSelectedWindowIdx == -1)
            let headerHover = (drag == nil && hoverHeaderWS == cell.wsIndex)
            let headerHot = cell.isActive || headerSel || headerHover
            (cell.isActive
                ? activeColor.withAlphaComponent(headerHover ? 0.20 : 0.12)
                : pal.muted.withAlphaComponent(headerHover ? 0.20 : 0.10))
                .setFill()
            NSBezierPath(roundedRect: hb.insetBy(dx: 0, dy: 1),
                         xRadius: 4, yRadius: 4).fill()
            if headerSel {
                // Match the cell cursor + rail: accent for the active
                // WS, secondary for a browse target — not a plain text
                // stroke (the WS-name slot is the open-time selection
                // since grid opens at kbSelectedWindowIdx == -1).
                (cell.isActive ? pal.primary : pal.secondary).setStroke()
                let ho = NSBezierPath(
                    roundedRect: hb.insetBy(dx: 0.75, dy: 1.25),
                    xRadius: 4, yRadius: 4)
                ho.lineWidth = 1.5
                ho.stroke()
            }
            drawGripDots(
                in: NSRect(x: hb.minX + 4, y: hb.minY,
                           width: gridHeaderGripW, height: hb.height),
                tallExtent: 18,
                color: headerHot ? activeColor : labelColor,
                alpha: headerHot ? 0.85 : 0.5)
            // WS name (line 1) + layout mode (line 2, accent), stacked
            // and vertically centred. Two lines give the header a
            // natural thickness and surface the same layout-mode info
            // the tree header shows. Fonts track the band height.
            let lp = NSMutableParagraphStyle()
            lp.alignment = .left
            lp.lineBreakMode = .byTruncatingTail
            let nameX = hb.minX + 4 + gridHeaderGripW + 5
            let nameW = max(hb.maxX - nameX - 4, 0)
            let nameFont = min(gridHeaderNameMaxFont,
                               max(gridHeaderNameMinFont,
                                   (hb.height * gridHeaderNameFrac).rounded()))
            let nameColor = cell.isActive ? activeColor : labelColor
            if cell.mode.isEmpty {
                let nameH = nameFont * 1.3
                drawTextLine(cell.label, font: nameFont, weight: .semibold,
                               color: nameColor, para: lp,
                               in: NSRect(x: nameX,
                                          y: hb.minY + (hb.height - nameH) / 2,
                                          width: nameW, height: nameH))
            } else {
                let modeFont = min(gridHeaderModeMaxFont,
                                   max(gridHeaderModeMinFont,
                                       (hb.height * gridHeaderModeFrac).rounded()))
                // Layout-mode text — secondary semibold on the active
                // WS, `pal.muted` on the rest. No pill background — the
                // text + color step alone carries the badge weight,
                // matching the tree header's restyle.
                let modeColor = cell.isActive ? pal.secondary : pal.muted
                let mAttrs: [NSAttributedString.Key: Any] = [
                    .font: uiFont(modeFont, .semibold),
                    .foregroundColor: modeColor,
                    .paragraphStyle: lp,
                ]
                let modeH = (modeFont * 1.3).rounded()
                let nameH = nameFont * 1.25
                let gap: CGFloat = 3
                let startY = hb.minY + (hb.height - (nameH + gap + modeH)) / 2
                drawTextLine(cell.label, font: nameFont, weight: .semibold,
                               color: nameColor, para: lp,
                               in: NSRect(x: nameX, y: startY,
                                          width: nameW, height: nameH))
                (layoutBadgeLabel(cell.mode) as NSString).draw(
                    in: NSRect(x: nameX, y: startY + nameH + gap,
                               width: nameW, height: modeH),
                    withAttributes: mAttrs)
            }
        }

        // In-transit windows (FLIP reorder): drawn last, NO cell
        // clip, so a thumb sliding from one cell to another isn't
        // sliced off at the boundary.
        if !reordering.isEmpty {
            for cell in cells {
                for w in cell.windows where w.id != dragSourceID {
                    guard let r = interpolatedRect(for: w.id)
                    else { continue }
                    drawMiniThumb(w, at: r,
                                  fill: w.isFocused ? winFocused : winFill,
                                  stroke: winStroke,
                                  thumbnails: thumbnails, iconFallback: true,
                                  pal: pal)
                }
            }
        }
    }

    // MARK: - Hover (header highlight)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect,
                      .mouseMoved, .mouseEnteredAndExited],
            owner: self))
    }

    public override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let ws = cells.first(where: { $0.headerRect.contains(p) })?.wsIndex
        let cellWS = cells.first(where: {
            $0.rect.contains(p) || $0.headerRect.contains(p) })?.wsIndex
        if ws != hoverHeaderWS || cellWS != hoverWS {
            hoverHeaderWS = ws
            hoverWS = cellWS
            needsDisplay = true
        }
        (ws != nil ? NSCursor.openHand : NSCursor.arrow).set()
    }

    public override func mouseExited(with e: NSEvent) {
        if hoverHeaderWS != nil || hoverWS != nil {
            hoverHeaderWS = nil
            hoverWS = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    // MARK: - Mouse

    // Right-click: WS header → layout-engine picker; window thumb →
    // window-ops menu (③ — the SAME shared menu the tree shows).
    public override func rightMouseDown(with e: NSEvent) {
        guard let backend, let win = window else { return }
        let p = convert(e.locationInWindow, from: nil)
        let scr = win.convertPoint(toScreen: e.locationInWindow)
        if let cell = cells.first(where: { $0.headerRect.contains(p) }) {
            ViewContextMenu.showLayout(at: scr, backend: backend,
                                       workspaceIndex: cell.wsIndex,
                                       workspaces: workspaces, palette: pal)
            return
        }
        if let cell = cells.first(where: { $0.rect.contains(p) }),
           let wh = cell.windows.first(where: { $0.rect.contains(p) }) {
            ViewContextMenu.showWindow(
                at: scr, backend: backend, workspaceIndex: cell.wsIndex,
                workspaces: workspaces, pid: wh.pid, windowID: wh.id, title: "",
                palette: pal
            ) { [weak self] ops, w, ws in self?.onRunWindowOps?(ops, w, ws) }
        }
    }

    /// Keyboard 'm' (③): open the context menu for the kb-selected slot
    /// — the WS header (layout picker) or a window thumb (window ops),
    /// anchored to that cell. No-op without a selection / backend.
    public func kbContextMenu() {
        guard let backend, let win = window, let ws = kbSelectedWS,
              let cell = cells.first(where: { $0.wsIndex == ws }) else { return }
        func screenPt(_ r: NSRect) -> NSPoint {
            win.convertPoint(toScreen: convert(NSPoint(x: r.minX + 12, y: r.minY), to: nil))
        }
        if kbSelectedWindowIdx == -1 {
            ViewContextMenu.showLayout(at: screenPt(cell.headerRect), backend: backend,
                                       workspaceIndex: ws, workspaces: workspaces,
                                       palette: pal)
        } else if kbSelectedWindowIdx >= 0, kbSelectedWindowIdx < cell.windows.count {
            let wh = cell.windows[kbSelectedWindowIdx]
            ViewContextMenu.showWindow(
                at: screenPt(wh.rect), backend: backend, workspaceIndex: ws,
                workspaces: workspaces, pid: wh.pid, windowID: wh.id, title: "",
                palette: pal
            ) { [weak self] ops, w, ws in self?.onRunWindowOps?(ops, w, ws) }
        }
    }

    public override func mouseDown(with e: NSEvent) {
        guard !commitZoom.isActive else { return }   // ② zoom in flight
        let p = convert(e.locationInWindow, from: nil)
        // Header band → workspace drag (swap) or click (switch).
        if let cell = cells.first(where: { $0.headerRect.contains(p) }) {
            pendingHeaderDown = (point: p, ws: cell.wsIndex)
            return
        }
        // No cell under cursor → backdrop click → immediate dismiss.
        guard let cell = cells.first(where: { $0.rect.contains(p) }) else {
            onDismiss?(); return
        }
        // Topmost window thumb wins z-order (drawn last). Empty-area
        // click in a cell is an immediate workspace switch — no
        // drag-or-click ambiguity to resolve.
        if let win = cell.windows.reversed()
            .first(where: { $0.rect.contains(p) })
        {
            pendingDown = (point: p, hit: win, ws: cell.wsIndex)
        } else {
            onPick?(.workspace(workspaceIndex: cell.wsIndex))
        }
    }

    public override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if drag == nil {
            // Theme A: the grabbed target decides the gesture — a
            // header drag swaps the whole workspace, a window-thumb
            // drag moves that window. No modifier keys.
            if let ph = pendingHeaderDown {
                let dx = p.x - ph.point.x, dy = p.y - ph.point.y
                if (dx * dx + dy * dy) < pointerDragThreshold * pointerDragThreshold {
                    return
                }
                guard let srcCell = cells.first(where: {
                    $0.wsIndex == ph.ws
                }) else { return }
                drag = OverviewDrag(
                    sourceWS: ph.ws,
                    kind: .workspace,
                    pid: -1, id: WindowID(serverID: -1),
                    sourceRect: srcCell.rect,
                    srcIDs: srcCell.windows.map(\.id),
                    current: p,
                    dropTargetWS: nil)
                layoutSuppressed = true
                installWorkspaceGhost(for: srcCell)
                NSCursor.closedHand.set()
            } else if let pd = pendingDown {
                let dx = p.x - pd.point.x, dy = p.y - pd.point.y
                if (dx * dx + dy * dy) < pointerDragThreshold * pointerDragThreshold {
                    return
                }
                drag = OverviewDrag(
                    sourceWS: pd.ws,
                    kind: .window,
                    pid: pd.hit.pid, id: pd.hit.id,
                    sourceRect: pd.hit.rect,
                    srcIDs: [],
                    current: p,
                    dropTargetWS: nil)
                layoutSuppressed = true
                installDragGhost(for: pd.hit)
                NSCursor.closedHand.set()
            } else {
                return
            }
        }
        guard var d = drag else { return }
        d.current = p
        d.dropTargetWS = cells.first(where: {
            $0.rect.contains(p) || $0.headerRect.contains(p)
        })
            .map(\.wsIndex)
            .flatMap { $0 == d.sourceWS ? nil : $0 }
        drag = d
        positionDragGhost(at: p)
        needsDisplay = true
    }

    public override func mouseUp(with e: NSEvent) {
        guard !commitZoom.isActive else { return }   // ② zoom in flight
        defer { pendingDown = nil; pendingHeaderDown = nil; NSCursor.arrow.set() }
        // Resolve as click when the gesture never crossed threshold.
        if drag == nil {
            if let pd = pendingDown {
                onPick?(.window(workspaceIndex: pd.ws,
                                pid: pd.hit.pid,
                                windowID: pd.hit.id))
            } else if let ph = pendingHeaderDown {
                onPick?(.workspace(workspaceIndex: ph.ws))
            }
            return
        }
        // Drag path: commit or cancel.
        //
        // CRITICAL: do NOT clear `drag` here. The commit path needs
        // `drag.id` to remain set so the draw loop keeps hiding the
        // source thumb during the backend round-trip (memory:
        // grid-drag-state-lifecycle — clear on backend ack, not on
        // mouseUp). `drag` is cleared in `layoutCells` (commit-
        // landed path) or `cleanupDrag` (cancel path).
        guard let d = drag else { return }
        if let dst = d.dropTargetWS,
           let dstCell = cells.first(where: { $0.wsIndex == dst })
        {
            switch d.kind {
            case .window:
                commitDrop(sourceWS: d.sourceWS,
                           pid: d.pid, id: d.id,
                           dstCell: dstCell)
            case .workspace:
                commitContentSwap(sourceWS: d.sourceWS,
                                  srcIDs: d.srcIDs,
                                  dstCell: dstCell)
            }
        } else {
            cancelDrop(to: d.sourceRect)
        }
        needsDisplay = true
    }

    // MARK: - Drag ghost

    // Construction is the shared FacetView helper (DragGhost.swift),
    // fed the grid's tunables (`gridGhostStyle`). These wrappers map
    // the grid's `OverviewCell` / thumbnail cache into the helper args —
    // including the app-icon fallback when no thumbnail is cached
    // (capture in flight / SR denied) — and keep `dragGhost` + the
    // shadow fade local.

    private func installDragGhost(for hit: MiniWindowHit) {
        let g = makeWindowGhost(
            over: hit.rect,
            thumbnail: thumbnails[hit.id],
            iconFallback: { AppIcons.icon(forPID: hit.pid) },
            style: gridGhostStyle,
            pal: pal)                          // PR-B: grid's per-view palette
        addSubview(g)
        dragGhost = g

        liftShadow(g, style: gridGhostStyle)
    }

    private func installWorkspaceGhost(for cell: OverviewCell) {
        let thumbs = cell.windows.map { hit -> MiniThumbSpec in
            let localRect = NSRect(
                x: hit.rect.minX - cell.rect.minX,
                y: hit.rect.minY - cell.rect.minY,
                width: hit.rect.width,
                height: hit.rect.height)
            let content: MiniThumbContent
            if let img = thumbnails[hit.id] {
                content = .capture(img)
            } else if let icon = AppIcons.icon(forPID: hit.pid) {
                content = .icon(icon)
            } else {
                content = .blank
            }
            return MiniThumbSpec(rect: localRect, content: content)
        }
        let g = makeWorkspaceGhost(cellRect: cell.rect,
                                   label: cell.label,
                                   thumbs: thumbs,
                                   style: gridGhostStyle,
                                   pal: pal)     // PR-B: grid's per-view palette
        addSubview(g)
        dragGhost = g

        liftShadow(g, style: gridGhostStyle)
    }

    private func positionDragGhost(at p: NSPoint) {
        positionGhost(dragGhost, at: p)
    }

    // MARK: - Commit / cancel

    private func commitDrop(sourceWS: Int, pid: Int, id: WindowID,
                            dstCell: OverviewCell) {
        // Record the in-flight move so the next `layoutCells` pass can
        // gate the source-thumb reveal on the backend acking it. The
        // ghost stays at the release point as a placeholder; the FLIP
        // reorder (driven by old→new rects in `layoutCells`) slides the
        // new thumb to its backend-decided final spot. Source cell never
        // animates — the gesture ended where the cursor was.
        if dragGhost != nil {
            lastDrop = OverviewPendingDrop(
                id: id,
                dstWS: dstCell.wsIndex,
                committedAt: Date())
        }
        // Ghost STAYS visible at the release point as a placeholder.
        // When the backend acks and `layoutCells` runs, the ghost
        // slides to the dropped thumb's real new rect, then
        // disappears. `drag` stays set so the source thumb is
        // hidden until ack.
        onMoveWindow?(sourceWS, dstCell.wsIndex, pid, id)
    }

    private func commitContentSwap(sourceWS: Int,
                                   srcIDs: [WindowID],
                                   dstCell: OverviewCell) {
        let dstIDs = dstCell.windows.map(\.id)
        lastSwap = OverviewPendingSwap(
            srcWS: sourceWS,
            dstWS: dstCell.wsIndex,
            srcIDs: srcIDs,
            dstIDs: dstIDs,
            committedAt: Date())
        // No-op swap (both cells empty) → nothing to apply; clean
        // up the ghost so the user sees the cancel.
        if srcIDs.isEmpty && dstIDs.isEmpty {
            lastSwap = nil
            cancelDrop(to: drag?.sourceRect ?? .zero)
            return
        }
        onSwap?(sourceWS, dstCell.wsIndex, srcIDs, dstIDs)
    }

    private func cancelDrop(to sourceRect: NSRect) {
        guard let g = dragGhost else { cleanupDrag(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            g.animator().frame = sourceRect
            g.animator().alphaValue = 0.0
        }) { [weak self] in self?.cleanupDrag() }
    }

    private func cleanupDrag() {
        dragGhost?.removeFromSuperview()
        dragGhost = nil
        layoutSuppressed = false
        // Cancel-drop path's `drag` clear lives here (commitDrop's
        // happens in layoutCells once the backend acks; same for
        // commitContentSwap via lastSwap).
        drag = nil
        lastSwap = nil
        needsDisplay = true
    }

    // MARK: - Thumbnails (Controller-fed)

    public func setThumbnail(_ image: NSImage, for id: WindowID) {
        thumbnails[id] = image
        needsDisplay = true
    }

    public func clearThumbnails() {
        thumbnails.removeAll()
    }

    // MARK: - Keyboard nav (Phase 1f-3 — kbDnD)

    // Reuses Drag struct, ghost view, commitDrop, cancelDrop. Mouse
    // and keyboard both produce the same `drag` state; only the
    // input differs. dropTargetWS for kb = currently-selected cell.

    /// Move the selection cursor by (dx, dy) cells. WRAPS at the edges
    /// (M9-4) — last column→first, last row→first — with a ragged final
    /// row snapping to the nearest real cell in the same row/column
    /// rather than landing on a phantom. On cell change, the window
    /// cursor resets to the header slot. While lifted, also re-aims the
    /// drag target + repositions the ghost.
    public func kbMoveSelection(dx: Int, dy: Int) {
        guard !commitZoom.isActive else { return }   // ② zoom in flight
        let cols = effectiveCols
        guard let sel = kbSelectedWS,
              let cur = cells.firstIndex(where: { $0.wsIndex == sel })
        else { return }
        let ni = gridWrapIndex(index: cur, dx: dx, dy: dy,
                               cols: cols, count: cells.count)
        guard ni < cells.count else { return }
        kbSelectedWS = cells[ni].wsIndex
        // Arrow moves the WS cursor only — land on the header (WS-name)
        // slot (-1) so no window is auto-selected (Tab picks a window).
        // Matches the rail's browse behaviour: arrow ⇒ no window ring,
        // WS name highlighted.
        kbSelectedWindowIdx = -1
        // While dragging via keyboard, the selection IS the drop
        // target.
        if drag != nil { syncKbDragToSelection() }
        needsDisplay = true
    }

    /// Tab / Shift-Tab: cycle the cursor through the cell's slots —
    /// the header (-1) then each window (0…n-1), wrapping at the
    /// ends. An empty cell has only the header slot. No effect while
    /// a lift is in flight.
    public func kbCycleWindow(forward: Bool) {
        guard !commitZoom.isActive else { return }   // ② zoom in flight
        guard drag == nil,
              let sel = kbSelectedWS,
              let cell = cells.first(where: { $0.wsIndex == sel })
        else { return }
        kbSelectedWindowIdx = cycleSlotIndex(
            current: kbSelectedWindowIdx,
            windowCount: cell.windows.count, forward: forward)
        needsDisplay = true
    }


    private func kbSelectedWindow() -> (cell: OverviewCell, hit: MiniWindowHit)? {
        guard let sel = kbSelectedWS,
              kbSelectedWindowIdx >= 0,
              let cell = cells.first(where: { $0.wsIndex == sel }),
              !cell.windows.isEmpty
        else { return nil }
        let ordered = readingOrder(cell.windows)
        let i = max(0, min(ordered.count - 1, kbSelectedWindowIdx))
        return (cell, ordered[i])
    }

    private func syncKbDragToSelection() {
        guard var d = drag, let sel = kbSelectedWS,
              let cell = cells.first(where: { $0.wsIndex == sel })
        else { return }
        d.dropTargetWS = (sel == d.sourceWS) ? nil : sel
        let at = NSPoint(x: cell.rect.midX, y: cell.rect.midY)
        d.current = at
        drag = d
        positionDragGhost(at: at)
    }

    /// Space: lift the keyboard selection — the selected window for a
    /// move, or (header slot, `kbSelectedWindowIdx == -1`) the whole
    /// workspace for a swap. Theme A: no Shift; the selected target
    /// decides. Tab moves between the header and the windows.
    /// Space is a TOGGLE (matches tree): carrying → drop (= Return),
    /// otherwise lift whatever is selected.
    public func kbSpaceLift() {
        guard !commitZoom.isActive else { return }   // ② zoom in flight
        if drag != nil { kbCommit(); return }        // carrying → Space drops
        if kbSelectedWindowIdx == -1 { kbLiftWorkspace() } else { kbLift() }
    }

    /// Lift the keyboard-selected window into the drag state,
    /// identically to a mouse-initiated drag.
    public func kbLift() {
        guard !commitZoom.isActive else { return }   // ② zoom in flight
        guard drag == nil, let s = kbSelectedWindow() else { return }
        let at = NSPoint(x: s.cell.rect.midX, y: s.cell.rect.midY)
        drag = OverviewDrag(
            sourceWS: s.cell.wsIndex,
            kind: .window,
            pid: s.hit.pid, id: s.hit.id,
            sourceRect: s.hit.rect,
            srcIDs: [],
            current: at,
            dropTargetWS: nil)
        layoutSuppressed = true
        installDragGhost(for: s.hit)
        positionDragGhost(at: at)
        needsDisplay = true
    }

    /// Lift the keyboard-selected cell's WHOLE contents for a
    /// workspace swap (header slot selected). Arrow keys then re-aim,
    /// Return commits. Empty source cells can still lift — the user
    /// might intend "move WS-X's contents here, leaving X empty in
    /// return".
    public func kbLiftWorkspace() {
        guard drag == nil, let sel = kbSelectedWS,
              let cell = cells.first(where: { $0.wsIndex == sel })
        else { return }
        let at = NSPoint(x: cell.rect.midX, y: cell.rect.midY)
        drag = OverviewDrag(
            sourceWS: cell.wsIndex,
            kind: .workspace,
            pid: -1, id: WindowID(serverID: -1),
            sourceRect: cell.rect,
            srcIDs: cell.windows.map(\.id),
            current: at,
            dropTargetWS: nil)
        layoutSuppressed = true
        installWorkspaceGhost(for: cell)
        positionDragGhost(at: at)
        needsDisplay = true
    }

    /// Return: commit-drop while lifted, or click-equivalent when
    /// not lifted (switch + focus selected cell's focused window).
    public func kbCommit() {
        if commitZoom.isActive { return }   // a switch zoom (②) is in flight
        if let d = drag {
            if let dst = d.dropTargetWS,
               let dstCell = cells.first(where: { $0.wsIndex == dst })
            {
                switch d.kind {
                case .window:
                    commitDrop(sourceWS: d.sourceWS,
                               pid: d.pid, id: d.id,
                               dstCell: dstCell)
                case .workspace:
                    commitContentSwap(sourceWS: d.sourceWS,
                                      srcIDs: d.srcIDs,
                                      dstCell: dstCell)
                }
            } else {
                // Drop on source / outside any cell → cancel.
                cancelDrop(to: d.sourceRect)
            }
            return
        }
        guard let sel = kbSelectedWS else { return }
        // Return on the selected cell → zoom that cell out to full screen
        // (②), then switch + close. A direct mouse click stays instant.
        if let s = kbSelectedWindow() {
            commitSwitch(target: sel) { [weak self] in
                self?.onPick?(.window(workspaceIndex: sel,
                                      pid: s.hit.pid, windowID: s.hit.id))
            }
        } else {
            commitSwitch(target: sel) { [weak self] in
                self?.onPick?(.workspace(workspaceIndex: sel))
            }
        }
    }

    /// Play the commit "cell zoom → full screen" transition (②) for the
    /// `target` workspace's cell, then run `perform` (the switch + close);
    /// if the cell can't be captured or Reduce Motion is on, run it now.
    private func commitSwitch(target ws: Int, perform: @escaping () -> Void) {
        guard !commitZoom.isActive else { return }
        guard let cell = cells.first(where: { $0.wsIndex == ws }),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let img = snapshotRegion(cell.rect)
        else { perform(); return }
        commitZoom.begin(image: img, from: cell.rect,
                         redraw: { [weak self] in self?.needsDisplay = true },
                         perform: perform)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, commitZoom.isActive {
            commitZoom.finish()   // closed mid-zoom → don't drop the switch
        }
    }

    /// Esc, in order: cancel an in-flight lift → clear a Tab window
    /// selection (back to the header slot, stay open) → dismiss the grid.
    public func kbEscape() {
        if let d = drag {
            cancelDrop(to: d.sourceRect)
        } else if kbSelectedWindowIdx != -1 {
            kbSelectedWindowIdx = -1            // Tab deselect only — don't close
            needsDisplay = true
        } else {
            onDismiss?()
        }
    }
}

// MARK: - OverviewView conformance
//
// Every requirement is satisfied by members declared above (the
// snapshot inputs, the run-ops / move / swap callbacks, layoutCells /
// setThumbnail / clearThumbnails, the BorderFX trio, and the common
// keyboard verbs). The grid-specific surface — `onPick(GridPick)`,
// `config`, the 2-D `kbMoveSelection(dx:dy:)`, FLIP reorder — stays off
// the shared protocol.
extension GridView: OverviewView {}
