// Full-screen workspace rail — a Mission-Control-style overview.
//
//   • a near-black BACKDROP hides the desktop behind it
//   • a HERO cell in the centre shows the active workspace large
//   • a ROW of every workspace along the BOTTOM, each a small
//     window-thumbnail mini-screen (active one highlighted)
//
//   click a bottom cell → switch to that workspace
//   click the backdrop / Esc → dismiss
//
// Controller-free, like `GridView`: orchestration plugs in through
// the callback closures. Each cell renders its workspace's windows as
// scaled mini-thumbnails (ScreenCaptureKit captures, app-icon
// fallback) — the same look as the grid overview.
//
// Flipped (y-down) to match the view layer's drawing convention and
// so window mini-rects (backend frames are CG y-down) map without a
// vertical flip.

import AppKit
import CoreGraphics
import FacetCore
import FacetView

public final class RailView: NSView {

    // MARK: - Inputs (Controller-supplied)

    public var workspaces: [Workspace] = []
    public var activeIndex: Int?
    /// Keyboard "browse" cursor — the workspace the centre HERO
    /// previews (←/→ move it, Return commits). Decoupled from
    /// `activeIndex` so browsing doesn't switch until commit. Seeded to
    /// the active WS in `showRail`.
    public var selectedWS: Int?
    /// The display frame windows were measured against (backend CG
    /// coords). Mini-thumb rects scale from this; `.zero` falls back
    /// to the view bounds.
    public var screenFrame: CGRect = .zero
    /// Which edge the strip docks against (M9-3). Set by the Controller
    /// from the CLI `--edge=` / `[rail] edge` config; drives the strip
    /// orientation and which arrow keys browse it.
    public var edge: RailEdge = .bottom
    /// How many strip cells are shown at once before the strip scrolls
    /// (M9-4, `[rail] cells`). Cells stay this fixed size as workspaces
    /// pile up; overflow scrolls instead of shrinking.
    public var cellsTarget: Int = 7

    /// Scroll position along the strip (points). 0 when every workspace
    /// fits; grows as the browse cursor / wheel scrolls past the
    /// viewport. Clamped to `maxScrollOffset` on every relayout.
    var scrollOffset: CGFloat = 0
    /// Maximum scroll, recomputed each relayout (`0` when all fit).
    private var maxScrollOffset: CGFloat = 0
    /// The strip band rect (drawing-space) — cells are clipped to it so
    /// a partially-scrolled cell "peeks" at the viewport edge.
    private var stripRect: NSRect = .zero
    /// Strip running-axis length per cell slot (fixed-size cells).
    private var slotAlong: CGFloat = 0

    // MARK: - Callbacks

    /// Click a workspace cell (empty area / header) or commit a
    /// keyboard browse → switch to that WS. The Controller owns the
    /// backend round-trip + whether the overlay then dismisses.
    public var onPick: ((Int) -> Void)?
    /// Click a specific window thumbnail → switch to its WS AND focus
    /// THAT window (grid parity). `nil`-safe: falls back to a plain
    /// switch via `onPick` is the caller's choice.
    public var onPickWindow: ((_ ws: Int, _ pid: Int, _ id: WindowID) -> Void)?
    /// Click the backdrop (no cell) or Esc → dismiss.
    public var onDismiss: (() -> Void)?
    /// Drag a window thumbnail onto another workspace cell → move it
    /// there. The overlay STAYS OPEN so the user sees the result.
    public var onMoveWindow: ((_ src: Int, _ dst: Int,
                               _ pid: Int, _ id: WindowID) -> Void)?
    /// Drag a cell's header onto another cell → swap the two
    /// workspaces' contents (indices stay put).
    public var onSwap: ((_ srcWS: Int, _ dstWS: Int,
                         _ srcIDs: [WindowID], _ dstIDs: [WindowID]) -> Void)?

    // MARK: - Captured thumbnails

    // internal so the drag-ghost extension (RailDrag.swift) can read it.
    var thumbnails: [WindowID: NSImage] = [:]

    // MARK: - Layout snapshot

