// Tree-view sidebar — the translucent always-on-top panel that
// lists workspaces and their windows. AX / focus orchestration
// routes through `TreeController` rather than touching globals,
// and the view talks to `WindowBackend` only (no concrete adapter
// imports — see CLAUDE.md layer rules).

import AppKit
import CoreGraphics
import FacetCore
import FacetView

public final class SidebarView: NSView {

    // MARK: - Wiring

    public weak var controller: TreeController?
    private let backend: any WindowBackend

    public init(frame: NSRect, backend: any WindowBackend) {
        self.backend = backend
        super.init(frame: frame)
    }
    public required init?(coder: NSCoder) { nil }

    // MARK: - Visual state

    private var rows: [TreeRow] = []
    private struct Cell {
        let row: NSRect
        let kind: Int          // 0 handle · 1 header · 2 window
        let hot: Bool
        let firstHeader: Bool
        let pid: Int
        let app: String
        let title: String
        let text: String       // handle / header label
        let mode: String       // header: WS layout engine
        let isMaster: Bool     // window: shows a right-edge `master` chip
        let isFloating: Bool   // window: shows a right-edge `float` chip
    }
    private var cells: [Cell] = []
    private var hoverIdx: Int?            // row under the pointer

    // Keyboard-nav mode (entered via `facet --active`).
    public private(set) var kbNav = false
    private var kbSel: TreeKbSel?

    // Type-to-filter sub-mode (entered with `s` while in --active).
    // When on, headers drop out; only fuzzy-matching window rows
    // are listed (cross-workspace flat list).
    public private(set) var searching = false
    public private(set) var query = ""

    private var wsBands: [Int: ClosedRange<CGFloat>] = [:]
    public private(set) var signature = ""
    public private(set) var contentHeight: CGFloat = 40

    /// While true, `draw` renders placeholder rows and `update`
    /// holds (incoming refreshes don't replace the skeleton). Driven
    /// by the CLI `facet --view=tree --loading[=MS]`: an external
    /// tool (e.g. chord) shows the skeleton just BEFORE triggering a
    /// native-Space switch, so the shared panel never flashes the
    /// previous desktop's tree. The Controller clears it on a timer.
    /// Memory: facet-per-native-space-ws.
    private var skeleton = false
    /// Content signature at the moment the skeleton was shown. While
    /// skeleton is up, an `update` whose signature still equals this
    /// is the SAME (pre-switch) content → keep holding; a different
    /// signature means new content loaded → drop the skeleton early.
    private var skeletonBaseSig = ""
    public private(set) var activeWS: Int?    // REAL active WS (skip-switch)

    // Optimistic selection: on click we move the highlight
    // immediately and hold briefly; the next real query reconciles
    // (reverts if rift's focus actually failed).
    private var lastWorkspaces: [Workspace] = []
    // Native macOS desktop ordinal (Mission Control order) for the
    // top handle band's "Desktop N" label. nil = SkyLight
    // unavailable / single-space → band shows no name. Preserved
    // across internal relayouts (update's `nativeDesktop` arg is a
    // double-optional: omitted = keep current).
    private var nativeDesktopOrdinal: Int?
    // AX-resolved titles for windows the backend left blank; kept
    // across internal relayouts that don't re-resolve.
    private var titleOverride: [WindowID: String] = [:]
    private var optWindowID: WindowID?
    private var optActiveWS: Int?
    private var optUntil: Date?

