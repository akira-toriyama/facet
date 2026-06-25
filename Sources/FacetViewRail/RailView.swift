// Full-screen workspace rail — a Mission-Control-style switcher.
//
//   • a solid black BACKDROP hides the desktop behind it
//   • a HERO cell shows the active (centred) workspace large
//   • a STRIP of workspace thumbnails docked against one screen
//     EDGE (--edge top|bottom|left|right, config [rail] edge): an
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

    /// Per-surface palette (PR-B). The Controller wires the rail box at
    /// build time; `pal` reads (here and in the RailHeader / RailDrag
    /// extensions) route through it — the rail's own `[rail].theme` — and
    /// the box is shared with the rail's `BorderFX`.
    public var paletteBox: PaletteBox! {
        didSet { borderFX.paletteBox = paletteBox }
    }
    var pal: ResolvedPalette { paletteBox.pal }

    // MARK: - Inputs (Controller-supplied)

    public var workspaces: [Workspace] = []
    public var activeIndex: Int?
    /// EX-2: the projected section list. The rail does not yet consume it
    /// (rail section rendering is EX-2b); stored to satisfy the `OverviewView`
    /// protocol so the Controller feed is symmetric with the grid.
    public var sections: [ProjectedSection] = []
    /// EX-2b / §A: the active lens's stable section id (`ProjectedSection.id`).
    /// Keyed on the id, not the label, so a non-unique / empty lens label can't
    /// light the wrong cell.
    public var activeLensID: String?
    /// Keyboard "browse" cursor — the SECTION the centre HERO previews
    /// (←/→ rotate it, Return commits). Keyed on the stable
    /// `ProjectedSection.id` (`"ws:<i>"` / `"section:<order>:<label>"`),
    /// NOT a workspace index — lens cells all share `wsIndex == −1`, which
    /// would collide (EX-2b, the rail analog of the grid's `kbSelectedID`).
    /// Decoupled from the active section so browsing doesn't activate until
    /// commit. Seeded by the first `layoutCells` (the stranded-cursor
    /// repair) + re-centred by the Controller on an external activate.
    public var selectedSectionID: String?
    /// EX-2b: window → home workspace index (0-based), rebuilt every
    /// `layoutCells` from the UNFILTERED `workspaces` snapshot. A window
    /// thumb may sit in a LENS cell (`wsIndex == −1`) but still has a real
    /// home WS; window picks resolve through this, never the cell's wsIndex.
    private var windowHomeWS: [WindowID: Int] = [:]
    /// EX-2b: the ordered section ids the carousel cycles (sources order, no
    /// peek-ghost duplicate), refreshed every `layoutCells`. Browse nav
    /// cycles THIS, not `cells` (which appends a wrap-peek ghost).
    private var sectionOrder: [String] = []
    /// The display frame windows were measured against (backend CG
    /// coords). Mini-thumb rects scale from this; `.zero` falls back
    /// to the view bounds.
    public var screenFrame: CGRect = .zero
    /// Which edge the strip docks against (M9-3). Set by the Controller
    /// from the CLI `--edge` / `[rail] edge` config; drives the strip
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

    /// Pick a section cell (workspace / lens), a window thumb, or commit a
    /// keyboard browse → the Controller routes through `activateSection`
    /// (EX-2b, mirrors the grid's `onPick(GridPick)`; replaces the old
    /// `onPick(Int)` + `onPickWindow` pair). The Controller owns the backend
    /// round-trip + whether the overlay then dismisses.
    public var onPick: ((RailPick) -> Void)?
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
    /// Section drag-to-reorder commit (display-only, session-only): move the
    /// section `sectionID` to insertion BOUNDARY `boundary` in `sectionOrder`
    /// coords (= the projected section order). No window moves, no config write.
    /// Mirrors the tree / grid `onReorder`; replaces the mouse header-SWAP.
    public var onReorder: ((_ sectionID: String, _ toBoundary: Int) -> Void)?
    /// Backend for the shared context menu (③). Set by the Controller.
    public var backend: (any WindowBackend)?
    /// Runs the non-close window-ops a context-menu pick chose (③).
    public var onRunWindowOps: ((_ ops: [WindowAction],
                                 _ window: Window, _ ws: Int) -> Void)?

    // MARK: - Captured thumbnails

    // internal so the drag-ghost extension (RailDrag.swift) can read it.
    var thumbnails: [WindowID: NSImage] = [:]

    // MARK: - Layout snapshot

    // Cells are the shared `OverviewCell` (FacetCore): one workspace
    // mini-screen each, recomputed on every relayout so paint and
    // hit-testing can't drift. `isHero` marks the centre hero (the rail's
    // large active-WS cell); the bottom-row cells pass `false`.
    private(set) var cells: [OverviewCell] = []     // bottom row (all workspaces)
    private(set) var hero: OverviewCell?            // centre (active workspace)

    private var hoverID: String? {
        didSet { if hoverID != oldValue { needsDisplay = true } }
    }
    /// Bottom cell whose HEADER the pointer is over — brightens the
    /// band + grip (the grab affordance for a WS swap, Phase R3). Keyed on
    /// `sectionID` (EX-2b) so a lens cell's `wsIndex == −1` can't light
    /// every lens header at once.
    var hoverHeaderID: String?
    private var trackingArea: NSTrackingArea?

    // MARK: - Drag state (window move + WS swap)

    // `OverviewDrag` / `OverviewDragKind` (FacetCore) carry the active
    // gesture: `.window` moves one window, `.workspace` swaps a whole
    // cell's contents. Decided at promotion by which target was grabbed
    // (window thumb vs header). NOT cleared on mouseUp — the landing gate
    // / cancel path clears it once the backend acks, so the source thumb
    // stays hidden through the round-trip (memory grid-drag-state-lifecycle).

    // mouseDown candidates (resolved to a drag past threshold, else a
    // click on mouseUp).
    var pendingDown: (point: NSPoint, hit: MiniWindowHit, cellID: String)?
    var pendingHeaderDown: (point: NSPoint, cellID: String)?
    var drag: OverviewDrag?
    var dragGhost: NSView?
    // Mouse section-reorder (the `.workspace`-kind drag is a display-only
    // reorder, NOT the keyboard's content swap): the dragged section id, the
    // live `sectionOrder` insertion boundary, the gate that tells draw/commit
    // "reorder, not swap", and the precomputed insertion-line endpoints (the
    // carousel subset makes a boundary→cell lookup awkward, so the line is
    // computed at hit-test time). Keyboard header-lift leaves `reorderDrag` false.
    var dragSectionID: String?
    var reorderInsertAt: Int?
    var reorderDrag = false
    var reorderLine: (a: NSPoint, b: NSPoint)?
    /// Freeze `layoutCells` mid-gesture so the source cell can't shift
    /// under the cursor; released by the landing gate.
    var layoutSuppressed = false
    var lastDrop: OverviewPendingDrop?
    var lastSwap: OverviewPendingSwap?

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
    private let commitZoom = CommitZoom(duration: overviewCommitZoomDuration)

    public override var isFlipped: Bool { true }
    // No `isOpaque` override (unlike GridView): although the rail paints
    // its own opaque backdrop in `draw`, it stays at the NSView default
    // (non-opaque) to sit cleanly under the clear, non-opaque
    // `OverviewPanel` — same host-paints-backdrop arrangement as the grid.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Layout

    /// EX-2b: one carousel cell source per projected section (workspace +
    /// lens), built with the single-highlight already gated. `wsIndex` is the
    /// 0-based source WS (−1 for a lens, which spans workspaces). A rail-local
    /// twin of the grid's `CellSource` (that one is `private` to FacetViewGrid).
    private struct CellSource {
        let wsIndex: Int
        let sectionType: SectionType
        let sectionID: String
        let label: String           // §D composed caption: `index (label)`
        let mode: String            // layout engine; "" for a lens
        let windows: [Window]
        let isActive: Bool          // single-highlight XOR, baked at build time
    }

    /// EX-2b: build the carousel cell sources. Degrade (no section model here)
    /// → one cell per workspace, byte-identical to pre-EX-2b. Section model →
    /// one cell per projected section (workspace + lens), in config order, with
    /// the single-highlight XOR baked into `isActive` (mirror of the grid's
    /// `overviewCellSources` / `SidebarView.headerActive`).
    private func overviewCellSources() -> [CellSource] {
        if sections.isEmpty {
            return workspaces.enumerated().map { (i, ws) in
                // §D: caption = `index (label)`. Index = 1-based DISPLAY position
                // (`workspaces` is `displayWss` — reorder-applied), NOT `ws.index`
                // (a session reorder makes them differ; `--focus index:N`
                // addresses by this display position).
                CellSource(wsIndex: ws.index, sectionType: .workspace,
                           sectionID: "ws:\(ws.index)",
                           label: sectionDisplayLabel(index: i + 1,
                                                      label: ws.name),
                           mode: ws.layoutMode, windows: ws.windows,
                           isActive: activeLensID == nil && ws.isActive)
            }
        }
        return sections.enumerated().map { (i, sec) in
            let isLens = sec.sectionType == .lens
            // The projection doesn't carry a workspace's live layoutMode; look
            // it up by source index (a lens has no layout engine → "").
            let srcWS = sec.sourceWorkspaceIndex.flatMap { src in
                workspaces.first { $0.index == src } }
            let mode = isLens ? "" : (srcWS?.layoutMode ?? "")
            // EX-2b single-highlight: lens cell lit ⟺ it IS the active lens;
            // workspace cell lit ⟺ no lens active AND its WS is active.
            let active = isLens
                ? (activeLensID != nil && sec.id == activeLensID)
                : (activeLensID == nil && srcWS?.isActive == true)
            // §D: every section type captions as `index (label)` — the
            // 1-based display index is the section's position in tree order
            // (this `.enumerated()` `i`), NOT `sourceWorkspaceIndex`.
            return CellSource(wsIndex: sec.sourceWorkspaceIndex ?? -1,
                              sectionType: sec.sectionType, sectionID: sec.id,
                              label: sectionDisplayLabel(index: i + 1,
                                                         label: sec.label),
                              mode: mode,
                              windows: sec.windows, isActive: active)
        }
    }

    /// `OverviewView` no-arg layout — the common (non-forced) rebuild.
    /// A distinct method (not a defaulted parameter) so it can witness
    /// the protocol requirement; the forced path keeps `layoutCells(force:)`.
    public func layoutCells() { layoutCells(force: false) }

    /// Rebuild the carousel cells + hero. `force` rebuilds even while a
    /// drag freezes the layout — used by the keyboard-lift rotation,
    /// where the strip must spin under the (hidden) lifted ghost; a mouse
    /// drag never forces, so its cells stay put under the cursor.
    public func layoutCells(force: Bool) {
        // Drag landing gate (runs before suppression so a landed
        // move/swap releases it + rebuilds). While a drop is in flight
        // we keep the old cells so the source thumb doesn't shift under
        // the cursor; clear `drag` only when the backend confirms the
        // move (memory grid-drag-state-lifecycle), or after a timeout.
        if let ld = lastDrop {
            let landed = ld.landed(in: workspaces)
            if landed || Date().timeIntervalSince(ld.committedAt) > overviewDropAckTimeout {
                clearDrag()
            } else { return }
        }
        if let ls = lastSwap {
            let landed = ls.landed(in: workspaces)
            if landed || Date().timeIntervalSince(ls.committedAt) > overviewDropAckTimeout {
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

        // EX-2b: build the section cell sources (degrade → one per workspace)
        // + the window→home-WS map + the carousel section order from the
        // current snapshot, before any geometry uses `n`. `sources` is
        // non-empty here (guarded by `!workspaces.isEmpty`), so the carousel
        // / hero resolution below always has a cell.
        let sources = overviewCellSources()
        sectionOrder = sources.map(\.sectionID)
        windowHomeWS = [:]
        for ws in workspaces { for w in ws.windows { windowHomeWS[w.id] = ws.index } }

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
        let n = sources.count
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
        let selectedPos = sources.firstIndex(where: { $0.sectionID == selectedSectionID })
            ?? sources.firstIndex(where: { $0.isActive })
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
        func placeCell(_ src: CellSource, offset: Int) {
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
            cells.append(OverviewCell(wsIndex: src.wsIndex, rect: cellRect,
                              headerRect: headerRect, isActive: src.isActive,
                              label: src.label, mode: src.mode,
                              windows: scaledWins(src.windows, cellRect, useScreen),
                              isHero: false,
                              sectionType: src.sectionType, sectionID: src.sectionID))
        }
        for (i, src) in sources.enumerated() { placeCell(src, offset: offsets[i]) }
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
            placeCell(sources[li], offset: n / 2)   // wrap-peek ghost (same source)
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
        // The hero = the centred section. When it's a lens (Decision 1,
        // トミー 2026-06-22) it renders the lens's cross-workspace union
        // (`act.windows`); a workspace renders its own windows. `isActive` is
        // the baked single-highlight XOR. `sources` is non-empty (guarded
        // above), so the fallback chain never falls through.
        if heroBox.width > 1, heroBox.height > 1,
           let act = sources.first(where: { $0.sectionID == selectedSectionID })
            ?? sources.first(where: { $0.isActive })
            ?? sources.first {
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
            hero = OverviewCell(wsIndex: act.wsIndex, rect: hCellRect,
                        headerRect: .zero, isActive: act.isActive,
                        label: act.label, mode: act.mode,
                        windows: scaledWins(act.windows, hCellRect, useScreen),
                        isHero: true,
                        sectionType: act.sectionType, sectionID: act.sectionID)
        }

        // Repair a stranded browse cursor: if the selected WS was
        // removed mid-browse (auto-removed / mac-desktop catalog swap),
        // snap it to the hero so the ←/→ cursor and the previewed hero
        // stay in sync and the next arrow continues from what's shown.
        // (Also SEEDS the cursor on first layout: `selectedSectionID` starts
        // nil, no cell matches, so it snaps to the hero — the active section.)
        if !cells.contains(where: { $0.sectionID == selectedSectionID }) {
            selectedSectionID = hero?.sectionID ?? cells.first?.sectionID
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
    /// cell. The rect math is the shared `scaledWindowRect`
    /// (FacetCore) — rail keeps only the `>= 2` px cull and its own
    /// `MiniWindowHit` construction.
    private func scaledWins(_ windows: [Window], _ cell: NSRect,
                            _ screen: CGRect) -> [MiniWindowHit] {
        var out: [MiniWindowHit] = []
        for win in windows
        where !win.isLensParked {   // drop out-of-lens parked windows
            guard let f = win.frame else { continue }
            let r = scaledWindowRect(windowFrame: f,
                                     screenFrame: screen,
                                     cellRect: cell)
            guard r.width >= 2, r.height >= 2 else { continue }
            out.append(MiniWindowHit(pid: win.pid, id: win.id,
                              isFocused: win.isFocused, rect: r,
                              mark: win.mark))
        }
        return out
    }

    private func stripCellAt(_ p: NSPoint) -> OverviewCell? {
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
        // Section reorder: the insertion LINE with end caps at the drop
        // boundary (mirrors tree/grid). Drawn inside the strip clip so it sits
        // with the cells.
        if reorderDrag, let l = reorderLine {
            pal.primary.setStroke(); pal.primary.setFill()
            let line = NSBezierPath()
            line.move(to: l.a); line.line(to: l.b)
            line.lineWidth = 3; line.stroke()
            for pt in [l.a, l.b] {
                NSBezierPath(ovalIn: NSRect(x: pt.x - 3, y: pt.y - 3,
                                            width: 6, height: 6)).fill()
            }
        }
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
    private func commitSwitch(targetSectionID: String, perform: @escaping () -> Void) {
        guard !commitZoom.isActive else { return }   // a zoom is already in flight
        // Play the hero-zoom transition iff the picked section IS the centred
        // hero — works for a workspace switch AND a lens-union activation (EX-2b).
        guard targetSectionID == selectedSectionID, let h = hero,
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

    private func drawCell(_ c: OverviewCell) {
        let path = NSBezierPath(roundedRect: c.rect,
                               xRadius: railCellRadius, yRadius: railCellRadius)
        // Mini-screen background.
        (pal.background ?? NSColor.windowBackgroundColor)
            .withAlphaComponent(0.55).setFill()
        path.fill()

        // Window mini-thumbnails, clipped to the cell. The window being
        // dragged is hidden everywhere (its ghost stands in) so it looks
        // lifted off both the hero and its bottom cell.
        let dragSrcID: WindowID? = (drag?.kind == .window) ? drag?.id : nil
        let winFill = pal.foreground.withAlphaComponent(0.16)
        let winFocused = pal.primary.withAlphaComponent(0.30)
        let winStroke = pal.foreground.withAlphaComponent(0.40)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        for w in c.windows where w.id != dragSrcID {
            // Capture-only (iconFallback: false) — the Controller's
            // thumbnail timer keeps the cache warm, so an open paints
            // real thumbnails; a not-yet-captured window shows just the
            // subtle fill until its image lands.
            drawMiniThumb(w, at: w.rect,
                          fill: w.isFocused ? winFocused : winFill,
                          stroke: winStroke,
                          thumbnails: thumbnails, iconFallback: false,
                          pal: pal)
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
                pal.foreground.withAlphaComponent(0.18).setFill(); path.fill()
                pal.foreground.withAlphaComponent(0.85).setStroke(); path.lineWidth = 2
            case .window:
                pal.primary.withAlphaComponent(0.28).setFill(); path.fill()
                pal.primary.setStroke(); path.lineWidth = 2
            }
        } else if let d = drag, d.kind == .workspace,
                  reorderDrag ? (c.sectionID == dragSectionID)
                              : (d.sourceWS == c.wsIndex) {
            // Dim the lifted SOURCE: reorder keys by sectionID (a lens source's
            // wsIndex −1 is shared); the keyboard swap keys by wsIndex.
            pal.foreground.withAlphaComponent(0.06).setFill(); path.fill()
            pal.foreground.withAlphaComponent(0.40).setStroke(); path.lineWidth = 1
        } else if c.isHero {
            // Always prominent: PRIMARY accent when the hero is the live
            // active WS, SECONDARY accent when browsing a different WS
            // (matches the browse-target strip cell — 2-b carousel).
            (c.isActive ? pal.primary : pal.secondary).setStroke()
            path.lineWidth = 2.5
        } else if c.isActive {
            pal.primary.setStroke(); path.lineWidth = 2          // PRIMARY = active WS
        } else if drag == nil && selectedSectionID == c.sectionID {
            // Browse target (≠ active) — SECONDARY accent border so it reads
            // apart from the primary-accent active section (2-b carousel).
            pal.secondary.setStroke(); path.lineWidth = 2
        } else if hoverID == c.sectionID {
            pal.foreground.withAlphaComponent(0.7).setStroke(); path.lineWidth = 1.5
        } else {
            pal.border.setStroke(); path.lineWidth = 1
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
           c.isHero || c.sectionID == selectedSectionID,
           let hit = c.windows.first(where: { $0.id == sel.id }) {
            let ring = NSBezierPath(roundedRect: hit.rect.insetBy(dx: -1, dy: -1),
                                    xRadius: 3, yRadius: 3)
            pal.primary.withAlphaComponent(0.30).setFill(); ring.fill()
            pal.primary.setStroke(); ring.lineWidth = c.isHero ? 3 : 2; ring.stroke()
        }
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
        hoverID = stripCellAt(p)?.sectionID
        let headerCell = stripCellAt(p).flatMap { $0.headerRect.contains(p) ? $0 : nil }
        let hh = headerCell?.sectionID
        if hh != hoverHeaderID { hoverHeaderID = hh; needsDisplay = true }
        // The overlay is key, so the cursor sticks: an open hand over a
        // WORKSPACE header advertises the grab (header drag = swap, Phase R3).
        // A lens header is click-only (no swap), so it keeps the arrow.
        (headerCell?.isLens == false ? NSCursor.openHand : NSCursor.arrow).set()
    }

    public override func mouseExited(with event: NSEvent) {
        hoverID = nil
        if hoverHeaderID != nil { hoverHeaderID = nil; needsDisplay = true }
        NSCursor.arrow.set()
    }

    // MARK: - Mouse (click switch / drag move / drag swap / dismiss)

    private func heroWinAt(_ p: NSPoint) -> MiniWindowHit? {
        hero?.windows.reversed().first { $0.rect.contains(p) }
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
        guard drag == nil, sectionOrder.count > 1,
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
        // Header press: a WORKSPACE header may become a swap drag (or click);
        // a LENS header is click-only → activate immediately (no swap arm,
        // no grip — Decision 6).
        if inStrip, let cell = cells.first(where: { $0.headerRect.contains(p) }) {
            // BOTH workspace + lens headers arm a reorder drag (past threshold);
            // a click still switches / toggles the lens (resolved on mouseUp).
            pendingHeaderDown = (p, cell.sectionID); return
        }
        // Window-thumb press → window drag (move) or click (switch + focus).
        // The big hero windows are the primary, ergonomic drag source;
        // the tiny bottom-cell windows are a secondary source.
        if let w = heroWinAt(p), let h = hero {
            pendingDown = (p, w, h.sectionID); return
        }
        if inStrip, let cell = cells.first(where: { $0.rect.contains(p) }) {
            if let w = cell.windows.reversed().first(where: { $0.rect.contains(p) }) {
                pendingDown = (p, w, cell.sectionID)
            } else {
                // empty cell area → activate+close (zoom if it's the centre)
                commitSwitch(targetSectionID: cell.sectionID) { [weak self] in
                    if cell.isLens { self?.onPick?(.lens(sectionID: cell.sectionID)) }
                    else { self?.onPick?(.workspace(workspaceIndex: cell.wsIndex)) }
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
            guard !cell.isLens else { return }       // lens header → no layout picker
            ViewContextMenu.showLayout(at: scr, backend: backend,
                                       workspaceIndex: cell.wsIndex,
                                       workspaces: workspaces,
                                       header: cell.label, palette: pal)
            return
        }
        if let w = heroWinAt(p), let h = hero {
            let home = windowHomeWS[w.id] ?? h.wsIndex
            guard home >= 0 else { return }          // unresolved (lens, no home) → no menu
            railWinMenu(scr, backend: backend, ws: home, w: w); return
        }
        if inStrip, let cell = cells.first(where: { $0.rect.contains(p) }),
           let w = cell.windows.reversed().first(where: { $0.rect.contains(p) }) {
            let home = windowHomeWS[w.id] ?? cell.wsIndex
            guard home >= 0 else { return }
            railWinMenu(scr, backend: backend, ws: home, w: w)
        }
    }

    /// Keyboard 'm' (③): context menu for the centred WS — the header
    /// (layout picker) when no hero window is cursored, else that window.
    public func kbContextMenu() {
        guard let backend, let win = window, let id = selectedSectionID,
              let cell = cells.first(where: { $0.sectionID == id }) else { return }
        if kbSelectedWindowIdx == -1 {
            guard !cell.isLens else { return }       // lens has no layout engine
            let scr = win.convertPoint(toScreen:
                convert(NSPoint(x: cell.headerRect.minX + 12, y: cell.headerRect.minY), to: nil))
            ViewContextMenu.showLayout(at: scr, backend: backend,
                                       workspaceIndex: cell.wsIndex, workspaces: workspaces,
                                       header: cell.label, palette: pal)
        } else if let h = hero, kbSelectedWindowIdx >= 0,
                  kbSelectedWindowIdx < h.windows.count {
            let w = h.windows[kbSelectedWindowIdx]
            let ws = windowHomeWS[w.id] ?? cell.wsIndex
            guard ws >= 0 else { return }            // unresolved (lens, no home) → no menu
            let scr = win.convertPoint(toScreen:
                convert(NSPoint(x: w.rect.minX + 12, y: w.rect.minY), to: nil))
            railWinMenu(scr, backend: backend, ws: ws, w: w)
        }
    }

    private func railWinMenu(_ scr: NSPoint, backend: any WindowBackend,
                             ws: Int, w: MiniWindowHit) {
        ViewContextMenu.showWindow(
            at: scr, backend: backend, workspaceIndex: ws,
            workspaces: workspaces, pid: w.pid, windowID: w.id, title: "",
            palette: pal
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
                if dx * dx + dy * dy < pointerDragThreshold * pointerDragThreshold { return }
                // Identify by sectionID (a lens header's wsIndex is −1). BOTH
                // workspace + lens headers arm a display-only REORDER drag.
                guard let src = cells.first(where: { $0.sectionID == ph.cellID })
                else { return }
                drag = OverviewDrag(sourceWS: src.wsIndex, kind: .workspace, pid: -1,
                            id: WindowID(serverID: -1), sourceRect: src.rect,
                            srcIDs: src.windows.map(\.id), current: p, dropTargetWS: nil)
                dragSectionID = ph.cellID
                reorderDrag = true
                reorderInsertAt = nil
                reorderLine = nil
                layoutSuppressed = true
                installWorkspaceGhost(for: src)
                NSCursor.closedHand.set()
            } else if let pd = pendingDown {
                let dx = p.x - pd.point.x, dy = p.y - pd.point.y
                if dx * dx + dy * dy < pointerDragThreshold * pointerDragThreshold { return }
                // A window inside a LENS cell has no source workspace → not
                // move-draggable (Decision 6). Resolve the cell + reject lens.
                guard let cell = cells.first(where: { $0.sectionID == pd.cellID }),
                      !cell.isLens else { return }
                drag = OverviewDrag(sourceWS: cell.wsIndex, kind: .window, pid: pd.hit.pid,
                            id: pd.hit.id, sourceRect: pd.hit.rect, srcIDs: [],
                            current: p, dropTargetWS: nil)
                layoutSuppressed = true
                installDragGhost(for: pd.hit)
                NSCursor.closedHand.set()
            } else { return }
        }
        guard var d = drag else { return }
        d.current = p
        if reorderDrag {
            updateReorderTarget(at: p)      // insertion boundary + line
        } else {
            // Drop targets are strip cells only (not the hero — it's the
            // active WS, already its own strip cell), and only within the
            // viewport clip (a rotated-off cell in the margin isn't a target).
            // A cell == source is not a target (no self-move).
            // A lens cell is never a drop target (no source WS — Decision 6).
            let over = stripCellAt(p)
            d.dropTargetWS = (over?.isLens == true || over?.wsIndex == d.sourceWS)
                ? nil : over?.wsIndex
        }
        drag = d
        positionDragGhost(at: p)
        needsDisplay = true
    }

    /// Section-reorder hit-test: the insertion BOUNDARY (in `sectionOrder`
    /// coords = the projected section order) for the strip cell under the
    /// cursor, before/after decided along the strip axis. Also precomputes the
    /// insertion-line endpoints. `nil` (no line / no commit) off all cells or
    /// on the dragged section's own slot.
    private func updateReorderTarget(at p: NSPoint) {
        guard let cell = stripCellAt(p),
              let t = sectionOrder.firstIndex(of: cell.sectionID) else {
            reorderInsertAt = nil; reorderLine = nil; return
        }
        let horizontal = edge.axis == .horizontal
        let after = horizontal ? (p.x >= cell.rect.midX) : (p.y >= cell.rect.midY)
        let b = after ? t + 1 : t
        if let id = dragSectionID, let s = sectionOrder.firstIndex(of: id),
           b == s || b == s + 1 {
            reorderInsertAt = nil; reorderLine = nil; return    // own slot → no-op
        }
        reorderInsertAt = b
        if horizontal {
            let x = after ? cell.rect.maxX : cell.rect.minX
            reorderLine = (NSPoint(x: x, y: cell.rect.minY),
                           NSPoint(x: x, y: cell.rect.maxY))
        } else {
            let y = after ? cell.rect.maxY : cell.rect.minY
            reorderLine = (NSPoint(x: cell.rect.minX, y: y),
                           NSPoint(x: cell.rect.maxX, y: y))
        }
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
                // Window thumb → switch to its HOME WS AND focus THAT window
                // (home resolved via windowHomeWS — correct even inside a lens
                // cell whose wsIndex is −1; the Controller guards home >= 0).
                let cell = cells.first { $0.sectionID == pd.cellID }
                let home = windowHomeWS[pd.hit.id] ?? cell?.wsIndex ?? -1
                commitSwitch(targetSectionID: pd.cellID) { [weak self] in
                    self?.onPick?(.window(homeWorkspaceIndex: home,
                                          pid: pd.hit.pid, windowID: pd.hit.id))
                }
            } else if let ph = pendingHeaderDown,
                      let cell = cells.first(where: { $0.sectionID == ph.cellID }) {
                // Header click → switch to that workspace, or toggle the lens.
                commitSwitch(targetSectionID: ph.cellID) { [weak self] in
                    if cell.isLens { self?.onPick?(.lens(sectionID: cell.sectionID)) }
                    else { self?.onPick?(.workspace(workspaceIndex: cell.wsIndex)) }
                }
            }
            return
        }
        // Drag path: commit or cancel. Do NOT clear `drag` here — the
        // landing gate (commit) / cancel animation owns the teardown.
        guard let d = drag else { return }
        if reorderDrag {
            // Section reorder commit (display-only, session-only): the
            // Controller mutates the per-mac-desktop order override + re-renders.
            // No backend round-trip → clear + re-lay now (a no-op drop just
            // re-lays unchanged; `reorderInsertAt` is nil then).
            if let id = dragSectionID, let at = reorderInsertAt {
                onReorder?(id, at)
            }
            clearDrag()
            layoutCells()
            return
        }
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
        guard kbSelectedWindowIdx >= 0, let h = hero, !h.windows.isEmpty
        else { return nil }
        let ordered = readingOrder(h.windows)
        return ordered[max(0, min(ordered.count - 1, kbSelectedWindowIdx))]
    }

    /// Browse-axis arrow (2-b carousel): ROTATE the strip one workspace
    /// so the next/previous one comes to the centre — the new centre is
    /// the browse target (hero previews it). Lifted → the centred cell is
    /// the drop target instead. `dx` is +1 / −1 along the strip (next /
    /// previous, supplied by the Controller for the edge's axis); it
    /// wraps circularly.
    public func kbMoveSelection(dx: Int) {
        guard !commitZoom.isActive, !sectionOrder.isEmpty else { return }
        let m = sectionOrder.count
        let cur = sectionOrder.firstIndex(of: selectedSectionID ?? "") ?? 0
        let ni = (cur + dx + m) % m   // wrap over ALL sections (lenses included)
        guard sectionOrder[ni] != selectedSectionID else { return }
        // Browse crossfade (①): snapshot the current hero before it
        // changes, to fade it out over the new one as the slide eases in.
        if drag == nil, let h = hero {
            prevHeroImage = snapshotRegion(h.rect); prevHeroRect = h.rect
        }
        selectedSectionID = sectionOrder[ni]
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
        kbSelectedWindowIdx = cycleSlotIndex(
            current: kbSelectedWindowIdx,
            windowCount: h.windows.count, forward: forward)
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
        // A window inside a LENS hero is not move-liftable (no source WS,
        // Decision 6) — guard `!h.isLens` so `h.wsIndex` below is a real WS.
        guard drag == nil, let h = hero, !h.isLens, let sel = kbSelectedWindow() else { return }
        // Lift from the BOTTOM cell's window (small) so the ghost matches
        // the rail's bottom-row size, not the big hero. Fall back to the
        // hero window if that window has no thumb in the bottom cell.
        let hit = cells.first(where: { $0.sectionID == selectedSectionID })?
            .windows.first(where: { $0.id == sel.id }) ?? sel
        let at = NSPoint(x: hit.rect.midX, y: hit.rect.midY)
        drag = OverviewDrag(sourceWS: h.wsIndex, kind: .window,
                    pid: hit.pid, id: hit.id, sourceRect: hit.rect, srcIDs: [],
                    current: at, dropTargetWS: nil)
        layoutSuppressed = true
        installDragGhost(for: hit)
        positionDragGhost(at: at)
        needsDisplay = true
    }

    private func kbLiftWorkspace() {
        // A lens cell cannot be lifted for a swap (no source WS — Decision 6).
        guard drag == nil, let id = selectedSectionID,
              let cell = cells.first(where: { $0.sectionID == id }), !cell.isLens else { return }
        let ws = cell.wsIndex
        // Live workspace windows (not the render-filtered thumbs).
        let srcIDs = workspaces.first(where: { $0.index == ws })?.windows.map(\.id)
            ?? cell.windows.map(\.id)
        let at = NSPoint(x: cell.rect.midX, y: cell.rect.midY)
        drag = OverviewDrag(sourceWS: ws, kind: .workspace, pid: -1,
                    id: WindowID(serverID: -1), sourceRect: cell.rect,
                    srcIDs: srcIDs, current: at, dropTargetWS: nil)
        layoutSuppressed = true
        installWorkspaceGhost(for: cell)
        positionDragGhost(at: at)
        needsDisplay = true
    }

    /// While lifted, an arrow advances `selectedSectionID` (the aim cursor);
    /// re-target the drop + teleport the ghost to the aimed cell.
    private func syncRailDragToSelection() {
        guard var d = drag, let id = selectedSectionID,
              let cell = cells.first(where: { $0.sectionID == id }) else { return }
        // Aiming at a lens cell → no valid drop (lens isn't a swap/move
        // destination); the ghost still teleports so the rotation reads.
        d.dropTargetWS = (cell.isLens || cell.wsIndex == d.sourceWS) ? nil : cell.wsIndex
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
        guard let id = selectedSectionID,
              let cell = cells.first(where: { $0.sectionID == id }) else { return }
        // The selected section is the centre, so this always plays the zoom (②).
        if let hit = kbSelectedWindow() {
            // Window (even inside a lens hero) → switch to its HOME WS + focus it.
            let home = windowHomeWS[hit.id] ?? cell.wsIndex
            commitSwitch(targetSectionID: id) { [weak self] in
                self?.onPick?(.window(homeWorkspaceIndex: home, pid: hit.pid, windowID: hit.id))
            }
        } else if cell.isLens {
            commitSwitch(targetSectionID: id) { [weak self] in
                self?.onPick?(.lens(sectionID: cell.sectionID))  // lens → activate it
            }
        } else {
            commitSwitch(targetSectionID: id) { [weak self] in
                self?.onPick?(.workspace(workspaceIndex: cell.wsIndex))  // WS → switch
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

// MARK: - OverviewView conformance
//
// Every requirement is satisfied by members declared above (the
// snapshot inputs, the run-ops / move / swap callbacks, the no-arg
// layoutCells / setThumbnail / clearThumbnails, the BorderFX trio, and
// the common keyboard verbs). The rail-specific surface —
// `onPick(RailPick)`, `edge` / `cellsTarget` /
// `stripPercent` / `selectedSectionID`, the 1-D `kbMoveSelection(dx:)`,
// `scrollRotate`, the carousel + hero — stays off the shared protocol.
extension RailView: OverviewView {}