    /// One window mini-thumbnail inside a cell (view coords).
    struct WinHit {
        let id: WindowID
        let pid: Int
        let isFocused: Bool
        let rect: NSRect
        let mark: String?      // user mark (M9-5 #3 corner badge)
    }
    /// One workspace mini-screen — used for both the bottom row and
    /// the centre hero. Recomputed on every relayout so paint and
    /// hit-testing can't drift.
    struct Cell {
        let wsIndex: Int
        let rect: NSRect          // the mini-screen rect
        let headerRect: NSRect    // grid-style header band (bottom cells); .zero for the hero
        let isActive: Bool
        let name: String
        let mode: String
        let count: Int
        let wins: [WinHit]
        let isHero: Bool
    }
    private(set) var cells: [Cell] = []     // bottom row (all workspaces)
    private(set) var hero: Cell?            // centre (active workspace)

    private var hoverWS: Int? {
        didSet { if hoverWS != oldValue { needsDisplay = true } }
    }
    /// Bottom cell whose HEADER the pointer is over — brightens the
    /// band + grip (the grab affordance for a WS swap, Phase R3).
    var hoverHeaderWS: Int?
    private var trackingArea: NSTrackingArea?

    // MARK: - Drag state (window move + WS swap)

    enum DragKind { case window, workspace }
    /// Active drag — `.window` moves one window, `.workspace` swaps a
    /// whole cell's contents. Decided at promotion by which target was
    /// grabbed (window thumb vs header). NOT cleared on mouseUp — the
    /// landing gate / cancel path clears it once the backend acks, so
    /// the source thumb stays hidden through the round-trip (memory
    /// grid-drag-state-lifecycle).
    struct Drag {
        let sourceWS: Int
        let kind: DragKind
        let pid: Int                  // .window: real; .workspace: -1
        let id: WindowID              // .window: real; .workspace: -1
        let sourceRect: NSRect
        let srcIDs: [WindowID]        // .workspace: all in source; .window: []
        var current: NSPoint
        var dropTargetWS: Int?        // bottom cell != source, else nil
    }
    struct PendingDrop {
        let id: WindowID; let dstWS: Int; let committedAt: Date
    }
    struct PendingSwap {
        let srcWS: Int; let dstWS: Int
        let srcIDs: [WindowID]; let dstIDs: [WindowID]; let committedAt: Date
    }