    // Drag state (driven by the explicit tracking loop in
    // mouseDown).
    private var draggingWid: (workspaceIndex: Int, windowID: WindowID)?
    private var dropWS: Int?
    private var dragLabel: String?
    private var lastDropWS: Int?           // redraw band only when this changes
    // Header-swap drag: source WS while a workspace header is being
    // dragged onto another (mouseDown loop `mode == 3`). Parallel to
    // `draggingWid`; drop trades the two workspaces' contents.
    private var draggingWS: Int?
    // Keyboard DnD: the row lifted with Space (window = move, header
    // = WS-swap). `kbDropWS` is the current aim target; arrows walk
    // it through the workspace order, Return/Space commits, Esc
    // cancels. nil = not lifting. Theme A: target carries the
    // move/swap semantics — no modifier keys.
    private var kbLifted: TreeKbSel?
    private var kbDropWS: Int?
    private lazy var chip: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.wantsLayer = true
        f.isBordered = false
        f.drawsBackground = false
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.isHidden = true
        f.layer?.cornerRadius = 6
        f.layer?.masksToBounds = true
        f.layer?.zPosition = 1000
        f.alignment = .center
        addSubview(f)
        return f
    }()
    private var prevApp: NSRunningApplication?   // re-activate post-drag

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    // Without this, the first click on a non-key panel only promotes
    // the panel to key — mouseDown never reaches row hit-test, so the
    // user has to click twice before a click registers.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // For NSPanel with becomesKeyOnlyIfNeeded=true, mouseDragged is
    // only routed to a view if it returns true from BOTH of these.
    // Without them the row click works but a drag (to-move panel /
    // to-move window) silently no-ops on a non-key panel.
    public override var acceptsFirstResponder: Bool { true }
    public override var needsPanelToBecomeKey: Bool { true }

    // MARK: - Optimistic state

    /// True while the optimistic highlight is still being held;
    /// auto-clears the optimistic state once expired.
    private func optimisticHeld() -> Bool {
        if let u = optUntil, Date() < u { return true }
        optWindowID = nil; optActiveWS = nil; optUntil = nil
        return false
    }

    /// Move the highlight to the clicked window immediately (before
    /// the backend reports back). Reconciled by the next real
    /// query.
    func setOptimistic(windowID: WindowID, workspaceIndex: Int) {
        optWindowID = windowID; optActiveWS = workspaceIndex
        // Hold past the focus-assert window so the highlight doesn't
        // flicker to rift's transient default focus before our
        // re-assert wins.
        optUntil = Date().addingTimeInterval(0.85)
        update(lastWorkspaces)            // rebuild now with the override
        controller?.scheduleReconcile(after: 0.9)
    }

    // MARK: - Update / layout

    @discardableResult
    public func update(_ workspaces: [Workspace],
                       titles: [WindowID: String]? = nil,
                       nativeDesktop: Int?? = nil) -> CGFloat {
        lastWorkspaces = workspaces
        if let titles { titleOverride = titles }
        // Double-optional: omitting the arg (internal relayouts) keeps
        // the current ordinal; passing it (the Controller refresh)
        // sets it — including to nil when SkyLight is unavailable.
        if let nativeDesktop { nativeDesktopOrdinal = nativeDesktop }
        activeWS = workspaces.first(where: { $0.isActive })?.index   // always REAL
        let opt = optimisticHeld()
        let effActive = opt ? optActiveWS : activeWS
        func hot(_ win: Window) -> Bool {
            opt ? (win.id == optWindowID) : win.isFocused
        }
        // Backend's title, or our AX-resolved one when blank.
        func eff(_ win: Window) -> String {
            win.title.isEmpty
                ? (titleOverride[win.id] ?? "") : win.title
        }
        let sig = (searching ? "S:\(query);" : "")
            + "D\(nativeDesktopOrdinal ?? -1);"
            + (opt
                ? "O\(optWindowID?.serverID ?? -1):\(optActiveWS ?? -1);"
                : "R;")
            + workspaces.map { ws in
                "\(ws.index)\(ws.index == effActive ? "*" : "")\(ws.layoutMode)|"
                + ws.windows.map {
                    "\($0.id.serverID)\(hot($0) ? "f" : ""):\(eff($0))"
                }.joined(separator: ",")
            }.joined(separator: ";")
        // Loading skeleton: hold while content is UNCHANGED from when
        // `--loading` fired (e.g. a refresh mid native-Space switch
        // still returns the previous desktop), but clear the instant
        // genuinely new content arrives (the new desktop finished
        // loading). The Controller's timer is only an upper bound.
        if skeleton {
            if sig == skeletonBaseSig { return skeletonHeight }
            skeleton = false
            Log.debug("tree: skeleton cleared (new content loaded)")
        }
        if sig == signature { return contentHeight }
        signature = sig
        rows.removeAll(); cells.removeAll(); wsBands.removeAll()
        let w = max(bounds.width, sidebarWidth)
        var y: CGFloat = 6        // small top inset

        // Top drag-handle band: grab to move the panel (mouseDown
        // routes a `.handle` drag to panel-move, mode 1) and shows the
        // native macOS desktop ("Desktop N") when SkyLight resolves the
        // ordinal — the panel previously had no grab affordance.
        let hbr = NSRect(x: 0, y: y, width: w, height: handleRowH)
        rows.append(TreeRow(rect: hbr, kind: .handle))
        cells.append(Cell(row: hbr, kind: 0, hot: false, firstHeader: false,
                          pid: 0, app: "", title: "",
                          text: nativeDesktopOrdinal.map { "Desktop \($0)" } ?? "",
                          mode: "", isMaster: false, isFloating: false))
        y += handleRowH

        if searching {
            // Flat cross-workspace result list (no headers).
            for ws in workspaces {
                for win in ws.windows {
                    let wt = eff(win)
                    guard fuzzyMatch(query, win.appName + " " + wt)
                    else { continue }
                    let hasLabel = win.isMaster || win.isFloating
                    let baseRH = wt.isEmpty ? windowRowH : windowRowTallH
                    let rh = baseRH + (hasLabel ? 14 : 0)
                    let wr = NSRect(x: 0, y: y, width: w, height: rh)
                    rows.append(TreeRow(rect: wr, kind: .window(
                        workspaceIndex: ws.index, pid: win.pid,
                        windowID: win.id, title: wt)))
                    cells.append(Cell(row: wr, kind: 2, hot: hot(win),
                                      firstHeader: false, pid: win.pid,
                                      app: win.appName, title: wt,
                                      text: "", mode: "",
                                      isMaster: win.isMaster,
                                      isFloating: win.isFloating))
                    y += rh
                }
            }
            contentHeight = y + 6
        } else {
            var firstHeader = true
            for ws in workspaces {
                let start = y
                let hh = firstHeader ? headerFirstRowH : headerRowH
                let hr = NSRect(x: 0, y: y, width: w, height: hh)
                rows.append(TreeRow(rect: hr,
                                    kind: .header(workspaceIndex: ws.index)))
                let t = ws.name.isEmpty ? "WS\(ws.index + 1)" : ws.name
                cells.append(Cell(row: hr, kind: 1, hot: ws.index == effActive,
                                  firstHeader: firstHeader, pid: 0, app: "",
                                  title: "", text: t.uppercased(),
                                  mode: ws.layoutMode,
                                  isMaster: false, isFloating: false))
                firstHeader = false
                y += hh
                for win in ws.windows {
                    let wt = eff(win)
                    let hasLabel = win.isMaster || win.isFloating
                    let baseRH = wt.isEmpty ? windowRowH : windowRowTallH
                    // A 3rd line (master / float) adds 14 pt so the
                    // label has its own row instead of crowding the
                    // title baseline.
                    let rh = baseRH + (hasLabel ? 14 : 0)
                    let wr = NSRect(x: 0, y: y, width: w, height: rh)
                    rows.append(TreeRow(rect: wr, kind: .window(
                        workspaceIndex: ws.index, pid: win.pid,
                        windowID: win.id, title: wt)))
                    cells.append(Cell(row: wr, kind: 2, hot: hot(win),
                                      firstHeader: false, pid: win.pid,
                                      app: win.appName, title: wt,
                                      text: "", mode: "",
                                      isMaster: win.isMaster,
                                      isFloating: win.isFloating))
                    y += rh
                }
                wsBands[ws.index] = start...(y + 3)
                y += 3
            }
            contentHeight = y + 6
        }
        if kbNav { resolveSel() }
        needsDisplay = true
        return contentHeight
    }

    public func forceRedraw() { signature = "" }

    /// Enter the loading-skeleton state (CLI `--loading`). Held until
    /// `clearSkeleton`; refreshes are absorbed without repainting.
    public func showSkeleton() {
        skeletonBaseSig = signature   // content shown right before loading
        skeleton = true
        needsDisplay = true
    }

    /// Leave the skeleton. `signature = ""` forces the next `update`
    /// (driven by the Controller's `apply`) to rebuild real content.
    public func clearSkeleton() {
        guard skeleton else { return }
        skeleton = false
        signature = ""
        needsDisplay = true
    }

    public var isSkeleton: Bool { skeleton }

    /// Panel height while the skeleton is on screen — three
    /// placeholder sections (header + two rows each).
    public var skeletonHeight: CGFloat {
        headerFirstRowH + headerRowH * 2 + windowRowH * 6 + 12
    }
    public func relayout() { signature = ""; _ = update(lastWorkspaces) }

    // MARK: - type-to-filter (entered with `s` in --active)

    private func rebuildSearch() {
        signature = ""
        _ = update(lastWorkspaces)
        kbSel = kbDefault()      // land on the first match each keystroke
        needsDisplay = true
        scrollSelVisible()
        controller?.previewTargetChanged()
    }

    /// Input comes from a real NSTextField (Controller-owned SearchBar)
    /// so the IME works; the field is the source of truth for `query`.
    public func beginSearch() { searching = true; query = ""; rebuildSearch() }

    public func setQuery(_ s: String) {
        guard searching else { return }
        query = s; rebuildSearch()
    }

    public func endSearch() {
        guard searching else { return }
        searching = false; query = ""
        signature = ""; _ = update(lastWorkspaces)
        needsDisplay = true
        controller?.previewTargetChanged()
    }

    // MARK: - Hover (cursor + highlight)

    // `.activeAlways` so hover still works while we're an inactive
    // accessory app (cursor may still be gated by macOS; the
    // highlight always works regardless).
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
        let i = rows.firstIndex { $0.rect.contains(p) }
        if i != hoverIdx {
            hoverIdx = i; needsDisplay = true
            controller?.previewTargetChanged()
        }
        hoverCursor(forRow: i).set()
    }

    /// Header rows are swap drag-handles → open-hand "grab" cursor
    /// (matches the grid header); other rows are click targets →
    /// pointing-hand; off-rows → arrow.
    ///
    /// NOTE: cursor changes only take effect while facet is the
    /// active app (i.e. `--active`). In passive `--view=tree` the
    /// panel is a non-activating background accessory, and macOS lets
    /// only the active app own the cursor — `NSCursor.set()` here is a
    /// harmless no-op then. Passive affordance is carried by the
    /// always-drawn grip (which also brightens on hover), so this is
    /// an OS limitation we accept rather than fight.
    private func hoverCursor(forRow i: Int?) -> NSCursor {
        guard let i, rows.indices.contains(i) else { return .arrow }
        if case .header = rows[i].kind { return .openHand }
        return .pointingHand
    }

    public override func mouseExited(with e: NSEvent) {
        if hoverIdx != nil {
            hoverIdx = nil; needsDisplay = true
            controller?.previewTargetChanged()
        }
        NSCursor.arrow.set()
    }

    /// Windows whose previews should show, paired with:
    /// - `rowAnchor` — screen rect of the source row (popover mode
    ///   anchor; keeps the preview on-screen even when the window
    ///   is anchor-hidden in a 1×41 corner sliver).
    /// - `windowFrame` — the window's own backend frame in Quartz
    ///   coords (mirror mode), or `nil` if the backend hasn't
    ///   reported one. The caller picks between anchor and frame
    ///   based on the `tree.preview-mode` config.
    ///
    /// Empty = no preview. A window row → 1 item; a workspace
    /// header → every window of that workspace, all sharing the
    /// header row as their popover anchor (the caller stacks
    /// them). The active workspace is always skipped — would just
    /// overlay the visible windows on themselves.
    public func previewTargets()
        -> [(window: WindowID, rowAnchor: NSRect, windowFrame: CGRect?)]
    {
        enum T { case win(WindowID); case ws(Int) }
        var t: T?
        if kbNav, let s = kbSel {
            switch s {
            case .win(let id):                  t = .win(id)
            case .hdr(let w):                   t = .ws(w)
            }
        } else if let h = hoverIdx, rows.indices.contains(h) {
            switch rows[h].kind {
            case .window(_, _, let id, _):      t = .win(id)
            case .header(let w):                t = .ws(w)
            default:                            break
            }
        }
        guard let t, let win = self.window else { return [] }
        func screen(_ r: NSRect) -> NSRect {
            win.convertToScreen(convert(r, to: nil))
        }
        switch t {
        case .win(let id):
            guard let ws = lastWorkspaces.first(where: { w in
                w.windows.contains { $0.id == id }
            }), !ws.isActive,
                  let winModel = ws.windows.first(where: { $0.id == id }),
                  let rowIdx = rows.firstIndex(where: { r in
                      if case .window(_, _, let wid, _) = r.kind {
                          return wid == id
                      }
                      return false
                  })
            else { return [] }
            return [(id, screen(rows[rowIdx].rect), winModel.frame)]
        case .ws(let wi):
            guard let ws = lastWorkspaces.first(where: { $0.index == wi }),
                  !ws.isActive,
                  let hdrIdx = rows.firstIndex(where: { r in
                      if case .header(let w) = r.kind { return w == wi }
                      return false
                  })
            else { return [] }
            let anchor = screen(rows[hdrIdx].rect)
            return ws.windows.map {
                (window: $0.id, rowAnchor: anchor, windowFrame: $0.frame)
            }
        }
    }

    public override func cursorUpdate(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        hoverCursor(forRow: rows.firstIndex { $0.rect.contains(p) }).set()
    }

    // MARK: - Draw

    /// Loading placeholder shown via `facet --view=tree --loading`.
    /// Mirrors the real layout's rhythm (caption + two window rows
    /// per section) with muted, theme-aware rounded bars.
    private func drawSkeleton() {
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                 _ alpha: CGFloat, _ radius: CGFloat = 4.5) {
            pal.dim.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                         xRadius: radius, yRadius: radius).fill()
        }
        var y: CGFloat = 6
        let widths: [CGFloat] = [0.60, 0.44, 0.52]
        for s in 0..<3 {
            let hh = s == 0 ? headerFirstRowH : headerRowH
            let capY = s == 0 ? y + 8 : y + 20
            bar(rowPadX, capY, bounds.width * 0.34, 9, 0.80)
            y += hh
            for r in 0..<2 {
                bar(rowPadX + 2, y + (windowRowH - 14) / 2, 14, 14, 0.45, 4)
                let tw = max(bounds.width * widths[(s + r) % widths.count] - 40, 40)
                bar(rowPadX + 24, y + (windowRowH - 9) / 2, tw, 9, 0.45)
                y += windowRowH
            }
            y += 3
        }
    }

    /// A 2-column dot grid — the universal "drag handle" affordance
    /// drawn at the left of every workspace header (header drag =
    /// WS-swap). Height-aware: stretches to an 8-row vertical strip
    /// in a tall rect (the WS header's full 2-line caption) so the
    /// grip reads as a proper anchor for the whole header; falls
    /// back to the compact 3-row form in shorter rects (the top
    /// desktop-name band). The tree stays at 2×8 (vs the grid's 3×10)
    /// because the sidebar is narrow — a wider strip would crowd the
    /// WS name column.
    private func drawGrip(in r: NSRect, hot: Bool) {
        let dotR: CGFloat = 1.15
        let xs = [r.minX + dotR + 1, r.minX + dotR + 5]
        let ys: [CGFloat] = r.height >= 28
            ? stride(from: -14.0, through: 14.0, by: 4.0)
                .map { r.midY + $0 }
            : [r.midY - 4, r.midY, r.midY + 4]
        (hot ? pal.accent : pal.dim)
            .withAlphaComponent(hot ? 0.85 : 0.45).setFill()
        for x in xs {
            for y in ys {
                NSBezierPath(ovalIn: NSRect(x: x - dotR, y: y - dotR,
                                            width: dotR * 2,
                                            height: dotR * 2)).fill()
            }
        }
    }

    public override func draw(_ dirty: NSRect) {
        if skeleton { drawSkeleton(); return }
        // Strong drop-target highlight: only a *different* workspace
        // band is a valid drop target — fill + outline it so "drop
        // here" is unmistakable. Source is a mouse window-drag
        // (`draggingWid`), a mouse header-swap (`draggingWS`), or a
        // keyboard lift (`kbLifted`). For a swap the source band is
        // also dashed-outlined so the trade reads as "these two".
        if let ctx = dragContext() {
            if let tgt = ctx.target, tgt != ctx.source,
               let band = wsBands[tgt] {
                let r = NSRect(x: 1, y: band.lowerBound,
                               width: bounds.width - 2,
                               height: band.upperBound - band.lowerBound)
                pal.accent.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                pal.accent.setStroke()
                let o = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1),
                                     xRadius: 6, yRadius: 6)
                o.lineWidth = 2
                o.stroke()
            }
            if ctx.isSwap, let band = wsBands[ctx.source] {
                let r = NSRect(x: 1, y: band.lowerBound,
                               width: bounds.width - 2,
                               height: band.upperBound - band.lowerBound)
                    .insetBy(dx: 1, dy: 1)
                pal.accent.withAlphaComponent(0.7).setStroke()
                let o = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
                o.lineWidth = 1.5
                o.setLineDash([4, 3], count: 2, phase: 0)
                o.stroke()
            }
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        let kbSelRow = kbNav ? kbSel.flatMap(kbIndex(of:)) : nil
        for (i, c) in cells.enumerated() {
            let row = c.row
            switch c.kind {
            case 0:   // top drag-handle band: grab to move the panel;
                      // shows the native macOS desktop ("Desktop N").
                      // Divider sits `dividerPadBelow` above the band's
                      // bottom edge; label + grip centre in the zone
                      // above it, so the line reads with breathing room
                      // on both sides.
                let dividerPadBelow: CGFloat = 6
                let zoneH = row.height - dividerPadBelow
                drawGrip(in: NSRect(x: rowPadX,
                                    y: row.minY + (zoneH - 12) / 2,
                                    width: headerGripW, height: 12),
                         hot: hoverIdx == i)
                let th: CGFloat = 18
                let t = c.text as NSString
                t.draw(in: NSRect(x: rowPadX + headerGripW + 7,
                                  y: row.minY + (zoneH - th) / 2,
                                  width: bounds.width
                                      - (rowPadX * 2 + headerGripW + 7),
                                  height: th),
                       withAttributes: [
                        .font: uiFont(13, .bold),
                        .foregroundColor: pal.text,
                        .kern: 0.5, .paragraphStyle: para])
                let lineY = row.maxY - dividerPadBelow
                pal.divider.setStroke()
                let hsep = NSBezierPath()
                hsep.move(to: NSPoint(x: rowPadX, y: lineY))
                hsep.line(to: NSPoint(x: bounds.width - rowPadX, y: lineY))
                hsep.lineWidth = 1
                hsep.stroke()

            case 1:   // workspace section header — 2-line caption
                if !c.firstHeader {
                    pal.divider.setStroke()
                    let sep = NSBezierPath()
                    let sy = row.minY + 9           // tighter gap above
                    sep.move(to: NSPoint(x: rowPadX, y: sy))
                    sep.line(to: NSPoint(x: bounds.width - rowPadX, y: sy))
                    sep.lineWidth = 1
                    sep.stroke()
                }
                let hp = NSMutableParagraphStyle()
                hp.lineBreakMode = .byTruncatingTail
                hp.maximumLineHeight = row.height
                let fs = c.hot ? activeHeaderFontSize : headerFontSize
                let capY = c.firstHeader ? row.minY + 6 : row.minY + 18
                let capH = row.maxY - capY - 6
                // Drag grip — affords "grab to swap this workspace".
                // Spans the full caption area so it visually anchors both
                // lines (WS name + layout-mode chip) as one unit.
                let gripSpace = headerGripW + 6
                drawGrip(in: NSRect(x: rowPadX, y: capY,
                                    width: headerGripW, height: capH),
                         hot: c.hot || hoverIdx == i)
                // Line 1: WS name (accent when active).
                let nameH: CGFloat = 18
                (c.text as NSString).draw(
                    in: NSRect(x: rowPadX + gripSpace, y: capY,
                               width: bounds.width - rowPadX * 2 - gripSpace,
                               height: nameH),
                    withAttributes: [
                        .font: uiFont(fs, .bold),
                        .foregroundColor: c.hot ? pal.accent : pal.dim,
                        .kern: 0.6, .paragraphStyle: hp])
                // Line 2: layout-mode text — accent-2 semibold on the
                // active WS, `pal.dim` semibold when the WS isn't
                // active so non-focused rows recede. No pill
                // background (the WS name on line 1 carries enough
                // visual weight for the group); the color + weight
                // step alone separates the badge from body text.
                // accent-2 is the palette's secondary hue
                // (terminal=purple, cute=peach, system=systemPurple),
                // reserved for status badges so the text never
                // collides with the primary accent used by the
                // active WS-name on line 1.
                if !c.mode.isEmpty {
                    let modeColor = c.hot ? pal.accent2 : pal.dim
                    (c.mode as NSString).draw(
                        in: NSRect(x: rowPadX + gripSpace,
                                   y: capY + nameH + 4,
                                   width: bounds.width - rowPadX * 2 - gripSpace,
                                   height: 14),
                        withAttributes: [
                            .font: uiFont(10.5, .semibold),
                            .foregroundColor: modeColor,
                            .paragraphStyle: hp,
                        ])
                }

            default:  // window row
                let sel = c.hot
                let hov = (hoverIdx == i)
                let pill = row.insetBy(dx: 6, dy: 2)
                if sel {
                    pal.selFill.setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                        .fill()
                    pal.accent.setFill()
                    NSBezierPath(roundedRect: NSRect(
                        x: pill.minX, y: pill.minY + 3,
                        width: 3, height: pill.height - 6),
                        xRadius: 1.5, yRadius: 1.5).fill()
                } else if hov {
                    pal.hoverFill.setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                        .fill()
                }
                let iconX = rowPadX + 2
                let iconY = row.midY - iconSize / 2
                if let img = AppIcons.icon(forPID: c.pid) {
                    img.draw(in: NSRect(x: iconX, y: iconY,
                                        width: iconSize, height: iconSize))
                }
                // Status label (master / float) — text-only 3rd line
                // under the title (or under the app name when there's
                // no title). Master and float are mutually exclusive
                // in the catalog (a floated window is detached from
                // the layout and can't also be its master). Same
                // accent-2 semibold styling as the WS-header layout
                // line, so the badge palette stays consistent across
                // the tree.
                let labelText: String? =
                    c.isMaster ? "master" :
                    c.isFloating ? "float" : nil
                let hasLabel = labelText != nil
                let hasTitle = !c.title.isEmpty
                let tx = iconX + iconSize + 8
                let tw = max(bounds.width - tx - rowPadX, 0)
                // Pin the app name to the top whenever a title or a
                // status label sits below it; otherwise center it.
                let appY = (hasTitle || hasLabel)
                    ? row.minY + 6 : row.midY - 9
                (c.app as NSString).draw(
                    in: NSRect(x: tx, y: appY, width: tw, height: 18),
                    withAttributes: [
                        .font: uiFont(windowFontSize,
                                      sel ? .semibold : .medium),
                        .foregroundColor: sel ? pal.accent : pal.text,
                        .paragraphStyle: para,
                    ])
                if hasTitle {
                    (c.title as NSString).draw(
                        in: NSRect(x: tx, y: row.minY + 25,
                                   width: tw, height: 15),
                        withAttributes: [
                            .font: uiFont(windowFontSize - 1, .regular),
                            .foregroundColor: pal.dim,
                            .paragraphStyle: para,
                        ])
                }
                if let labelText {
                    let labelY = hasTitle
                        ? row.minY + 42   // app(6-24) + title(25-40) + gap
                        : row.minY + 24   // app(6-24) + tiny gap
                    (labelText as NSString).draw(
                        in: NSRect(x: tx, y: labelY,
                                   width: tw, height: 14),
                        withAttributes: [
                            .font: uiFont(windowFontSize - 1, .semibold),
                            .foregroundColor: pal.accent2,
                            .paragraphStyle: para,
                        ])
                }
            }

            // Keyboard cursor: an accent outline distinct from the
            // selected-window pill (fill) and hover (faint fill).
            if let kbSelRow, kbSelRow == i {
                let r = (c.kind == 2 ? row.insetBy(dx: 6, dy: 2)
                                     : row.insetBy(dx: 6, dy: 4))
                pal.accent.setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1),
                                     xRadius: 7, yRadius: 7)
                p.lineWidth = 2
                p.stroke()
            }
        }

        // DnD: dim the lifted/dragged source window row (mouse drag
        // or kb lift). The follow-pointer chip is a separate
        // layer-backed subview (repositioned, never redrawn) so it
        // keeps up with fast cursor motion. Header-swap dims nothing
        // here — its source WS is dashed-outlined above instead.
        let liftedWinID: WindowID? = draggingWid?.windowID ?? {
            if case .win(let id)? = kbLifted { return id }
            return nil
        }()
        if let liftedWinID {
            for row in rows {
                if case .window(_, _, let id, _) = row.kind,
                   id == liftedWinID {
                    (pal.bg ?? .windowBackgroundColor)
                        .withAlphaComponent(0.55).setFill()
                    NSBezierPath(roundedRect: row.rect.insetBy(dx: 4, dy: 1),
                                 xRadius: 5, yRadius: 5).fill()
                }
            }
        }
    }

    /// Unified drag/lift context for `draw`: the source workspace,
    /// the current drop target (if any), and whether the gesture is a
    /// header swap (vs a window move).
    private func dragContext() -> (source: Int, target: Int?, isSwap: Bool)? {
        if let d = draggingWid { return (d.workspaceIndex, dropWS, false) }
        if let s = draggingWS { return (s, dropWS, true) }
        switch kbLifted {
        case .win(let id): return (wsOf(windowID: id) ?? -1, kbDropWS, false)
        case .hdr(let ws): return (ws, kbDropWS, true)
        case .none:        return nil
        }
    }

    // MARK: - Mouse: click vs drag-handle vs drag-window-row

    // A single explicit mouse-tracking loop. NSCursor changes during
    // a button-down drag are only honored from inside such a loop
    // (the normal mouseDragged path suppresses them) — this is what
    // finally makes the hand cursor appear.
    public override func mouseDown(with e: NSEvent) {
        let start = convert(e.locationInWindow, from: nil)
        guard let win = window else { return }
        let row = rows.first(where: { $0.rect.contains(start) })
        draggingWid = nil; dropWS = nil; dragLabel = nil

        var mode = 0          // 0 undecided · 1 panel-move · 2 window-drag
        var dragWS = 0
        var dragWindowID = WindowID(serverID: 0)
        var dragPID = 0
        var dragTitle = ""
        var movedFocused = false      // moved window took focus
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        loop: while let ev = win.nextEvent(matching: mask) {
            let cp = convert(ev.locationInWindow, from: nil)
            switch ev.type {
            case .leftMouseUp:
                if mode == 1 {
                    controller?.persistPosition()
                } else if mode == 2 {
                    let tgt = wsBands.first { $0.value.contains(cp.y) }?.key
                    if let tgt, tgt != dragWS {
                        // Move it, then land focus ON the moved
                        // window in its new workspace (not the app
                        // that was frontmost before).
                        let id = dragWindowID
                        let window = Window(
                            id: id, pid: dragPID, appName: "",
                            title: dragTitle, isFocused: false,
                            isFloating: false, frame: nil)
                        movedFocused = true
                        setOptimistic(windowID: id, workspaceIndex: tgt)
                        let bk = backend
                        let ctrl = controller
                        cliQueue.async {
                            bk.moveWindow(id, toWorkspaceIndex: tgt)
                            bk.switchWorkspace(toIndex: tgt)
                            Task { @MainActor in
                                ctrl?.focusWindow(window, postSwitch: true)
                            }
                        }
                    }
                } else if mode == 3 {
                    let tgt = wsBands.first { $0.value.contains(cp.y) }?.key
                    if let tgt, tgt != dragWS {
                        performSwap(sourceWS: dragWS, targetWS: tgt)
                    }
                } else if let row, row.rect.contains(cp) {
                    handleClick(row)
                }
                break loop
            case .leftMouseDragged:
                if mode == 0,
                   hypot(cp.x - start.x, cp.y - start.y) >= dragThreshold {
                    if ev.modifierFlags.contains(.command) {
                        mode = 1                       // ⌘+drag anywhere → move
                    } else {
                        switch row?.kind {
                        case .none, .handle?, .search?:
                            mode = 1                   // empty / search → move
                        case .window(let ws, let pid, let wid, let title)?:
                            mode = 2
                            dragWS = ws
                            dragWindowID = wid
                            dragPID = pid
                            dragTitle = title
                            draggingWid = (ws, wid)
                            if let rr = row?.rect,
                               let c = cells.first(where: {
                                   $0.row == rr && $0.kind == 2
                               }) {
                                dragLabel = c.title.isEmpty
                                    ? c.app : "\(c.app)  \(c.title)"
                            }
                            showChip(dragLabel ?? "")
                            lastDropWS = nil
                            prevApp = NSWorkspace.shared.frontmostApplication
                            NSApp.activate(ignoringOtherApps: true)
                        case .header(let ws)?:
                            // Theme A: header drag = swap this WS's
                            // contents with the drop-target WS. Panel
                            // move retreats to ⌘+drag / empty space.
                            mode = 3
                            dragWS = ws
                            draggingWS = ws
                            showChip(swapChipLabel(for: ws))
                            lastDropWS = nil
                        }
                    }
                }
                if mode == 1 {
                    controller?.movePanel(by: CGSize(width: ev.deltaX,
                                                     height: -ev.deltaY))
                } else if mode == 2 || mode == 3 {
                    dropWS = wsBands.first { $0.value.contains(cp.y) }?.key
                    if let t = dropWS, t != dragWS {
                        NSCursor.closedHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                    // Move just the chip layer (cheap → keeps up
                    // at speed).
                    chip.setFrameOrigin(NSPoint(
                        x: min(max(cp.x + 12, 4),
                               bounds.width - chip.frame.width - 4),
                        y: cp.y - chip.frame.height / 2))
                    // Full redraw only when the drop band changes.
                    if dropWS != lastDropWS {
                        lastDropWS = dropWS
                        needsDisplay = true
                    }
                }
            default:
                break
            }
        }

        draggingWid = nil; draggingWS = nil; dropWS = nil; dragLabel = nil
        lastDropWS = nil
        chip.isHidden = true
        NSCursor.arrow.set()
        // Restore the previously-frontmost app only when the moved
        // window did NOT take focus (cancelled drag / same-WS drop
        // / panel move).
        if let prev = prevApp {
            if !movedFocused { prev.activate() }
            prevApp = nil
        }
        needsDisplay = true
    }

    private func showChip(_ label: String) {
        chip.stringValue = label
        chip.font = uiFont(windowFontSize, .semibold)
        chip.textColor = pal.bg ?? .white
        chip.layer?.backgroundColor = pal.accent.cgColor
        chip.sizeToFit()
        let w = min(chip.frame.width + 20, bounds.width - 16)
        chip.frame = NSRect(x: chip.frame.minX, y: chip.frame.minY,
                            width: w, height: 22)
        chip.isHidden = false
    }

    // MARK: - Workspace-content swap (header drag / kb header lift)

    private func wsName(_ ws: Int) -> String {
        let w = lastWorkspaces.first { $0.index == ws }
        return (w?.name.isEmpty == false) ? w!.name : "WS\(ws + 1)"
    }

    private func swapChipLabel(for ws: Int) -> String { "⇄ \(wsName(ws))" }

    private func wsOf(windowID id: WindowID) -> Int? {
        lastWorkspaces.first { $0.windows.contains { $0.id == id } }?.index
    }

    /// Swap the entire window membership of two workspaces. The WS
    /// indices never change (hotkey mapping preserved) — only the
    /// windows inside trade places. IDs are captured up-front so the
    /// two halves don't interfere mid-flight; N+M `moveWindow` calls
    /// run on the serial backend queue, then a reconcile reflects the
    /// result. Active WS / focus are intentionally left unchanged
    /// (Theme A).
    private func performSwap(sourceWS: Int, targetWS: Int) {
        guard sourceWS != targetWS else { return }
        let srcIDs = lastWorkspaces.first { $0.index == sourceWS }?
            .windows.map(\.id) ?? []
        let dstIDs = lastWorkspaces.first { $0.index == targetWS }?
            .windows.map(\.id) ?? []
        guard !(srcIDs.isEmpty && dstIDs.isEmpty) else { return }
        let bk = backend
        cliQueue.async {
            for id in srcIDs { bk.moveWindow(id, toWorkspaceIndex: targetWS) }
            for id in dstIDs { bk.moveWindow(id, toWorkspaceIndex: sourceWS) }
        }
        controller?.scheduleReconcile(after: 0.05)
    }

    private func handleClick(_ row: TreeRow) {
        switch row.kind {
        case .handle, .search:
            break
        case .header(let i):
            // Move highlight to that workspace immediately: its
            // last-focused window, else its lowest window id (empty
            // → none). Without this the old workspace's window
            // stays selected until the next backend query, then
            // jumps.
            let tgt = lastWorkspaces.first { $0.index == i }
            let pred = tgt?.windows.predictedFocus()?.id
                ?? WindowID(serverID: -1)
            setOptimistic(windowID: pred, workspaceIndex: i)
            // Carry the kb-nav cursor with the click so the
            // outline (drawn when `kbNav` is on, which a panel
            // click enables) doesn't strand on the previously
            // selected row beside the new sel fill.
            kbSel = .hdr(workspaceIndex: i)
            let bk = backend
            // Header click = no explicit window pick. The backend's
            // `autoFocus: true` path uses the same `predictedFocus`
            // helper as fallback, so the window highlighted above
            // is the same one that ends up focused (or Finder
            // activated when the WS is empty).
            cliQueue.async {
                bk.switchWorkspace(toIndex: i, autoFocus: true)
            }
        case .window(let i, let pid, let id, let title):
            // Off main so the click never hitches; skip the switch
            // round-trip when the window is already on the active
            // workspace.
            let needSwitch = (i != activeWS)
            setOptimistic(windowID: id, workspaceIndex: i)
            // Keep the kb-nav cursor (drawn whenever `kbNav` is
            // on — a panel click flips that on passively) in sync
            // with the click target, otherwise the outline strands
            // on the previous selection beside the new sel fill.
            kbSel = .win(id)
            let window = Window(id: id, pid: pid, appName: "",
                                title: title, isFocused: false,
                                isFloating: false, frame: nil)
            let bk = backend
            let ctrl = controller
            cliQueue.async {
                if needSwitch {
                    bk.switchWorkspace(toIndex: i)
                }
                Task { @MainActor in
                    ctrl?.focusWindow(window, postSwitch: needSwitch)
                }
            }
        }
    }

    // MARK: - Keyboard navigation (facet --active)

    // Selection is tracked by logical identity (window id / empty-WS
    // index), never array position, so it survives the 2 s refresh
    // and backend events.

    // Thin wrappers around the free, testable kb-nav functions.
    private func kbSelectable() -> [Int] {
        kbSelectableIndices(rows: rows)
    }
    private func kbKey(at i: Int) -> TreeKbSel? {
        kbKeyAt(i, in: rows)
    }
    private func kbIndex(of sel: TreeKbSel) -> Int? {
        kbIndexOf(sel, in: rows)
    }

    /// Focused window, else the first selectable row.
    private func kbDefault() -> TreeKbSel? {
        if let i = cells.firstIndex(where: { $0.kind == 2 && $0.hot }),
           let k = kbKey(at: i) { return k }
        return kbSelectable().first.flatMap(kbKey(at:))
    }

    /// Re-anchor across a rebuild: keep the same logical selection
    /// if it still exists; only fall back when it's truly gone.
    private func resolveSel() {
        if let s = kbSel, kbIndex(of: s) != nil { return }
        kbSel = kbDefault()
    }

    private func selRect() -> NSRect? {
        guard let s = kbSel, let i = kbIndex(of: s) else { return nil }
        return rows[i].rect
    }

    private func scrollSelVisible() {
        guard let r = selRect() else { return }
        scrollToVisible(r.insetBy(dx: 0, dy: -windowRowH))
    }

    private func setSel(_ s: TreeKbSel?) {
        kbSel = s
        needsDisplay = true
        if s != nil { scrollSelVisible() }
        controller?.previewTargetChanged()
    }

    public func enterKbNav() {
        kbNav = true
        if kbSel == nil { kbSel = kbDefault() }
        needsDisplay = true
        scrollSelVisible()
        controller?.previewTargetChanged()
    }

    public func exitKbNav() {
        kbNav = false
        kbSel = nil
        kbLifted = nil; kbDropWS = nil
        searching = false           // restore headers / normal list next show
        query = ""
        signature = ""
        needsDisplay = true
        controller?.previewTargetChanged()
    }

    public func kbMove(_ d: Int) {
        if kbLifted != nil { kbAim(d); return }
        let ids = kbSelectable()
        let cur = kbSel.flatMap(kbIndex(of:))
        if let new = kbMoveTarget(selectable: ids, current: cur, delta: d) {
            setSel(kbKey(at: new))
        }
    }

    /// Jump to the prev/next workspace: its first window, or its
    /// header when that workspace is empty.
    public func kbJumpWS(_ dir: Int) {
        if kbLifted != nil { kbAim(dir); return }
        let curWS: Int? = {
            guard let s = kbSel, let i = kbIndex(of: s) else { return nil }
            switch rows[i].kind {
            case .header(let ws):          return ws
            case .window(let ws, _, _, _): return ws
            default:                       return nil
            }
        }()
        if let t = kbJumpTarget(rows: rows, fromWS: curWS, dir: dir) {
            setSel(t)
        }
    }

    // MARK: - Keyboard DnD (lift / aim / commit)

    public var kbIsLifting: Bool { kbLifted != nil }

    private func liftSourceWS() -> Int? {
        switch kbLifted {
        case .win(let id): return wsOf(windowID: id)
        case .hdr(let ws): return ws
        case .none:        return nil
        }
    }

    /// Space: pick up the selected row (window = move, header =
    /// WS-swap). A second Space — or Return — commits; Esc cancels.
    /// While lifted, the arrow keys (via `kbMove` / `kbJumpWS`) walk
    /// the drop target through the workspace order instead of moving
    /// the selection.
    public func kbToggleLift() {
        if kbLifted == nil {
            guard let s = kbSel else { return }
            kbLifted = s
            kbDropWS = liftSourceWS()
            needsDisplay = true
        } else {
            kbCommitLift()
        }
    }

    /// Step the drop target to the prev/next workspace.
    private func kbAim(_ delta: Int) {
        guard kbLifted != nil else { return }
        let order = kbWsOrder(rows: rows)
        guard !order.isEmpty else { return }
        let cur = kbDropWS ?? liftSourceWS() ?? order[0]
        let pos = order.firstIndex(of: cur) ?? 0
        let step = delta > 0 ? 1 : -1
        kbDropWS = order[min(max(pos + step, 0), order.count - 1)]
        if let t = kbDropWS, let band = wsBands[t] {
            scrollToVisible(NSRect(x: 0, y: band.lowerBound,
                                   width: bounds.width,
                                   height: band.upperBound - band.lowerBound))
        }
        needsDisplay = true
    }

    /// Esc while lifting: drop the lift without moving anything.
    /// Returns true if a lift was in progress (so the caller doesn't
    /// also exit keyboard mode).
    @discardableResult
    public func kbCancelLift() -> Bool {
        guard kbLifted != nil else { return false }
        kbLifted = nil; kbDropWS = nil
        needsDisplay = true
        return true
    }

    /// Commit the lift: a window moves to the target WS (mirrors the
    /// mouse drop — optimistic highlight, then move + switch +
    /// focus-follow); a header swaps its WS's contents with the
    /// target. Returns true if a lift was in progress.
    @discardableResult
    public func kbCommitLift() -> Bool {
        guard let s = kbLifted else { return false }
        let tgt = kbDropWS
        kbLifted = nil; kbDropWS = nil
        needsDisplay = true
        guard let tgt else { return true }
        switch s {
        case .win(let id):
            // Move-only: unlike the mouse drop (which switches +
            // focus-follows), a keyboard lift "files" the window into
            // the target WS and stays in --active so the user can
            // keep organizing. No switch → don't claim tgt is active
            // (so no setOptimistic, which would mislabel the active
            // WS). The reconcile relocates the row; kbSel follows it.
            guard let src = wsOf(windowID: id), src != tgt else { return true }
            let bk = backend
            cliQueue.async {
                bk.moveWindow(id, toWorkspaceIndex: tgt)
            }
            kbSel = .win(id)
            controller?.scheduleReconcile(after: 0.05)
        case .hdr(let ws):
            guard ws != tgt else { return true }
            performSwap(sourceWS: ws, targetWS: tgt)
        }
        return true
    }

    /// `m` in --active: open the selected row's context menu — the
    /// same menu right-click shows (window actions / workspace
    /// layout), anchored at that row. (Space is the lift gesture in
    /// Theme A.) facet stays --active; pick with the mouse or Esc.
    public func kbContextMenu() {
        guard let s = kbSel, let i = kbIndex(of: s),
              let win = window else { return }
        let r = rows[i].rect
        let scr = win.convertPoint(toScreen:
            convert(NSPoint(x: r.minX + 24, y: r.minY), to: nil))
        switch rows[i].kind {
        case .header(let ws):
            showLayoutMenu(at: scr, workspaceIndex: ws)
        case .window(let ws, let pid, let id, let title):
            showWindowMenu(at: scr, workspaceIndex: ws,
                           pid: pid, windowID: id, title: title)
        default:
            break
        }
    }

    /// Enter: act on the selected row exactly like a click, then
    /// leave keyboard mode (focus follows via assertFocus, so we
    /// don't restore the previously-frontmost app here).
    public func kbActivate() {
        guard let s = kbSel, let i = kbIndex(of: s) else { return }
        let row = rows[i]
        // Leave keyboard mode FIRST so we act exactly like a mouse
        // click (facet no longer the active app). Otherwise,
        // switching to an empty workspace then dropping .regular
        // lets the prior app re-activate and yank the WM back.
        controller?.exitActive(restore: false)
        handleClick(row)
    }

    // MARK: - Right-click menus

    // Right-click: WS header → pick layout engine; window row →
    // window actions.
    public override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let row = rows.first(where: { $0.rect.contains(p) }),
              let win = window else { return }
        let scr = win.convertPoint(toScreen: e.locationInWindow)
        switch row.kind {
        case .header(let ws):
            showLayoutMenu(at: scr, workspaceIndex: ws)
        case .window(let ws, let pid, let id, let title):
            showWindowMenu(at: scr, workspaceIndex: ws,
                           pid: pid, windowID: id, title: title)
        default:
            break
        }
    }

    private func showLayoutMenu(at scr: NSPoint, workspaceIndex ws: Int) {
        let modes = backend.layoutModes
        let cur = (lastWorkspaces.first { $0.index == ws })?.layoutMode
        let idx = modes.firstIndex(of: cur ?? "")
        let bk = backend
        PopupMenu.shared.show(at: scr,
                              header: "WS\(ws + 1) layout",
                              items: modes,
                              checkedIndex: idx) { i in
            let mode = modes[i]
            cliQueue.async {
                bk.setLayoutMode(workspaceIndex: ws, mode: mode)
            }
        }
    }

    private func showWindowMenu(at scr: NSPoint,
                                workspaceIndex ws: Int,
                                pid: Int,
                                windowID id: WindowID,
                                title: String) {
        let wsModel = lastWorkspaces.first { $0.index == ws }
        let mode = wsModel?.layoutMode ?? ""
        let win = wsModel?.windows.first { $0.id == id }
        let floating = win?.isFloating ?? false
        let isMaster = win?.isMaster ?? false
        // Non-floating tiled members — what stack cycling rotates over.
        let windowCount = wsModel?.windows.filter { !$0.isFloating }.count ?? 0
        let menu = backend.windowMenu(mode: mode, floating: floating,
                                      isMaster: isMaster,
                                      windowCount: windowCount)
        let bk = backend
        let ctrl = controller
        PopupMenu.shared.show(at: scr,
                              header: "Window",
                              items: menu.map(\.label),
                              checkedIndex: nil) { i in
            let item = menu[i]
            if item.isClose {
                cliQueue.async { bk.closeWindow(id) }
            } else {
                let window = Window(id: id, pid: pid, appName: "",
                                    title: title, isFocused: false,
                                    isFloating: floating, frame: nil)
                ctrl?.runWindowOps(item.ops, on: window,
                                   workspaceIndex: ws)
            }
        }
    }
}
