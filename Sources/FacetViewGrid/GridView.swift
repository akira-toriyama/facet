// Full-screen overview grid — one cell per workspace, arranged in
// `cols × rows`. Each cell mirrors the screen aspect so window
// mini-rects map cleanly. The view stays controller-free:
// orchestration plugs in via the four callback closures
// (``onDismiss`` / ``onPick`` / ``onDrop`` / ``onSwap``).
// Controller decides what those mean.

import AppKit
import CoreGraphics
import Foundation
import FacetCore
import FacetView

public final class GridView: NSView {

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
    /// Drop-commit callback (window-move). Controller owns the
    /// backend round-trip and the subsequent re-query.
    public var onDrop: ((_ src: Int, _ dst: Int,
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

    /// One per-window hit target inside a cell (scaled logical
    /// frame). Click-on-thumb switches + focuses *that* window;
    /// click-on-empty-cell only switches workspace.
    struct WindowHit: Sendable {
        let pid: Int
        let id: WindowID
        let isFocused: Bool
        let rect: NSRect
    }

    /// One layout-pass snapshot per workspace cell. Holds everything
    /// `draw` and hit-testing need to agree on (no recomputation
    /// drift between paint and click).
    struct Cell {
        let wsIndex: Int
        let rect: NSRect
        // Label/header band (above or below the cell per config). The
        // drag handle for a workspace-content swap: drag = swap,
        // click = switch (Theme A — same model as the tree header).
        let headerRect: NSRect
        let isActive: Bool
        let label: String
        let mode: String          // layout engine (bsp / stack), shown in header
        let windows: [WindowHit]
    }
    private var cells: [Cell] = []

    // MARK: - Drag state

    /// `.window` — dragging a window thumb moves that window to
    /// another WS. `.workspace` — dragging a cell's HEADER swaps the
    /// SOURCE workspace's entire contents with the destination
    /// cell's. The backend's workspace index never changes; only the
    /// windows inside trade places. Theme A: the grabbed target (not
    /// a modifier key) decides which gesture runs.
    enum DragKind { case window, workspace }

    /// Drag-and-drop state. Captured on mouseDown over a window thumb
    /// or a cell header; promoted from a pending-click to a real drag
    /// once the cursor moves past `dragThreshold`. `kind` is decided
    /// at promotion time by which target was grabbed (header =
    /// `.workspace`, thumb = `.window`).
    struct Drag {
        let sourceWS: Int
        let kind: DragKind
        let pid: Int                    // .window: real; .workspace: -1
        let id: WindowID                // .window: real; .workspace: -1
        let sourceRect: NSRect          // .window: thumb; .workspace: cell
        let srcIDs: [WindowID]          // .workspace: all in source; .window: []
        var current: NSPoint            // cursor in view coords
        var dropTargetWS: Int?          // cell != sourceWS under cursor
    }
    private var pendingDown: (point: NSPoint, hit: WindowHit, ws: Int)?
    // Header band pressed: a workspace drag-or-switch candidate
    // (Theme A). Promoted to a `.workspace` swap drag past threshold,
    // else resolved as a WS switch on mouseUp.
    private var pendingHeaderDown: (point: NSPoint, ws: Int)?
    // Workspace whose header the pointer is hovering — brightens the
    // header band + grip (mirrors the tree header hover affordance).
    private var hoverHeaderWS: Int?
    private var drag: Drag?
    private var dragGhost: NSView?
    private var isDragging: Bool { drag != nil }

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

    /// Set by ``commitDrop``; consumed by the next ``layoutCells``
    /// pass that can confirm the move landed (dropped id now lives
    /// in dstWS). Makes the dropped thumb hand off from "ghost at
    /// release point" to its real new rect, and gates the source
    /// thumb's reveal on the move being reflected by the backend
    /// (otherwise refresh ticks racing the round-trip would briefly
    /// show a residual thumb in the source cell — 残像).
    struct PendingDrop {
        let id: WindowID
        let dstWS: Int
        let releaseRect: NSRect
        let committedAt: Date
    }
    private var lastDrop: PendingDrop?

    /// Workspace-swap analogue of ``lastDrop``. Holds the expected
    /// post-swap window membership so ``layoutCells`` can gate the
    /// "clear drag + reveal cells" hand-off on the backend actually
    /// reporting both halves of the swap.
    struct PendingSwap {
        let srcWS: Int
        let dstWS: Int
        let srcIDs: [WindowID]    // started in srcWS → should land in dstWS
        let dstIDs: [WindowID]    // started in dstWS → should land in srcWS
        let committedAt: Date
    }
    private var lastSwap: PendingSwap?

    /// Max time we keep ``drag`` set waiting for the drop's apply.
    /// If the backend never reports the move (it could fail
    /// silently), we give up and reveal the source thumb so the UI
    /// doesn't stay frozen.
    private static let dropAckTimeout: TimeInterval = 1.0

    // MARK: - ScreenCaptureKit thumbnails

    /// `WindowID → captured image`. Populated by the Controller as
    /// captures land during a grid show; ``drawWindowThumb``
    /// consults this first and falls back to the app icon when
    /// missing (capture not yet done, or Screen Recording denied).
    /// Cleared on ``clearThumbnails`` to release memory.
    private var thumbnails: [WindowID: NSImage] = [:]

    // MARK: - Keyboard nav (Phase 1f-3)

    public var kbSelectedWS: Int?
    public var kbSelectedWindowIdx: Int = 0

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
            var hits: [WindowHit] = []
            if useScreen.width > 0 {
                for win in ws.windows {
                    guard let f = win.frame else { continue }
                    let wr = gridScaledWindowRect(
                        windowFrame: f,
                        screenFrame: useScreen,
                        cellRect: cellRect)
                    guard wr.width >= 2, wr.height >= 2 else { continue }
                    hits.append(WindowHit(
                        pid: win.pid,
                        id: win.id,
                        isFocused: win.isFocused,
                        rect: wr))
                }
            }
            // Header band rect (matches the label draw position) —
            // hit target for header drag (swap) / click (switch).
            let headerY = labelPos == "down"
                ? cellRect.maxY + gridLabelGap - 2
                : cellRect.minY - labelH - gridLabelGap + 2
            let headerRect = NSRect(x: cellRect.minX, y: headerY,
                                    width: cellRect.width, height: labelH)
            cells.append(Cell(
                wsIndex: ws.index,
                rect: cellRect,
                headerRect: headerRect,
                isActive: ws.index == activeIndex,
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

    public override func layout() { super.layout(); layoutCells() }

    // MARK: - Draw

    public override func draw(_ dirty: NSRect) {
        // Palette: very faint cell fills + strokes so window thumbs
        // do the visual work, accent reserved for active / drop-target.
        let activeColor = pal.accent
        let cellFill    = pal.dim.withAlphaComponent(0.08)
        let cellStroke  = pal.dim.withAlphaComponent(0.22)
        let labelColor  = pal.text.withAlphaComponent(0.85)
        let activeFill  = pal.accent.withAlphaComponent(0.10)
        let winFill     = pal.text.withAlphaComponent(0.18)
        let winFocused  = pal.accent.withAlphaComponent(0.32)
        let winStroke   = pal.text.withAlphaComponent(0.45)
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
                    pal.text.withAlphaComponent(0.18).setFill()
                    path.fill()
                    pal.text.withAlphaComponent(0.85).setStroke()
                    path.lineWidth = 2
                    path.stroke()
                case .window, .none:
                    pal.accent.withAlphaComponent(0.28).setFill()
                    path.fill()
                    pal.accent.setStroke()
                    path.lineWidth = 2
                    path.stroke()
                }
            } else if isSwapSource {
                pal.text.withAlphaComponent(0.06).setFill()
                path.fill()
                pal.text.withAlphaComponent(0.40).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                (cell.isActive ? activeFill : cellFill).setFill()
                path.fill()
                (cell.isActive ? activeColor.withAlphaComponent(0.7)
                               : cellStroke).setStroke()
                path.lineWidth = cell.isActive ? 1 : 0.5
                path.stroke()
            }
            // Keyboard selection cursor — outline the currently
            // selected cell while NOT lifted (during a lift the
            // drop-target highlight already shows where the ghost
            // will land). Bright text-color stroke distinguishes it
            // from active-WS / drop-target accents.
            if drag == nil, kbSelectedWS == cell.wsIndex {
                pal.text.withAlphaComponent(0.85).setStroke()
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
                    drawWindowThumb(w, at: w.rect,
                                    fill: w.isFocused ? winFocused : winFill,
                                    stroke: winStroke)
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
                    pal.accent.withAlphaComponent(0.30).setFill(); ko.fill()
                    pal.accent.setStroke()
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
                : pal.dim.withAlphaComponent(headerHover ? 0.20 : 0.10))
                .setFill()
            NSBezierPath(roundedRect: hb.insetBy(dx: 0, dy: 1),
                         xRadius: 4, yRadius: 4).fill()
            if headerSel {
                pal.text.withAlphaComponent(0.85).setStroke()
                let ho = NSBezierPath(
                    roundedRect: hb.insetBy(dx: 0.75, dy: 1.25),
                    xRadius: 4, yRadius: 4)
                ho.lineWidth = 1.5
                ho.stroke()
            }
            drawGridGrip(
                in: NSRect(x: hb.minX + 4, y: hb.minY,
                           width: gridHeaderGripW, height: hb.height),
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
                drawHeaderLine(cell.label, font: nameFont, weight: .semibold,
                               color: nameColor, para: lp,
                               in: NSRect(x: nameX,
                                          y: hb.minY + (hb.height - nameH) / 2,
                                          width: nameW, height: nameH))
            } else {
                let modeFont = min(gridHeaderModeMaxFont,
                                   max(gridHeaderModeMinFont,
                                       (hb.height * gridHeaderModeFrac).rounded()))
                // Layout-mode text — accent-2 semibold on the active
                // WS, `pal.dim` on the rest. No pill background — the
                // text + color step alone carries the badge weight,
                // matching the tree header's restyle.
                let modeColor = cell.isActive ? pal.accent2 : pal.dim
                let mAttrs: [NSAttributedString.Key: Any] = [
                    .font: uiFont(modeFont, .semibold),
                    .foregroundColor: modeColor,
                    .paragraphStyle: lp,
                ]
                let modeH = (modeFont * 1.3).rounded()
                let nameH = nameFont * 1.25
                let gap: CGFloat = 3
                let startY = hb.minY + (hb.height - (nameH + gap + modeH)) / 2
                drawHeaderLine(cell.label, font: nameFont, weight: .semibold,
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
                    drawWindowThumb(w, at: r,
                                    fill: w.isFocused ? winFocused : winFill,
                                    stroke: winStroke)
                }
            }
        }
    }

    /// One left-aligned text line of the workspace header.
    private func drawHeaderLine(_ s: String, font: CGFloat,
                                weight: NSFont.Weight, color: NSColor,
                                para: NSParagraphStyle, in rect: NSRect) {
        (s as NSString).draw(in: rect, withAttributes: [
            .font: uiFont(font, weight),
            .foregroundColor: color,
            .paragraphStyle: para,
        ])
    }

    /// A 3-column dot grid — the "drag handle" affordance at the left
    /// of each workspace header band (header drag = WS-swap). Two-
    /// state height awareness mirrors the tree's grip: 10 rows in a
    /// tall rect (the 2-line header) and 3 rows in compact rects, so
    /// the same dot texture renders whether the user is on the tree
    /// or the grid.
    private func drawGridGrip(in r: NSRect, color: NSColor, alpha: CGFloat) {
        let dotR: CGFloat = 1.5
        let xs = [r.minX + dotR + 2, r.minX + dotR + 7,
                  r.minX + dotR + 12]
        let ys: [CGFloat] = r.height >= 28
            ? stride(from: -18.0, through: 18.0, by: 4.0)
                .map { r.midY + $0 }
            : [r.midY - 4, r.midY, r.midY + 4]
        color.withAlphaComponent(alpha).setFill()
        for x in xs {
            for y in ys {
                NSBezierPath(ovalIn: NSRect(x: x - dotR, y: y - dotR,
                                            width: dotR * 2,
                                            height: dotR * 2)).fill()
            }
        }
    }

    /// Shared window-thumb painter — same look whether drawn
    /// statically inside the cell clip or as an in-flight FLIP
    /// tween outside it. Falls back to app icon when no
    /// ScreenCaptureKit thumbnail is cached yet.
    private func drawWindowThumb(_ w: WindowHit, at r: NSRect,
                                 fill: NSColor, stroke: NSColor) {
        let wp = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        fill.setFill(); wp.fill()
        NSGraphicsContext.saveGraphicsState()
        wp.addClip()
        if let img = thumbnails[w.id] {
            img.draw(in: r, from: .zero,
                     operation: .sourceOver, fraction: 1.0,
                     respectFlipped: true, hints: nil)
        } else {
            let iconSide = max(12, min(min(r.width, r.height) - 8, 48))
            if iconSide >= 12, let icon = AppIcons.icon(forPID: w.pid) {
                let iconRect = NSRect(
                    x: r.midX - iconSide / 2,
                    y: r.midY - iconSide / 2,
                    width: iconSide, height: iconSide)
                // GridView is flipped (Y-down); the default
                // NSImage.draw paints upside-down — use the
                // respect-flipped overload.
                icon.draw(in: iconRect, from: .zero,
                          operation: .sourceOver, fraction: 0.95,
                          respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        // Stroke on top so the border isn't covered by the image.
        stroke.setStroke()
        wp.lineWidth = 0.5
        wp.stroke()
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
        if ws != hoverHeaderWS {
            hoverHeaderWS = ws
            needsDisplay = true
        }
        (ws != nil ? NSCursor.openHand : NSCursor.arrow).set()
    }

    public override func mouseExited(with e: NSEvent) {
        if hoverHeaderWS != nil {
            hoverHeaderWS = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    // MARK: - Mouse

    public override func mouseDown(with e: NSEvent) {
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
                if (dx * dx + dy * dy) < dragThreshold * dragThreshold {
                    return
                }
                guard let srcCell = cells.first(where: {
                    $0.wsIndex == ph.ws
                }) else { return }
                drag = Drag(
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
                if (dx * dx + dy * dy) < dragThreshold * dragThreshold {
                    return
                }
                drag = Drag(
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

    private func installDragGhost(for hit: WindowHit) {
        // Ghost installed already at "lifted" size so cursor-follow
        // can start on frame 1 with no pause. Only animation is the
        // shadow softly fading in. Going instant on size + animated
        // only on shadow gives smooth feel without the "ガクッ" of a
        // size tween being yanked by mouseDragged origin writes.
        let lifted = NSRect(
            x: hit.rect.midX - (hit.rect.width  * gridLiftScale) / 2,
            y: hit.rect.midY - (hit.rect.height * gridLiftScale) / 2,
            width:  hit.rect.width  * gridLiftScale,
            height: hit.rect.height * gridLiftScale)
        let g = NSView(frame: lifted)
        g.wantsLayer = true
        g.layer?.cornerRadius = 4
        g.layer?.cornerCurve = .continuous
        g.layer?.masksToBounds = true
        g.layer?.borderColor = pal.accent.cgColor
        g.layer?.borderWidth = 1.5
        g.layer?.shadowColor = NSColor.black.cgColor
        g.layer?.shadowOffset = CGSize(width: 0, height: -4)
        g.layer?.shadowRadius = gridLiftShadowRadius
        g.layer?.shadowOpacity = 0
        // Ghost shows the same ScreenCaptureKit thumbnail the source
        // cell was showing so the drag *looks* like the thumb lifted
        // off the cell. Falls back to accent fill + app icon if no
        // thumbnail cached (capture in flight / SR denied).
        if let img = thumbnails[hit.id] {
            g.layer?.backgroundColor = NSColor.black
                .withAlphaComponent(0.15).cgColor
            let iv = NSImageView(frame: g.bounds)
            iv.image = img
            iv.imageScaling = .scaleAxesIndependently
            iv.imageAlignment = .alignCenter
            iv.autoresizingMask = [.width, .height]
            g.addSubview(iv)
        } else {
            g.layer?.backgroundColor = pal.accent
                .withAlphaComponent(0.45).cgColor
            if let icon = AppIcons.icon(forPID: hit.pid) {
                let side = max(16, min(min(lifted.width,
                                           lifted.height) - 8, 48))
                let iv = NSImageView(frame: NSRect(
                    x: (lifted.width  - side) / 2,
                    y: (lifted.height - side) / 2,
                    width: side, height: side))
                iv.image = icon
                iv.imageScaling = .scaleProportionallyDown
                g.addSubview(iv)
            }
        }
        addSubview(g)
        dragGhost = g

        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = 0
        fade.toValue = gridLiftShadowOpacity
        fade.duration = gridLiftDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.layer?.shadowOpacity = gridLiftShadowOpacity
        g.layer?.add(fade, forKey: "shadow-lift")
    }

    /// Cell-sized ghost for a workspace drag. Reproduces the source
    /// cell's contents (thumbnails laid out in their backend
    /// positions) so the gesture feels like "the whole cell is
    /// floating with the cursor" — visually distinct from the
    /// thumb-sized accent ghost of a window drag. Falls back to a
    /// centred WS label for empty cells.
    private func installWorkspaceGhost(for cell: Cell) {
        let g = FlippedView(frame: cell.rect)
        g.wantsLayer = true
        g.layer?.cornerRadius = gridCellCornerRadius
        g.layer?.cornerCurve = .continuous
        g.layer?.masksToBounds = true
        g.layer?.borderColor = pal.text.withAlphaComponent(0.85).cgColor
        g.layer?.borderWidth = 2
        g.layer?.backgroundColor = pal.text
            .withAlphaComponent(0.10).cgColor
        g.layer?.shadowColor = NSColor.black.cgColor
        g.layer?.shadowOffset = CGSize(width: 0, height: -4)
        g.layer?.shadowRadius = gridLiftShadowRadius
        g.layer?.shadowOpacity = 0

        if cell.windows.isEmpty {
            let label = NSTextField(labelWithString: cell.label)
            label.font = uiFont(gridGhostLabelSize, .bold)
            label.textColor = pal.text.withAlphaComponent(0.95)
            label.alignment = .center
            label.sizeToFit()
            label.frame = NSRect(
                x: (g.bounds.width  - label.frame.width)  / 2,
                y: (g.bounds.height - label.frame.height) / 2,
                width: label.frame.width,
                height: label.frame.height)
            label.autoresizingMask =
                [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            g.addSubview(label)
        } else {
            for hit in cell.windows {
                let localRect = NSRect(
                    x: hit.rect.minX - cell.rect.minX,
                    y: hit.rect.minY - cell.rect.minY,
                    width: hit.rect.width,
                    height: hit.rect.height)
                let iv = NSImageView(frame: localRect)
                iv.wantsLayer = true
                iv.layer?.cornerRadius = 3
                iv.layer?.masksToBounds = true
                if let img = thumbnails[hit.id] {
                    iv.image = img
                    iv.imageScaling = .scaleAxesIndependently
                } else if let icon = AppIcons.icon(forPID: hit.pid) {
                    iv.image = icon
                    iv.imageScaling = .scaleProportionallyDown
                    iv.layer?.backgroundColor = pal.text
                        .withAlphaComponent(0.22).cgColor
                }
                g.addSubview(iv)
            }
        }
        addSubview(g)
        dragGhost = g

        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = 0
        fade.toValue = gridLiftShadowOpacity
        fade.duration = gridLiftDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.layer?.shadowOpacity = gridLiftShadowOpacity
        g.layer?.add(fade, forKey: "shadow-lift")
    }

    private func positionDragGhost(at p: NSPoint) {
        guard let g = dragGhost else { return }
        g.frame.origin = NSPoint(
            x: p.x - g.frame.width / 2,
            y: p.y - g.frame.height / 2)
    }

    // MARK: - Commit / cancel

    private func commitDrop(sourceWS: Int, pid: Int, id: WindowID,
                            dstCell: Cell) {
        // Ghost disappears at release point and the FLIP reorder
        // slides the new thumb FROM that release rect TO its
        // backend-decided final spot. Source cell never animates —
        // the user's gesture ended where their cursor was, not at
        // the old home.
        if let g = dragGhost {
            lastDrop = PendingDrop(
                id: id,
                dstWS: dstCell.wsIndex,
                releaseRect: g.frame,
                committedAt: Date())
        }
        // Ghost STAYS visible at the release point as a placeholder.
        // When the backend acks and `layoutCells` runs, the ghost
        // slides to the dropped thumb's real new rect, then
        // disappears. `drag` stays set so the source thumb is
        // hidden until ack.
        onDrop?(sourceWS, dstCell.wsIndex, pid, id)
    }

    private func commitContentSwap(sourceWS: Int,
                                   srcIDs: [WindowID],
                                   dstCell: Cell) {
        let dstIDs = dstCell.windows.map(\.id)
        lastSwap = PendingSwap(
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

    /// Move the selection cursor by (dx, dy) cells. Clamps at edges.
    /// On cell change, the window cursor resets to the cell's
    /// focused window (or 0 if none). While lifted, also re-aims
    /// drag target + repositions ghost to the new selection's
    /// centre.
    public func kbMoveSelection(dx: Int, dy: Int) {
        let cols = effectiveCols
        let rows = gridRowCount(wsCount: workspaces.count, cols: cols)
        guard let sel = kbSelectedWS,
              let cur = cells.firstIndex(where: { $0.wsIndex == sel })
        else { return }
        let r = cur / cols, c = cur % cols
        let nr = max(0, min(rows - 1, r + dy))
        let nc = max(0, min(cols - 1, c + dx))
        let ni = nr * cols + nc
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
        guard drag == nil,
              let sel = kbSelectedWS,
              let cell = cells.first(where: { $0.wsIndex == sel })
        else { return }
        let n = cell.windows.count
        let slots = n + 1                       // header + windows
        let cur = max(-1, min(n - 1, kbSelectedWindowIdx)) + 1
        let next = forward ? (cur + 1) % slots
                           : (cur - 1 + slots) % slots
        kbSelectedWindowIdx = next - 1          // back to -1…n-1
        needsDisplay = true
    }

    /// Windows in visual reading order — top-to-bottom, left-to-right
    /// (flipped coords: smaller y = top). Tab walks the grid the way
    /// the eye does, not the backend's creation order.
    private func readingOrder(_ wins: [WindowHit]) -> [WindowHit] {
        guard wins.count > 1 else { return wins }
        let band = max(1, (wins.map { $0.rect.height }.max() ?? 1) * 0.5)
        // Cluster into rows (y within `band` = same row, so a sub-pixel
        // y difference between side-by-side windows can't split them),
        // then order each row left → right, rows top → bottom.
        let byY = wins.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[WindowHit]] = []
        for w in byY {
            if let rowY = rows.last?.first?.rect.midY, w.rect.midY - rowY <= band {
                rows[rows.count - 1].append(w)
            } else {
                rows.append([w])
            }
        }
        return rows.flatMap { $0.sorted { $0.rect.midX < $1.rect.midX } }
    }

    private func kbSelectedWindow() -> (cell: Cell, hit: WindowHit)? {
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
    public func kbSpaceLift() {
        if kbSelectedWindowIdx == -1 { kbLiftWorkspace() } else { kbLift() }
    }

    /// Lift the keyboard-selected window into the drag state,
    /// identically to a mouse-initiated drag.
    public func kbLift() {
        guard drag == nil, let s = kbSelectedWindow() else { return }
        let at = NSPoint(x: s.cell.rect.midX, y: s.cell.rect.midY)
        drag = Drag(
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
        drag = Drag(
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
        if let s = kbSelectedWindow() {
            onPick?(.window(workspaceIndex: sel,
                            pid: s.hit.pid, windowID: s.hit.id))
        } else {
            onPick?(.workspace(workspaceIndex: sel))
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