    // mouseDown candidates (resolved to a drag past threshold, else a
    // click on mouseUp).
    var pendingDown: (point: NSPoint, hit: WinHit, ws: Int)?
    var pendingHeaderDown: (point: NSPoint, ws: Int)?
    var drag: Drag?
    var dragGhost: NSView?
    /// Freeze `layoutCells` mid-gesture so the source cell can't shift
    /// under the cursor; released by the landing gate.
    var layoutSuppressed = false
    var lastDrop: PendingDrop?
    var lastSwap: PendingSwap?
    /// Give up waiting for a move/swap to land after this and reveal
    /// the source so the UI can't freeze on a silent backend failure.
    static let railDropAckTimeout: TimeInterval = 1.0

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    public func layoutCells() {
        // Drag landing gate (runs before suppression so a landed
        // move/swap releases it + rebuilds). While a drop is in flight
        // we keep the old cells so the source thumb doesn't shift under
        // the cursor; clear `drag` only when the backend confirms the
        // move (memory grid-drag-state-lifecycle), or after a timeout.
        if let ld = lastDrop {
            let landed = workspaces.contains {
                $0.index == ld.dstWS && $0.windows.contains { $0.id == ld.id }
            }
            if landed || Date().timeIntervalSince(ld.committedAt) > Self.railDropAckTimeout {
                clearDrag()
            } else { return }
        }
        if let ls = lastSwap {
            let s = workspaces.first { $0.index == ls.srcWS }
            let d = workspaces.first { $0.index == ls.dstWS }
            let landed: Bool = {
                guard let s, let d else { return false }
                let srcNow = Set(s.windows.map(\.id))
                let dstNow = Set(d.windows.map(\.id))
                return ls.srcIDs.allSatisfy(dstNow.contains)
                    && ls.dstIDs.allSatisfy(srcNow.contains)
            }()
            if landed || Date().timeIntervalSince(ls.committedAt) > Self.railDropAckTimeout {
                clearDrag()
            } else { return }
        }
        if layoutSuppressed { return }

        cells.removeAll(); hero = nil
        guard !workspaces.isEmpty, bounds.width > 1, bounds.height > 1 else {
            needsDisplay = true; return
        }
        let useScreen = screenFrame.width > 1 ? screenFrame : bounds
        let aspect = useScreen.width / max(1, useScreen.height)
        let horizontal = edge.axis == .horizontal

        // -- Strip band + hero area for the docked edge (pure split). --
        let crossScreen = horizontal ? bounds.height : bounds.width
        let thickness = (crossScreen * railStripSizeFrac).rounded()
        let (strip, heroArea) = railBands(in: bounds, edge: edge,
                                          thickness: thickness,
                                          outerPad: railOuterPad,
                                          heroGap: railCellGap)
        stripRect = strip

        // -- Strip cells: every workspace as a fixed-size mini-screen +
        //    header, stacked along the cross axis (header band always a
        //    horizontal band — above the thumb, or below on a top rail).
        //    `cellsTarget` slots fit along the strip; extra workspaces
        //    SCROLL rather than shrink (M9-4). --
        let n = workspaces.count
        let along = horizontal ? strip.width : strip.height
        let availAlong = max(1, along - railOuterPad * 2)
        let visible = max(1, cellsTarget)
        let slot = max(railCellMinDim, availAlong / CGFloat(visible))
        slotAlong = slot

        // Header height + thumb box. The header+gap+thumb block always
        // stacks vertically; it fits inside the cross thickness on a
        // horizontal strip, inside the slot on a vertical one.
        let crossBudget = max(1, thickness - railOuterPad)
        let stackBudget = horizontal ? crossBudget : slot
        let rawHeaderH = min(railHeaderMaxH,
                             max(railHeaderMinH,
                                 (stackBudget * railHeaderRatio).rounded()))
        let headerH = min(rawHeaderH, max(8, stackBudget - railLabelGap - 8))
        // Thumb box (boxW × boxH) and the largest landscape thumb in it.
        let boxW = horizontal ? slot : crossBudget
        let boxH = horizontal ? max(1, crossBudget - headerH - railLabelGap)
                              : max(1, slot - headerH - railLabelGap)
        let thumbH = min(boxH, boxW / aspect)
        let thumbW = thumbH * aspect
        let headerOnTop = edge != .top   // top rail flips the header below

        // Scroll: fit-or-scroll. n ≤ visible → centre, no scroll.
        let content = CGFloat(n) * slot
        maxScrollOffset = max(0, content - availAlong)
        let centred = maxScrollOffset <= 0
        if centred { scrollOffset = 0 }
        else { scrollOffset = max(0, min(maxScrollOffset, scrollOffset)) }
        let alongOrigin = (horizontal ? strip.minX : strip.minY) + railOuterPad
        let alongBase = centred
            ? alongOrigin + (availAlong - content) / 2
            : alongOrigin - scrollOffset
        // The header+gap+thumb block is a fixed (thumbW × blockH) box;
        // it tiles along the strip and centres across the thickness.
        // The header is always a horizontal band, stacked in screen-Y
        // above the thumb (or below on a `.top` rail).
        let blockH = headerH + railLabelGap + thumbH
        for (i, ws) in workspaces.enumerated() {
            let slotStart = alongBase + CGFloat(i) * slot
            let blockX: CGFloat, blockY: CGFloat
            if horizontal {
                blockX = slotStart + (slot - thumbW) / 2
                blockY = strip.minY + (strip.height - blockH) / 2
            } else {
                blockX = strip.minX + (strip.width - thumbW) / 2
                blockY = slotStart + (slot - blockH) / 2
            }
            let headerY = headerOnTop ? blockY : blockY + thumbH + railLabelGap
            let thumbY  = headerOnTop ? blockY + headerH + railLabelGap : blockY
            let cellRect = NSRect(x: blockX.rounded(), y: thumbY.rounded(),
                                  width: thumbW, height: thumbH)
            let headerRect = NSRect(x: blockX.rounded(), y: headerY.rounded(),
                                    width: thumbW, height: headerH)
            cells.append(Cell(wsIndex: ws.index, rect: cellRect,
                              headerRect: headerRect, isActive: ws.isActive,
                              name: ws.name, mode: ws.layoutMode,
                              count: ws.windows.count,
                              wins: scaledWins(ws, cellRect, useScreen),
                              isHero: false))
        }

        // -- Hero: the SELECTED workspace (browse) — aspect-fit, centred
        //    in the area the strip left free. --
        if heroArea.width > 1, heroArea.height > 1,
           let act = workspaces.first(where: { $0.index == selectedWS })
            ?? workspaces.first(where: { $0.isActive })
            ?? workspaces.first {
            var hCellW = heroArea.width
            var hCellH = heroArea.height
            if hCellW / hCellH > aspect { hCellW = hCellH * aspect }
            else { hCellH = hCellW / aspect }
            let hx = (heroArea.minX + (heroArea.width - hCellW) / 2).rounded()
            let hy = (heroArea.minY + (heroArea.height - hCellH) / 2).rounded()
            let hCellRect = NSRect(x: hx, y: hy, width: hCellW, height: hCellH)
            hero = Cell(wsIndex: act.index, rect: hCellRect,
                        headerRect: .zero, isActive: act.isActive,
                        name: act.name, mode: act.layoutMode,
                        count: act.windows.count,
                        wins: scaledWins(act, hCellRect, useScreen),
                        isHero: true)
        }

        // Repair a stranded browse cursor: if the selected WS was
        // removed mid-browse (auto-removed / mac-desktop catalog swap),
        // snap it to the hero so the ←/→ cursor and the previewed hero
        // stay in sync and the next arrow continues from what's shown.
        if !cells.contains(where: { $0.wsIndex == selectedWS }) {
            selectedWS = hero?.wsIndex ?? cells.first?.wsIndex
        }
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        layoutCells()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCells()
    }

