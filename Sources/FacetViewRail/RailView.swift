// Full-screen workspace rail — a Mission-Control-style switcher.
//
//   • a solid black BACKDROP hides the desktop behind it
//   • a HERO cell shows the active (centred) workspace large
//   • a STRIP of workspace thumbnails docked against one screen
//     EDGE (--edge=top|bottom|left|right, config [rail] edge): an
//     active-centred CAROUSEL of a capped subset ([rail] cells),
//     the rest rotating through with a both-ends peek
//
//   browse arrows ROTATE the strip (centre = the selection)
//   Return / click a cell → switch to centre + dismiss
//   click the backdrop / Esc → dismiss
//
// Strip/hero split scales off the short screen edge ([rail] strip)
// so it stays balanced in any orientation. Geometry is pure
// (`railBands` / `railCarouselOffsets`, FacetCore). Design memory:
// `facet-rail-carousel-decisions`.
//
// Controller-free, like `GridView`: orchestration plugs in through
// the callback closures. Each cell renders its workspace's windows
// as scaled ScreenCaptureKit mini-thumbnails — captures only, no
// app-icon fallback (unlike the grid); a not-yet-captured window
// shows just the subtle fill until its image lands.
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
    /// Upper bound on how many strip cells the viewport shows at once
    /// (2-b carousel, `[rail] cells`). The actual count auto-fits the
    /// strip's thumbnail size (`stripPercent`), capped here. The
    /// *selected* workspace is pinned to the strip centre and the rest
    /// fan out circularly, so extra workspaces rotate through (peeking
    /// at both ends) rather than scrolling.
    public var cellsTarget: Int = 7
    /// Maximum strip band size, as a percentage of the SHORT screen edge
    /// (`[rail] strip`) — caps the thumbnail scale; the hero fills the
    /// rest. Thumbnails grow to fill the run up to this cap (even, tight
    /// gaps); bigger = larger thumbnails. Short-edge-based so the split
    /// stays balanced in any orientation / on any display size.
    public var stripPercent: Int = 30

    /// The strip band rect (drawing-space) — cells are clipped to it so a
    /// carousel cell rotating past the viewport edge "peeks" (the
    /// both-ends "there's more" cue).
    private var stripRect: NSRect = .zero

    /// Shared neon border, drawn around the OUTER screen edge in `draw`
    /// when an effect is active (same BorderFX + screen frame as the
    /// grid; matches the tree panel's border).
    private let borderFX = BorderFX()

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
    /// Backend for the shared context menu (③). Set by the Controller.
    public var backend: (any WindowBackend)?
    /// Runs the non-close window-ops a context-menu pick chose (③).
    public var onRunWindowOps: ((_ ops: [WindowAction],
                                 _ window: Window, _ ws: Int) -> Void)?

    // MARK: - Captured thumbnails

    // internal so the drag-ghost extension (RailDrag.swift) can read it.
    var thumbnails: [WindowID: NSImage] = [:]

    // MARK: - Layout snapshot

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
        let wins: [MiniWindowHit]
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
    var pendingDown: (point: NSPoint, hit: MiniWindowHit, ws: Int)?
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

    // MARK: - Carousel slide animation (2-b v2)

    /// Current along-axis offset (points) added to the strip cells while
    /// a rotation eases in; 0 when settled. The clip viewport stays put,
    /// so cells slide under it (peeking at the ends).
    private var slideOffset: CGFloat = 0
    /// Offset the in-flight ease is decaying from (set on each rotate so
    /// rapid presses retarget from the current position).
    private var slideFrom: CGFloat = 0
    private var slideStart: Date?
    private var slideTimer: Timer?
    /// Last carousel slot size (set by `layoutCells`) — one rotation
    /// slides the strip by this much.
    private var lastSlot: CGFloat = 0
    /// Accumulated scroll-wheel delta; one carousel step per
    /// `railScrollStep` points so a wheel notch / swipe ≈ one rotation.
    private var scrollAccum: CGFloat = 0
    /// Ease value (0→1) of the active slide; also drives the hero
    /// crossfade (①): the old hero fades out over `1 − slideProgress`.
    private var slideProgress: CGFloat = 0
    /// Snapshot of the hero BEFORE a rotate, drawn over the new hero and
    /// faded out as the slide eases in (browse crossfade, ①).
    private var prevHeroImage: NSImage?
    private var prevHeroRect: NSRect = .zero

    // MARK: - Commit zoom animation (②: hero → full screen on switch)

    /// Plays the "hero zoom to full screen" transition on a switch
    /// commit; input is gated on `commitZoom.isActive` until it finishes
    /// (then the backend switch + close fire). Shared with the grid.
    private let commitZoom = CommitZoom(duration: railCommitZoomDuration)

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    /// Rebuild the carousel cells + hero. `force` rebuilds even while a
    /// drag freezes the layout — used by the keyboard-lift rotation,
    /// where the strip must spin under the (hidden) lifted ghost; a mouse
    /// drag never forces, so its cells stay put under the cursor.
    public func layoutCells(force: Bool = false) {
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
        if layoutSuppressed && !force { return }

        cells.removeAll(); hero = nil
        guard !workspaces.isEmpty, bounds.width > 1, bounds.height > 1 else {
            needsDisplay = true; return
        }
        let useScreen = screenFrame.width > 1 ? screenFrame : bounds
        let aspect = useScreen.width / max(1, useScreen.height)
        let horizontal = edge.axis == .horizontal

        // -- Strip / hero split (orientation- & display-size-aware).
        //    `stripPercent`% of the SHORT screen edge CAPS the strip band
        //    (and thus the thumbnail scale); the hero fills the rest.
        //    Short-edge-based, so the split stays balanced in any
        //    orientation / on any display size (never the old cross-axis
        //    fraction, which over-thickened the strip in portrait). --
        let shortEdge = min(useScreen.width, useScreen.height)
        let (edgeFloat, heroGap, outer) = railScaledPads(
            screen: useScreen.size,
            edgeFloatFrac: railEdgeFloatFrac,
            heroGapFrac: railHeroGapFrac,
            outerFrac: railOuterFrac)
        let n = workspaces.count
        let alongFull = horizontal ? bounds.width : bounds.height
        let availAlong = max(1, alongFull - outer * 2)
        // Show every workspace, up to the `[rail] cells` cap; the rest
        // rotate through the carousel.
        let visible = max(1, min(cellsTarget, max(1, n)))

        // Thumbnails are JUSTIFIED: they grow so `visible` cells fill the
        // run with a single `railCellGap` between them — the strip fills
        // the width/height with even, tight gaps instead of a few small
        // cells spread far apart. `stripPercent` caps the thumb scale
        // (`bandCap`); only when too few cells would push the thumb past
        // that cap does it stop growing (then the group centres with end
        // margins). The band then auto-fits the actual thumb.
        let bandCap = max(railCellMinDim, (shortEdge * CGFloat(stripPercent) / 100) - edgeFloat)
        let justRun = max(railCellMinDim,
                          (availAlong - CGFloat(visible + 1) * railCellGap) / CGFloat(visible))
        let thumbH: CGFloat, thumbW: CGFloat, headerH: CGFloat
        let blockCross: CGFloat, cellRun: CGFloat
        if horizontal {
            // Cell run-extent = thumb width; cap the height at the band.
            headerH = min(railHeaderMaxH,
                          max(railHeaderMinH, (bandCap * railHeaderRatio).rounded()))
            let maxThumbH = max(railCellMinDim, bandCap - headerH - railLabelGap)
            let th = min(justRun / aspect, maxThumbH)
            thumbH = th
            thumbW = th * aspect
            blockCross = headerH + railLabelGap + th
            cellRun = thumbW
        } else {
            // Cell run-extent = the header + thumb stack (height); cap the
            // thumb width at the band.
            headerH = min(railHeaderMaxH,
                          max(railHeaderMinH, (justRun * railHeaderRatio).rounded()))
            let availH = max(railCellMinDim, justRun - headerH - railLabelGap)
            let tw = min(availH * aspect, bandCap)
            thumbW = tw
            thumbH = tw / aspect
            blockCross = tw
            cellRun = headerH + railLabelGap + thumbH
        }
        let blockH = headerH + railLabelGap + thumbH

        // Band auto-fits the cell block + its float off the docked edge
        // (so ≤ `stripPercent`%); the hero fills the rest.
        let thickness = (edgeFloat + blockCross).rounded()

        // -- Carousel viewport (2-b): the SELECTED workspace pins to the
        //    strip centre; the rest fan out circularly and rotate through,
        //    peeking at both ends. Tight slot (one gap); the group is
        //    CENTRED — when the thumbs fill the run it ≈ spans the screen,
        //    otherwise it centres with end margins. --
        let peek: CGFloat = n > visible ? railPeek : 0
        let slot = max(railCellMinDim, cellRun + railCellGap)
        lastSlot = slot   // one rotation slides the strip by one slot (v2)
        let viewportAlong = min(availAlong, CGFloat(visible) * slot + 2 * peek)

        let (strip, heroArea) = railBands(in: bounds, edge: edge,
                                          thickness: thickness,
                                          outerPad: outer,
                                          heroGap: heroGap)
        // Clip region = the centred cell viewport (shown group + peek),
        // full thickness; a cell rotating past its run edges clips to the
        // peek.
        stripRect = horizontal
            ? NSRect(x: (strip.midX - viewportAlong / 2).rounded(), y: strip.minY,
                     width: viewportAlong, height: strip.height)
            : NSRect(x: strip.minX, y: (strip.midY - viewportAlong / 2).rounded(),
                     width: strip.width, height: viewportAlong)

        // Carousel placement: the selected workspace's cell sits at the
        // strip's along-centre; each cell's slot offset comes from the
        // pure `railCarouselOffsets` (selected = 0, the rest fan out
        // circularly). Cells past the viewport clip to the peek.
        let selectedPos = workspaces.firstIndex(where: { $0.index == selectedWS })
            ?? workspaces.firstIndex(where: { $0.isActive })
            ?? 0
        let offsets = railCarouselOffsets(count: n, selectedPos: selectedPos)
        let alongCentre = horizontal ? strip.midX : strip.midY
        // The header+gap+thumb block (thumbW × blockH) floats just off the
        // docked screen edge (by `edgeFloat`), so the strip sits near the
        // edge and the hero grows toward the centre. `blockCross` is the
        // block's cross-axis span (computed above with the thumb sizing);
        // place its outer (edge) corner and inner (hero-facing) edge.
        let blockOuter: CGFloat, innerEdge: CGFloat
        switch edge {
        case .bottom: blockOuter = strip.maxY - edgeFloat - blockCross; innerEdge = blockOuter
        case .top:    blockOuter = strip.minY + edgeFloat;              innerEdge = blockOuter + blockCross
        case .left:   blockOuter = strip.minX + edgeFloat;              innerEdge = blockOuter + blockCross
        case .right:  blockOuter = strip.maxX - edgeFloat - blockCross; innerEdge = blockOuter
        }
        // Place one strip cell at a signed carousel `offset` (0 = the
        // centred selected WS). Shared by the per-workspace cells and the
        // even-count wrap-peek ghost below.
        func placeCell(_ ws: Workspace, offset: Int) {
            let slotStart = alongCentre + CGFloat(offset) * slot - slot / 2
            let blockX: CGFloat, blockY: CGFloat
            if horizontal {
                blockX = slotStart + (slot - thumbW) / 2
                blockY = blockOuter
            } else {
                blockX = blockOuter
                blockY = slotStart + (slot - blockH) / 2
            }
            // Header band always sits above the thumb (every edge), so a
            // top rail's name / layout label reads at the cell's top too.
            let headerY = blockY
            let thumbY  = blockY + headerH + railLabelGap
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
        for (i, ws) in workspaces.enumerated() { placeCell(ws, offset: offsets[i]) }
        // Both-ends peek symmetry (⑥): for an EVEN workspace count the
        // carousel offsets span [-n/2, +(n/2−1)] — one more cell on the
        // negative side — so when every workspace is shown the strip's
        // left end peeks but the right has a bare slot. The carousel
        // wraps, so the far-left workspace (offset −n/2) is also the
        // wrap-around at +n/2; draw it there too as a peek ghost so the
        // ends mirror (the active stays centred). Only when all fit
        // (n == visible) — with overflow the natural ±cells already peek
        // symmetrically and a +n/2 ghost would be off-viewport anyway.
        if n % 2 == 0, n > 1, n == visible,
           let li = offsets.firstIndex(of: -(n / 2)) {
            placeCell(workspaces[li], offset: n / 2)
        }

        // -- Hero: the SELECTED workspace (browse) — aspect-fit, biased
        //    toward the SCREEN centre. The strip hugs the edge, so pull
        //    the hero's strip-side boundary in to the cells' inner edge
        //    (reclaiming the band slack), then centre the hero on the
        //    screen, clamped so it never overlaps the strip. --
        var heroBox = heroArea
        switch edge {
        case .bottom:
            heroBox.size.height = max(0, (innerEdge - heroGap) - heroBox.minY)
        case .top:
            let top = innerEdge + heroGap
            heroBox = CGRect(x: heroBox.minX, y: top,
                             width: heroBox.width, height: max(0, heroBox.maxY - top))
        case .left:
            let left = innerEdge + heroGap
            heroBox = CGRect(x: left, y: heroBox.minY,
                             width: max(0, heroBox.maxX - left), height: heroBox.height)
        case .right:
            heroBox.size.width = max(0, (innerEdge - heroGap) - heroBox.minX)
        }
        if heroBox.width > 1, heroBox.height > 1,
           let act = workspaces.first(where: { $0.index == selectedWS })
            ?? workspaces.first(where: { $0.isActive })
            ?? workspaces.first {
            var hCellW = heroBox.width
            var hCellH = heroBox.height
            if hCellW / hCellH > aspect { hCellW = hCellH * aspect }
            else { hCellH = hCellW / aspect }
            // Centre on the screen, clamped into the (strip-free) box.
            let hx = min(max(bounds.midX - hCellW / 2, heroBox.minX),
                         heroBox.maxX - hCellW).rounded()
            let hy = min(max(bounds.midY - hCellH / 2, heroBox.minY),
                         heroBox.maxY - hCellH).rounded()
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
                            _ screen: CGRect) -> [MiniWindowHit] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        let sx = cell.width / screen.width
        let sy = cell.height / screen.height
        var out: [MiniWindowHit] = []
        for win in ws.windows {
            guard let f = win.frame else { continue }
            let r = NSRect(x: cell.minX + (f.minX - screen.minX) * sx,
                           y: cell.minY + (f.minY - screen.minY) * sy,
                           width: f.width * sx, height: f.height * sy)
            guard r.width >= 2, r.height >= 2 else { continue }
            out.append(MiniWindowHit(pid: win.pid, id: win.id,
                              isFocused: win.isFocused, rect: r,
                              mark: win.mark,
                              tags: Array(win.tags.dropFirst())))
        }
        return out
    }

    private func stripCellAt(_ p: NSPoint) -> Cell? {
        // Only cells whose visible (clipped-to-strip) area is under the
        // pointer count — a cell rotated past the viewport edge never
        // matches even though it still exists in `cells` (every workspace
        // is kept, for peek + hit order).
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

        // Commit zoom (②): the captured hero scales from its rect to fill
        // the screen (ease-out); then the switch + close fire. Nothing
        // else is drawn during it.
        if commitZoom.draw(in: bounds) { return }

        if let h = hero { drawCell(h) }
        // Hero crossfade (①): the previous hero fades out over the new one
        // as the rotation eases in (`slideProgress` 0→1).
        if let prev = prevHeroImage, slideProgress < 1 {
            prev.draw(in: prevHeroRect, from: .zero,
                      operation: .sourceOver, fraction: max(0, 1 - slideProgress))
        }
        // Strip cells are clipped to the carousel viewport so a cell
        // rotating past the end "peeks" half-off the edge (the both-ends
        // "there's more" cue) instead of drawing over the hero. A drag
        // ghost is a separate subview, unaffected by this clip. While a
        // rotation eases in (`slideOffset`), the cells are translated
        // along the run UNDER the fixed viewport, so the strip slides
        // (the hero, drawn above, already shows the new centre). (2-b v2)
        NSGraphicsContext.saveGraphicsState()
        if !stripRect.isEmpty { NSBezierPath(rect: stripRect).addClip() }
        if slideOffset != 0 {
            let horizontal = edge.axis == .horizontal
            let t = NSAffineTransform()
            t.translateX(by: horizontal ? slideOffset : 0,
                         yBy: horizontal ? 0 : slideOffset)
            t.concat()
        }
        for c in cells { drawCell(c) }
        NSGraphicsContext.restoreGraphicsState()

        // Neon border framing the OUTER screen edge (shared BorderFX),
        // drawn unclipped over everything — same as the grid overview.
        // Only when an effect is active.
        if borderFX.active { drawOuterBorder() }
    }

    // MARK: - Border (shared BorderFX — frames the outer screen edge)

    /// Apply the `[border]` config (Controller, on show / reload). The
    /// rail frames the outer screen edge only while an effect is active.
    public func applyBorder(effectName: String, glow: Bool, width: CGFloat,
                            cycleSeconds: CGFloat, cycleColors: Bool,
                            minWidth: CGFloat?, maxWidth: CGFloat?) {
        borderFX.onRepaint = { [weak self] in self?.needsDisplay = true }
        borderFX.configure(effectName: effectName, glow: glow, width: width,
                           cycleSeconds: cycleSeconds, cycleColors: cycleColors,
                           minWidth: minWidth, maxWidth: maxWidth)
    }
    /// WS-switch / show flash (no-op when off).
    public func flashBorder() { borderFX.flash() }
    /// Stop the border timer when the overlay closes.
    public func stopBorder() { borderFX.stop() }

    /// Stroke the outer screen-edge frame in the current BorderFX color
    /// / width — square corners, matching the grid overview. Glow is
    /// faked with a wide, faint halo under the crisp stroke (a CALayer
    /// shadow isn't available in `draw`).
    private func drawOuterBorder() {
        let w = borderFX.width
        let c = borderFX.color
        let r = bounds.insetBy(dx: w / 2, dy: w / 2)
        if borderFX.glowEnabled {
            c.withAlphaComponent(0.35).setStroke()
            let halo = NSBezierPath(rect: r)
            halo.lineWidth = w * 3
            halo.stroke()
        }
        c.setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = w
        path.stroke()
    }

    // MARK: - Carousel slide animation (2-b v2)

    /// Start (or retarget) the rotation slide. `dx` is the carousel step
    /// (+1 next / −1 previous); the strip slides one `slot` per step. On a
    /// rapid press the offset accumulates from its current value so the
    /// motion follows the latest target without a jump. Honours Reduce
    /// Motion (instant).
    private func startSlide(step dx: Int, slot: CGFloat) {
        guard dx != 0, slot > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { slideOffset = 0; stopSlide(); needsDisplay = true; return }
        let cap = slot * railSlideMaxSlots
        slideOffset = max(-cap, min(cap, slideOffset + CGFloat(dx) * slot))
        slideFrom = slideOffset
        slideProgress = 0
        slideStart = Date()
        if slideTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickSlide() }
            }
            RunLoop.main.add(timer, forMode: .common)   // fire during key-mash too
            slideTimer = timer
        }
        needsDisplay = true
    }

    private func tickSlide() {
        guard let start = slideStart else { stopSlide(); return }
        let t = Date().timeIntervalSince(start) / railSlideDuration
        if t >= 1 {
            slideOffset = 0; slideProgress = 1
            stopSlide()
        } else {
            let e = 1 - pow(1 - CGFloat(t), 3)   // ease-out cubic
            slideOffset = slideFrom * (1 - e)
            slideProgress = e
        }
        needsDisplay = true
    }

    private func stopSlide() {
        slideTimer?.invalidate(); slideTimer = nil; slideStart = nil
        slideProgress = 0
        prevHeroImage = nil          // crossfade done (①)
    }

    /// Funnel for a switch-and-close commit. If the destination is the
    /// centred hero, play the "hero zoom → full screen" transition (②)
    /// then run `perform` (the actual switch + close); otherwise run it
    /// immediately. Honours Reduce Motion.
    private func commitSwitch(target ws: Int, perform: @escaping () -> Void) {
        guard !commitZoom.isActive else { return }   // a zoom is already in flight
        guard ws == selectedWS, let h = hero,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let img = snapshotRegion(h.rect)
        else { perform(); return }
        commitZoom.begin(image: img, from: h.rect,
                         redraw: { [weak self] in self?.needsDisplay = true },
                         perform: perform)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {                  // overlay closed
            slideOffset = 0; stopSlide()
            if commitZoom.isActive { commitZoom.finish() }   // don't drop the switch
        }
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
            // Always prominent: PRIMARY accent when the hero is the live
            // active WS, SECONDARY accent when browsing a different WS
            // (matches the browse-target strip cell — 2-b carousel).
            (c.isActive ? pal.accent : pal.accent2).setStroke()
            path.lineWidth = 2.5
        } else if c.isActive {
            pal.accent.setStroke(); path.lineWidth = 2          // PRIMARY = active WS
        } else if drag == nil && selectedWS == c.wsIndex {
            // Browse target (≠ active) — SECONDARY accent border so it
            // reads apart from the primary-accent active WS (2-b carousel).
            pal.accent2.setStroke(); path.lineWidth = 2
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

    private func drawThumb(_ w: MiniWindowHit, fill: NSColor, stroke: NSColor) {
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
        drawMiniTagDots(w.tags.count, in: w.rect)
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

    private func heroWinAt(_ p: NSPoint) -> MiniWindowHit? {
        hero?.wins.reversed().first { $0.rect.contains(p) }
    }

    /// Mouse-wheel / two-finger scroll rotates the carousel: scroll DOWN
    /// → next workspace, UP → previous (same on every edge — the gesture
    /// isn't tied to the strip's axis). Mirrors the browse arrows
    /// (`kbMoveSelection`), so the eased rotation + hero re-preview are
    /// shared. A keyboard lift owns the carousel, so scrolling is inert
    /// while lifted. Driven by the Controller's `.scrollWheel` local
    /// monitor (NOT an NSView override) — the rail is a nonactivating
    /// panel, so, like the browse keys, scroll events are caught at the
    /// app's event monitor rather than the view responder chain.
    public func scrollRotate(_ event: NSEvent) {
        guard drag == nil, workspaces.count > 1,
              event.momentumPhase == [] else { return }
        var dy = event.scrollingDeltaY
        if dy == 0 { return }
        // The natural-scroll preference already lives in the sign, so
        // honour it as-is (no inversion) — down → next.
        if event.hasPreciseScrollingDeltas {
            // Trackpad / Magic Mouse: accumulate points, one step per
            // `railScrollStep`; reset at each gesture start.
            if event.phase.contains(.began) { scrollAccum = 0 }
            scrollAccum += dy
            while abs(scrollAccum) >= railScrollStep {
                let dx = scrollAccum < 0 ? 1 : -1   // down → next, up → prev
                scrollAccum += CGFloat(dx) * railScrollStep
                kbMoveSelection(dx: dx)
            }
        } else {
            // Classic notched wheel: one detent → one step.
            kbMoveSelection(dx: dy < 0 ? 1 : -1)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        // A keyboard lift owns the drag; ignore mouse presses until it
        // commits (Return) or cancels (Esc) so a stray click can't
        // commit it at the keyboard-aimed target. A commit zoom (②) also
        // swallows input until it finishes.
        guard !commitZoom.isActive, drag == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Strip hit-tests are gated by the same viewport clip as hover
        // (`stripRect`), so a press in the clipped outer-pad margin — bare
        // backdrop to the eye — never acts on a rotated-off cell.
        let inStrip = stripRect.isEmpty || stripRect.contains(p)
        // Header press → workspace drag (swap) or click (switch).
        if inStrip, let cell = cells.first(where: { $0.headerRect.contains(p) }) {
            pendingHeaderDown = (p, cell.wsIndex); return
        }
        // Window-thumb press → window drag (move) or click (switch).
        // The big hero windows are the primary, ergonomic drag source;
        // the tiny bottom-cell windows are a secondary source.
        if let w = heroWinAt(p), let h = hero {
            pendingDown = (p, w, h.wsIndex); return
        }
        if inStrip, let cell = cells.first(where: { $0.rect.contains(p) }) {
            if let w = cell.wins.reversed().first(where: { $0.rect.contains(p) }) {
                pendingDown = (p, w, cell.wsIndex)
            } else {
                // empty cell area → switch+close (zoom if it's the centre)
                commitSwitch(target: cell.wsIndex) { [weak self] in
                    self?.onPick?(cell.wsIndex)
                }
            }
            return
        }
        // The hero is the focal preview, not a target — clicking its
        // empty area does nothing. Only the true backdrop dismisses.
        if let h = hero, h.rect.contains(p) { return }
        onDismiss?()
    }

    // Right-click: WS header → layout picker; window thumb (hero or
    // strip) → window-ops menu (③ — the SAME shared menu the tree shows).
    public override func rightMouseDown(with event: NSEvent) {
        guard let backend, let win = window, drag == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let scr = win.convertPoint(toScreen: event.locationInWindow)
        let inStrip = stripRect.isEmpty || stripRect.contains(p)
        if inStrip, let cell = cells.first(where: { $0.headerRect.contains(p) }) {
            ViewContextMenu.showLayout(at: scr, backend: backend,
                                       workspaceIndex: cell.wsIndex,
                                       workspaces: workspaces)
            return
        }
        if let w = heroWinAt(p), let h = hero {
            railWinMenu(scr, backend: backend, ws: h.wsIndex, w: w); return
        }
        if inStrip, let cell = cells.first(where: { $0.rect.contains(p) }),
           let w = cell.wins.reversed().first(where: { $0.rect.contains(p) }) {
            railWinMenu(scr, backend: backend, ws: cell.wsIndex, w: w)
        }
    }

    /// Keyboard 'm' (③): context menu for the centred WS — the header
    /// (layout picker) when no hero window is cursored, else that window.
    public func kbContextMenu() {
        guard let backend, let win = window, let ws = selectedWS else { return }
        if kbSelectedWindowIdx == -1 {
            guard let cell = cells.first(where: { $0.wsIndex == ws }) else { return }
            let scr = win.convertPoint(toScreen:
                convert(NSPoint(x: cell.headerRect.minX + 12, y: cell.headerRect.minY), to: nil))
            ViewContextMenu.showLayout(at: scr, backend: backend,
                                       workspaceIndex: ws, workspaces: workspaces)
        } else if let h = hero, kbSelectedWindowIdx >= 0,
                  kbSelectedWindowIdx < h.wins.count {
            let w = h.wins[kbSelectedWindowIdx]
            let scr = win.convertPoint(toScreen:
                convert(NSPoint(x: w.rect.minX + 12, y: w.rect.minY), to: nil))
            railWinMenu(scr, backend: backend, ws: ws, w: w)
        }
    }

    private func railWinMenu(_ scr: NSPoint, backend: any WindowBackend,
                             ws: Int, w: MiniWindowHit) {
        ViewContextMenu.showWindow(
            at: scr, backend: backend, workspaceIndex: ws,
            workspaces: workspaces, pid: w.pid, windowID: w.id, title: ""
        ) { [weak self] ops, win, ws in self?.onRunWindowOps?(ops, win, ws) }
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
        // Drop targets are strip cells only (not the hero — it's the
        // active WS, already its own strip cell), and only within the
        // viewport clip (a rotated-off cell in the margin isn't a target).
        // A cell == source is not a target (no self-move).
        let over = stripCellAt(p)?.wsIndex
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
            // No drag crossed threshold → resolve as a click (zoom if the
            // target is the centred hero, else switch immediately).
            if let pd = pendingDown {
                // Window thumb → switch to its WS AND focus THAT window.
                commitSwitch(target: pd.ws) { [weak self] in
                    self?.onPickWindow?(pd.ws, pd.hit.pid, pd.hit.id)
                }
            } else if let ph = pendingHeaderDown {
                commitSwitch(target: ph.ws) { [weak self] in
                    self?.onPick?(ph.ws)       // header → switch WS only
                }
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


    /// The keyboard-selected window: the kbSelectedWindowIdx-th window
    /// (in reading order) of the SELECTED WS, taken from the HERO (it
    /// shows the full window list large). The ring is drawn in BOTH
    /// tiers — the hero and the matching bottom cell — by window id.
    private func kbSelectedWindow() -> MiniWindowHit? {
        guard kbSelectedWindowIdx >= 0, let h = hero, !h.wins.isEmpty
        else { return nil }
        let ordered = readingOrder(h.wins)
        return ordered[max(0, min(ordered.count - 1, kbSelectedWindowIdx))]
    }

    /// Browse-axis arrow (2-b carousel): ROTATE the strip one workspace
    /// so the next/previous one comes to the centre — the new centre is
    /// the browse target (hero previews it). Lifted → the centred cell is
    /// the drop target instead. `dx` is +1 / −1 along the strip (next /
    /// previous, supplied by the Controller for the edge's axis); it
    /// wraps circularly.
    public func kbMoveSelection(dx: Int) {
        guard !commitZoom.isActive, !workspaces.isEmpty else { return }
        let cur = workspaces.firstIndex { $0.index == selectedWS } ?? 0
        let ni = (cur + dx + workspaces.count) % workspaces.count   // wrap
        guard workspaces[ni].index != selectedWS else { return }
        // Browse crossfade (①): snapshot the current hero before it
        // changes, to fade it out over the new one as the slide eases in.
        if drag == nil, let h = hero {
            prevHeroImage = snapshotRegion(h.rect); prevHeroRect = h.rect
        }
        selectedWS = workspaces[ni].index
        if drag != nil {
            // Lifted: rotate the carousel under the ghost so the aimed
            // workspace comes to centre = the drop target. Force past the
            // drag freeze — the lifted window is hidden, so re-laying is
            // safe (the freeze only guards a mouse drag's cell positions).
            layoutCells(force: true)
            syncRailDragToSelection()      // lifted → arrows AIM the destination
        } else {
            kbSelectedWindowIdx = -1       // browse → reset window cursor for the new WS
            layoutCells()                  // rotate the strip (+ hero re-preview)
            startSlide(step: dx, slot: lastSlot)   // ease the rotation (v2)
        }
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
    /// Space is a TOGGLE (matches tree): carrying → drop (= Return),
    /// otherwise lift whatever is selected.
    public func kbSpaceLift() {
        if drag != nil { kbCommit(); return }   // carrying → Space drops
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
        if commitZoom.isActive { return }   // a switch zoom (②) is already in flight
        // A commit is already waiting for the backend ack (the rail stays
        // open through it) — swallow a second Return so it can't fire a
        // duplicate move/swap before the landing gate clears `drag`.
        if lastDrop != nil || lastSwap != nil { return }
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
        // The selected WS is the centre, so this always plays the zoom (②).
        if let hit = kbSelectedWindow() {
            commitSwitch(target: ws) { [weak self] in
                self?.onPickWindow?(ws, hit.pid, hit.id)   // window → switch + focus it
            }
        } else {
            commitSwitch(target: ws) { [weak self] in
                self?.onPick?(ws)                          // whole-WS → switch + close
            }
        }
    }

    /// Escape, in order: cancel an in-flight lift → clear a Tab window
    /// selection (stay open) → dismiss the rail.
    public func kbEscape() {
        if commitZoom.isActive { return }   // mid switch zoom (②) — let it finish
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