    /// Map a workspace's windows into mini-thumbnail rects inside a
    /// cell. Both window frame and `screen` are CG y-down, so this is
    /// a straight scale (no vertical flip) — the cell is in the
    /// flipped view's coords. (Local copy of the grid's
    /// `gridScaledWindowRect`; kept module-local to avoid a
    /// cross-view-module import for one pure helper.)
    private func scaledWins(_ ws: Workspace, _ cell: NSRect,
                            _ screen: CGRect) -> [WinHit] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        let sx = cell.width / screen.width
        let sy = cell.height / screen.height
        var out: [WinHit] = []
        for win in ws.windows {
            guard let f = win.frame else { continue }
            let r = NSRect(x: cell.minX + (f.minX - screen.minX) * sx,
                           y: cell.minY + (f.minY - screen.minY) * sy,
                           width: f.width * sx, height: f.height * sy)
            guard r.width >= 2, r.height >= 2 else { continue }
            out.append(WinHit(id: win.id, pid: win.pid,
                              isFocused: win.isFocused, rect: r,
                              mark: win.mark))
        }
        return out
    }

    private func stripCellAt(_ p: NSPoint) -> Cell? {
        // Only cells whose visible (clipped-to-strip) area is under the
        // pointer count — a fully-scrolled-off cell never matches even
        // though it still exists in `cells` (kept for peek + hit order).
        guard stripRect.isEmpty || stripRect.contains(p) else { return nil }
        return cells.first { $0.rect.contains(p) || $0.headerRect.contains(p) }
    }

    // MARK: - Thumbnails

    public func setThumbnail(_ image: NSImage, for id: WindowID) {
        thumbnails[id] = image
        needsDisplay = true
    }

    public func clearThumbnails() {
        thumbnails.removeAll()
    }

    // MARK: - Drawing

    public override func draw(_ dirty: NSRect) {
        // Backdrop — hides the desktop.
        NSColor.black.withAlphaComponent(railBackdropAlpha).setFill()
        bounds.fill()

        if let h = hero { drawCell(h) }
        // Strip cells are clipped to the strip band so an overflow-
        // scrolled cell "peeks" half-off the viewport edge (the "there's
        // more" cue) instead of drawing over the hero. A drag ghost is a
        // separate subview, unaffected by this clip.
        if stripRect.isEmpty {
            for c in cells { drawCell(c) }
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: stripRect).addClip()
            for c in cells { drawCell(c) }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        // Wheel / two-finger scroll moves the strip along its axis when
        // there's overflow; a no-op otherwise (everything already fits).
        guard maxScrollOffset > 0 else { return }
        let d = edge.axis == .horizontal ? (event.scrollingDeltaX != 0
                    ? event.scrollingDeltaX : event.scrollingDeltaY)
                                         : event.scrollingDeltaY
        let next = max(0, min(maxScrollOffset, scrollOffset - d))
        guard next != scrollOffset else { return }
        scrollOffset = next
        layoutCells()
    }

    private func drawCell(_ c: Cell) {
        let path = NSBezierPath(roundedRect: c.rect,
                               xRadius: railCellRadius, yRadius: railCellRadius)
        // Mini-screen background.
        (pal.bg ?? NSColor.windowBackgroundColor)
            .withAlphaComponent(0.55).setFill()
        path.fill()

        // Window mini-thumbnails, clipped to the cell. The window being
        // dragged is hidden everywhere (its ghost stands in) so it looks
        // lifted off both the hero and its bottom cell.
        let dragSrcID: WindowID? = (drag?.kind == .window) ? drag?.id : nil
        let winFill = pal.text.withAlphaComponent(0.16)
        let winFocused = pal.accent.withAlphaComponent(0.30)
        let winStroke = pal.text.withAlphaComponent(0.40)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        for w in c.wins where w.id != dragSrcID {
            drawThumb(w, fill: w.isFocused ? winFocused : winFill,
                      stroke: winStroke)
        }
        NSGraphicsContext.restoreGraphicsState()

        // Border priority: drop target → swap source → hero (focal) →
        // active WS → keyboard-browse selection → hover → divider. The
        // drop target is colour-coded by drag kind and the lifted source
        // is tinted — matching the grid so a window-move vs a whole-WS
        // swap reads at a glance (M9-5 #1).
        if let d = drag, d.dropTargetWS == c.wsIndex {
            switch d.kind {
            case .workspace:
                pal.text.withAlphaComponent(0.18).setFill(); path.fill()
                pal.text.withAlphaComponent(0.85).setStroke(); path.lineWidth = 2
            case .window:
                pal.accent.withAlphaComponent(0.28).setFill(); path.fill()
                pal.accent.setStroke(); path.lineWidth = 2
            }
        } else if let d = drag, d.kind == .workspace, d.sourceWS == c.wsIndex {
            pal.text.withAlphaComponent(0.06).setFill(); path.fill()
            pal.text.withAlphaComponent(0.40).setStroke(); path.lineWidth = 1
        } else if c.isHero {
            // Always prominent: accent when it's also the live active
            // WS, bright neutral when browsing a different WS.
            (c.isActive ? pal.accent : pal.text.withAlphaComponent(0.85)).setStroke()
            path.lineWidth = 2.5
        } else if c.isActive {
            pal.accent.setStroke(); path.lineWidth = 2
        } else if drag == nil && selectedWS == c.wsIndex {
            pal.text.withAlphaComponent(0.85).setStroke(); path.lineWidth = 2
        } else if hoverWS == c.wsIndex {
            pal.text.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1.5
        } else {
            pal.divider.setStroke(); path.lineWidth = 1
        }
        path.stroke()

        // The hero is the centre of attention and gets no caption; the
        // small bottom cells get the grid-style header (name + mode +
        // grip — the swap grab affordance).
        if !c.isHero { drawHeader(c) }

        // Keyboard-selected window: a prominent accent ring + fill tint,
        // drawn in BOTH tiers — the centre hero (large) and the selected
        // WS's bottom cell (small), matched by window id (suppressed
        // while lifted — the ghost carries the selection then).
        if drag == nil, let sel = kbSelectedWindow(),
           c.isHero || c.wsIndex == selectedWS,
           let hit = c.wins.first(where: { $0.id == sel.id }) {
            let ring = NSBezierPath(roundedRect: hit.rect.insetBy(dx: -1, dy: -1),
                                    xRadius: 3, yRadius: 3)
            pal.accent.withAlphaComponent(0.30).setFill(); ring.fill()
            pal.accent.setStroke(); ring.lineWidth = c.isHero ? 3 : 2; ring.stroke()
        }
    }

    private func drawThumb(_ w: WinHit, fill: NSColor, stroke: NSColor) {
        let p = NSBezierPath(roundedRect: w.rect, xRadius: 3, yRadius: 3)
        fill.setFill(); p.fill()
        // Real capture only — the Controller's thumbnail timer keeps
        // the cache warm in the background, so an open paints actual
        // thumbnails. No app-icon fallback (a not-yet-captured window
        // shows just the subtle fill until its image lands).
        if let img = thumbnails[w.id] {
            NSGraphicsContext.saveGraphicsState()
            p.addClip()
            img.draw(in: w.rect, from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        stroke.setStroke(); p.lineWidth = 0.5; p.stroke()
        if let mark = w.mark { drawMiniMarkBadge(mark, in: w.rect) }
    }

    // MARK: - Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect,
                      .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverWS = stripCellAt(p)?.wsIndex
        let hh = stripCellAt(p).flatMap {
            $0.headerRect.contains(p) ? $0.wsIndex : nil }
        if hh != hoverHeaderWS { hoverHeaderWS = hh; needsDisplay = true }
        // The overlay is key, so the cursor sticks: an open hand over a
        // header advertises the grab (header drag = swap, Phase R3).
        (hh != nil ? NSCursor.openHand : NSCursor.arrow).set()
    }

    public override func mouseExited(with event: NSEvent) {
        hoverWS = nil
        if hoverHeaderWS != nil { hoverHeaderWS = nil; needsDisplay = true }
        NSCursor.arrow.set()
    }

    // MARK: - Mouse (click switch / drag move / drag swap / dismiss)

    private func heroWinAt(_ p: NSPoint) -> WinHit? {
        hero?.wins.reversed().first { $0.rect.contains(p) }
    }

    public override func mouseDown(with event: NSEvent) {
        // A keyboard lift owns the drag; ignore mouse presses until it
        // commits (Return) or cancels (Esc) so a stray click can't
        // commit it at the keyboard-aimed target.
        guard drag == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Header press → workspace drag (swap) or click (switch).
        if let cell = cells.first(where: { $0.headerRect.contains(p) }) {
            pendingHeaderDown = (p, cell.wsIndex); return
        }
        // Window-thumb press → window drag (move) or click (switch).
        // The big hero windows are the primary, ergonomic drag source;
        // the tiny bottom-cell windows are a secondary source.
        if let w = heroWinAt(p), let h = hero {
            pendingDown = (p, w, h.wsIndex); return
        }
        if let cell = cells.first(where: { $0.rect.contains(p) }) {
            if let w = cell.wins.reversed().first(where: { $0.rect.contains(p) }) {
                pendingDown = (p, w, cell.wsIndex)
            } else {
                onPick?(cell.wsIndex)          // empty cell area → switch+close
            }
            return
        }
        // The hero is the focal preview, not a target — clicking its
        // empty area does nothing. Only the true backdrop dismisses.
        if let h = hero, h.rect.contains(p) { return }
        onDismiss?()
    }

    public override func mouseDragged(with event: NSEvent) {
        // Only act on a real mouse gesture (a press set a pending). A
        // keyboard lift has none, so mouse motion can't hijack its aim.
        guard pendingDown != nil || pendingHeaderDown != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        if drag == nil {
            // The grabbed target decides the gesture (no modifier keys):
            // a header drag swaps the whole workspace, a window-thumb
            // drag moves that window.
            if let ph = pendingHeaderDown {
                let dx = p.x - ph.point.x, dy = p.y - ph.point.y
                if dx * dx + dy * dy < railDragThreshold * railDragThreshold { return }
                guard let src = cells.first(where: { $0.wsIndex == ph.ws }) else { return }
                // Source the swap's window set from the LIVE workspace,
                // not the render-filtered cell thumbs — a frameless /
                // sub-2pt window has no thumb but must still move.
                let srcIDs = workspaces.first(where: { $0.index == ph.ws })?
                    .windows.map(\.id) ?? src.wins.map(\.id)
                drag = Drag(sourceWS: ph.ws, kind: .workspace, pid: -1,
                            id: WindowID(serverID: -1), sourceRect: src.rect,
                            srcIDs: srcIDs, current: p, dropTargetWS: nil)
                layoutSuppressed = true
                installWorkspaceGhost(for: src)
                NSCursor.closedHand.set()
            } else if let pd = pendingDown {
                let dx = p.x - pd.point.x, dy = p.y - pd.point.y
                if dx * dx + dy * dy < railDragThreshold * railDragThreshold { return }
                drag = Drag(sourceWS: pd.ws, kind: .window, pid: pd.hit.pid,
                            id: pd.hit.id, sourceRect: pd.hit.rect, srcIDs: [],
                            current: p, dropTargetWS: nil)
                layoutSuppressed = true
                installDragGhost(for: pd.hit)
                NSCursor.closedHand.set()
            } else { return }
        }
        guard var d = drag else { return }
        d.current = p
        // Drop targets are BOTTOM cells only (not the hero — it's the
        // active WS, already its own bottom cell). A cell == source is
        // not a target (no self-move).
        let over = cells.first { $0.rect.contains(p) || $0.headerRect.contains(p) }?.wsIndex
        d.dropTargetWS = (over == d.sourceWS) ? nil : over
        drag = d
        positionDragGhost(at: p)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer { pendingDown = nil; pendingHeaderDown = nil; NSCursor.arrow.set() }
        // No mouse pending → this mouseUp belongs to no mouse gesture
        // (e.g. a click during a keyboard lift). Leave the keyboard
        // drag to Return/Esc.
        guard pendingDown != nil || pendingHeaderDown != nil else { return }
        if drag == nil {
            // No drag crossed threshold → resolve as a click.
            if let pd = pendingDown {
                // Window thumb → switch to its WS AND focus THAT window.
                onPickWindow?(pd.ws, pd.hit.pid, pd.hit.id)
            } else if let ph = pendingHeaderDown {
                onPick?(ph.ws)                 // header → switch WS only
            }
            return
        }
        // Drag path: commit or cancel. Do NOT clear `drag` here — the
        // landing gate (commit) / cancel animation owns the teardown.
        guard let d = drag else { return }
        if let dst = d.dropTargetWS,
           let dstCell = cells.first(where: { $0.wsIndex == dst }) {
            switch d.kind {
            case .window:
                commitDrop(sourceWS: d.sourceWS, pid: d.pid, id: d.id, dstCell: dstCell)
            case .workspace:
                commitContentSwap(sourceWS: d.sourceWS, srcIDs: d.srcIDs, dstCell: dstCell)
            }
        } else {
            cancelDrop(to: d.sourceRect)
        }
        needsDisplay = true
    }

    // MARK: - Keyboard (browse + DnD, Phase R4 + parity)

    /// Per-window keyboard cursor WITHIN the selected (hero) WS.
    ///   -1 = whole-WS / none (browse; Space lifts the WS for a swap)
    ///    0..n-1 = a specific hero window (Space lifts it for a move)
    public var kbSelectedWindowIdx: Int = -1

    /// Windows in visual reading order — top-to-bottom, left-to-right
    /// (flipped coords: smaller y = top). So Tab walks the grid the way
    /// the eye does (left-top → right-top → left-bottom → …), not the
    /// backend's creation order.
    private func readingOrder(_ wins: [WinHit]) -> [WinHit] {
        guard wins.count > 1 else { return wins }
        let band = max(1, (wins.map { $0.rect.height }.max() ?? 1) * 0.5)
        // Cluster into rows (y within `band` = same row, so a sub-pixel
        // y difference between side-by-side windows can't split them),
        // then order each row left → right, rows top → bottom.
        let byY = wins.sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[WinHit]] = []
        for w in byY {
            if let rowY = rows.last?.first?.rect.midY, w.rect.midY - rowY <= band {
                rows[rows.count - 1].append(w)
            } else {
                rows.append([w])
            }
        }
        return rows.flatMap { $0.sorted { $0.rect.midX < $1.rect.midX } }
    }

    /// The keyboard-selected window: the kbSelectedWindowIdx-th window
    /// (in reading order) of the SELECTED WS, taken from the HERO (it
    /// shows the full window list large). The ring is drawn in BOTH
    /// tiers — the hero and the matching bottom cell — by window id.
    private func kbSelectedWindow() -> WinHit? {
        guard kbSelectedWindowIdx >= 0, let h = hero, !h.wins.isEmpty
        else { return nil }
        let ordered = readingOrder(h.wins)
        return ordered[max(0, min(ordered.count - 1, kbSelectedWindowIdx))]
    }

    /// Browse-axis arrow : not lifted → move the WS browse cursor (hero
    /// previews it); lifted → re-aim the drop target along the strip
    /// (dual role, mirrors the grid). `dx` is +1 / −1 along the strip,
    /// supplied by the Controller for whichever axis the edge runs. The
    /// cursor WRAPS (last→first, first→last) — M9-4.
    public func kbMoveSelection(dx: Int) {
        guard !cells.isEmpty else { return }
        let cur = cells.firstIndex { $0.wsIndex == selectedWS } ?? 0
        let ni = (cur + dx + cells.count) % cells.count   // wrap
        guard cells[ni].wsIndex != selectedWS else { return }
        selectedWS = cells[ni].wsIndex
        keepSelectedWSVisible()
        if drag != nil {
            syncRailDragToSelection()      // lifted → arrows AIM the destination
        } else {
            kbSelectedWindowIdx = -1       // browse → reset window cursor for the new WS
            layoutCells()                  // rebuild hero (+ selection cursor)
        }
    }

    /// Scroll the strip so the browse-selected workspace is fully in
    /// view (no-op when everything already fits). Pure offset maths in
    /// `railScrollToShow`; the relayout that follows applies it.
    private func keepSelectedWSVisible() {
        guard maxScrollOffset > 0, slotAlong > 0,
              let idx = cells.firstIndex(where: { $0.wsIndex == selectedWS })
        else { return }
        let along = (edge.axis == .horizontal ? stripRect.width : stripRect.height)
            - railOuterPad * 2
        scrollOffset = railScrollToShow(index: idx, count: cells.count,
                                        slot: slotAlong, avail: max(1, along),
                                        offset: scrollOffset)
    }

    /// Tab / Shift-Tab : cycle the SELECTED WS's bottom-cell windows +
    /// the whole-WS slot (-1). Whole-WS = swap-lift target; a window =
    /// move-lift target.
    public func kbCycleWindow(forward: Bool) {
        guard drag == nil, let h = hero else { return }
        let slots = h.wins.count + 1                        // whole-WS(-1) + windows
        let cur = max(-1, min(h.wins.count - 1, kbSelectedWindowIdx)) + 1
        let next = forward ? (cur + 1) % slots : (cur - 1 + slots) % slots
        kbSelectedWindowIdx = next - 1
        needsDisplay = true
    }

    /// Space : lift whatever is selected — a window (move) or, on the
    /// whole-WS slot, the whole workspace (swap).
    public func kbSpaceLift() {
        if kbSelectedWindowIdx == -1 { kbLiftWorkspace() } else { kbLiftWindow() }
    }

    private func kbLiftWindow() {
        guard drag == nil, let h = hero, let sel = kbSelectedWindow() else { return }
        // Lift from the BOTTOM cell's window (small) so the ghost matches
        // the rail's bottom-row size, not the big hero. Fall back to the
        // hero window if that window has no thumb in the bottom cell.
        let hit = cells.first(where: { $0.wsIndex == selectedWS })?
            .wins.first(where: { $0.id == sel.id }) ?? sel
        let at = NSPoint(x: hit.rect.midX, y: hit.rect.midY)
        drag = Drag(sourceWS: h.wsIndex, kind: .window,
                    pid: hit.pid, id: hit.id, sourceRect: hit.rect, srcIDs: [],
                    current: at, dropTargetWS: nil)
        layoutSuppressed = true
        installDragGhost(for: hit)
        positionDragGhost(at: at)
        needsDisplay = true
    }

    private func kbLiftWorkspace() {
        guard drag == nil, let ws = selectedWS,
              let cell = cells.first(where: { $0.wsIndex == ws }) else { return }
        // Live workspace windows (not the render-filtered thumbs).
        let srcIDs = workspaces.first(where: { $0.index == ws })?.windows.map(\.id)
            ?? cell.wins.map(\.id)
        let at = NSPoint(x: cell.rect.midX, y: cell.rect.midY)
        drag = Drag(sourceWS: ws, kind: .workspace, pid: -1,
                    id: WindowID(serverID: -1), sourceRect: cell.rect,
                    srcIDs: srcIDs, current: at, dropTargetWS: nil)
        layoutSuppressed = true
        installWorkspaceGhost(for: cell)
        positionDragGhost(at: at)
        needsDisplay = true
    }

    /// While lifted, an arrow advances `selectedWS` (the aim cursor);
    /// re-target the drop + teleport the ghost to the aimed cell.
    private func syncRailDragToSelection() {
        guard var d = drag, let sel = selectedWS,
              let cell = cells.first(where: { $0.wsIndex == sel }) else { return }
        d.dropTargetWS = (sel == d.sourceWS) ? nil : sel
        let at = NSPoint(x: cell.rect.midX, y: cell.rect.midY)
        d.current = at
        drag = d
        positionDragGhost(at: at)
        needsDisplay = true
    }

    /// Return : lifted → commit the move/swap (stay open); not lifted →
    /// switch to the selection (focus a Tab-selected window) + close.
    public func kbCommit() {
        if let d = drag {
            if let dst = d.dropTargetWS,
               let dstCell = cells.first(where: { $0.wsIndex == dst }) {
                switch d.kind {
                case .window:
                    commitDrop(sourceWS: d.sourceWS, pid: d.pid, id: d.id, dstCell: dstCell)
                case .workspace:
                    commitContentSwap(sourceWS: d.sourceWS, srcIDs: d.srcIDs, dstCell: dstCell)
                }
            } else {
                cancelDrop(to: d.sourceRect)     // aimed home / nowhere → cancel
            }
            return
        }
        guard let ws = selectedWS else { return }
        if let hit = kbSelectedWindow() {
            onPickWindow?(ws, hit.pid, hit.id)   // Tab-selected window → switch + focus it
        } else {
            onPick?(ws)                          // whole-WS → switch + close
        }
    }

    /// Escape, in order: cancel an in-flight lift → clear a Tab window
    /// selection (stay open) → dismiss the rail.
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
