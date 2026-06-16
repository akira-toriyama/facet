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

    /// Per-surface palette (PR-B). The Controller wires the tree box at
    /// construction; `pal` reads route through it — the tree panel's own
    /// `[tree].theme`.
    public var paletteBox: PaletteBox!
    var pal: ResolvedPalette { paletteBox.pal }

    public weak var controller: TreeController?
    let backend: any WindowBackend

    public init(frame: NSRect, backend: any WindowBackend) {
        self.backend = backend
        super.init(frame: frame)
    }
    public required init?(coder: NSCoder) { nil }

    // MARK: - Visual state

    var rows: [TreeRow] = []
    struct Cell {
        let row: NSRect
        let kind: Int          // 0 handle · 1 header · 2 window
        let hot: Bool
        let firstHeader: Bool
        let pid: Int
        let app: String
        let title: String
        let text: String       // handle / header label
        let mode: String       // header: WS layout engine
        let isMaster: Bool     // window: shows a `master` status line
        let isFloating: Bool   // window: shows a `float` status line
        let isSticky: Bool     // window: shows a slanted "sticky" badge
        let mark: String?      // window: user mark → right-edge badge
        let isHidden: Bool     // window: Cmd+H/Cmd+M'd → dim + hidden badge
        let scratchpad: String?  // window: settled shelf → `scratchpad:NAME`
        let tags: [String]       // window: tag names → `#tag` chips (flat tag mode)
    }
    var cells: [Cell] = []
    var hoverIdx: Int?            // row under the pointer

    // Keyboard-nav mode (entered via `facet --active`).
    public internal(set) var kbNav = false
    var kbSel: TreeKbSel?

    // Type-to-filter sub-mode (entered with `s` while in --active).
    // When on, headers drop out; only fuzzy-matching window rows
    // are listed (cross-workspace flat list).
    public internal(set) var searching = false
    public internal(set) var query = ""

    /// Tag mode (`[grouping] by = "tag"`): the snapshot is ONE synthetic
    /// flat workspace, so the tree drops the workspace header — the list
    /// reads as a flat window list with `#tag` chips per row — and
    /// disables the workspace-targeting DnD (window-move / header-swap),
    /// since a flat list has nowhere to drop. Set by `update(tagMode:)`
    /// and sticky across the internal relayouts that omit the arg. (#191
    /// PR-6.)
    var tagModeActive = false

    var wsBands: [Int: ClosedRange<CGFloat>] = [:]
    public internal(set) var signature = ""
    public private(set) var contentHeight: CGFloat = 40
    /// Natural content width (widest row's untruncated text, floored at
    /// the clip width). PanelHost sizes the documentView to this so the
    /// panel scrolls horizontally to read overflowing titles (B). Set by
    /// `update`; read through PanelHost's layout.
    public private(set) var contentWidth: CGFloat = sidebarWidth

    /// While true, `draw` renders placeholder rows and `update`
    /// holds (incoming refreshes don't replace the skeleton). Driven
    /// by the CLI `facet --view tree --loading MS`: an external
    /// tool (e.g. chord) shows the skeleton just BEFORE triggering a
    /// mac-desktop switch, so the shared panel never flashes the
    /// previous mac desktop's tree. The Controller clears it on a timer.
    /// Memory: facet-per-native-space-ws.
    var skeleton = false
    /// Content signature at the moment the skeleton was shown. While
    /// skeleton is up, an `update` whose signature still equals this
    /// is the SAME (pre-switch) content → keep holding; a different
    /// signature means new content loaded → drop the skeleton early.
    var skeletonBaseSig = ""
    public private(set) var activeWS: Int?    // REAL active WS (skip-switch)

    // Optimistic selection: on click we move the highlight
    // immediately and hold briefly; the next real query reconciles
    // (reverts if the backend's focus actually failed).
    var lastWorkspaces: [Workspace] = []
    // Mac desktop ordinal (Mission Control order) for the
    // top handle band's "Desktop N" label. nil = SkyLight
    // unavailable / single-desktop → band shows no name. Preserved
    // across internal relayouts (update's `macDesktop` arg is a
    // double-optional: omitted = keep current).
    var macDesktopOrdinal: Int?
    /// The mac-desktop ordinal currently shown ("Desktop N"). Read by
    /// PanelHost to label the pinned `HandleBar`. nil when SkyLight is
    /// unavailable.
    public var shownMacDesktopOrdinal: Int? { macDesktopOrdinal }
    // AX-resolved titles for windows the backend left blank; kept
    // across internal relayouts that don't re-resolve.
    var titleOverride: [WindowID: String] = [:]
    var optWindowID: WindowID?
    var optActiveWS: Int?
    var optUntil: Date?

    // Drag state (driven by the explicit tracking loop in
    // mouseDown).
    var draggingWid: (workspaceIndex: Int, windowID: WindowID)?
    var dropWS: Int?
    var dragLabel: String?
    var lastDropWS: Int?           // redraw band only when this changes
    // Header-swap drag: source WS while a workspace header is being
    // dragged onto another (mouseDown loop `mode == 3`). Parallel to
    // `draggingWid`; drop trades the two workspaces' contents.
    var draggingWS: Int?
    // Keyboard DnD: the row lifted with Space (window = move, header
    // = WS-swap). `kbDropWS` is the current aim target; arrows walk
    // it through the workspace order, Return/Space commits, Esc
    // cancels. nil = not lifting. Theme A: target carries the
    // move/swap semantics — no modifier keys.
    var kbLifted: TreeKbSel?
    var kbDropWS: Int?
    lazy var chip: NSTextField = {
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
    /// Richer drag ghost (⑨): a snapshot "card" of the lifted row(s) —
    /// the dragged WS's header + its windows, or a single window row.
    /// Shown in a borderless FLOATING WINDOW (`dragCardWindow`) so it can
    /// extend BEYOND the narrow tree panel — a subview would be clipped to
    /// the panel. `dragCard` is the window's (padded) content; the pad
    /// gives the lean (tilt) room so it doesn't clip at the window edge.
    /// Falls back to the in-panel text chip if the snapshot fails.
    lazy var dragCard: NSImageView = {
        let v = NSImageView()
        v.wantsLayer = true
        v.imageScaling = .scaleNone
        v.layer?.masksToBounds = false       // don't clip the tilt
        v.layer?.borderWidth = 2
        return v
    }()
    let dragCardPad: CGFloat = 26     // room for the tilt's corners
    lazy var dragCardWindow: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless,
                         backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true           // never blocks the drag tracking
        w.level = .popUpMenu
        w.collectionBehavior = [.transient, .ignoresCycle]
        let container = NSView()
        container.wantsLayer = true
        container.addSubview(dragCard)
        w.contentView = container
        return w
    }()
    var cardShown = false
    var prevApp: NSRunningApplication?   // re-activate post-drag
    /// Current lean of the drag card (⑨); eased per move by
    /// `tiltDragGhost` (SidebarView+Drag). Stored here — extensions
    /// can't hold stored properties.
    var dragTilt: CGFloat = 0

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
        // flicker to the backend's transient default focus before our
        // re-assert wins.
        optUntil = Date().addingTimeInterval(0.85)
        update(lastWorkspaces)            // rebuild now with the override
        controller?.scheduleReconcile(after: 0.9)
    }

    // MARK: - Update / layout

    @discardableResult
    public func update(_ workspaces: [Workspace],
                       titles: [WindowID: String]? = nil,
                       macDesktop: Int?? = nil,
                       tagMode: Bool? = nil) -> CGFloat {
        lastWorkspaces = workspaces
        if let titles { titleOverride = titles }
        // Double-optional: omitting the arg (internal relayouts) keeps
        // the current ordinal; passing it (the Controller refresh)
        // sets it — including to nil when SkyLight is unavailable.
        if let macDesktop { macDesktopOrdinal = macDesktop }
        // Sticky like `macDesktop`: only the Controller refresh passes
        // `tagMode`; internal relayouts (omit it) keep the current value.
        if let tagMode { tagModeActive = tagMode }
        activeWS = workspaces.first(where: { $0.isActive })?.index   // always REAL
        let opt = optimisticHeld()
        // Read `ws.isActive` (not a single active index): workspace mode
        // has one active WS, and tag mode emits a single always-active
        // synthetic workspace (no header is rendered for it — see the
        // `tagModeActive` gate below). The optimistic overlay (kbNav /
        // `--active` mid-switch) is workspace-mode only — a single
        // transient target.
        func headerActive(_ ws: Workspace) -> Bool {
            opt ? (ws.index == optActiveWS) : ws.isActive
        }
        func hot(_ win: Window) -> Bool {
            opt ? (win.id == optWindowID) : win.isFocused
        }
        // Backend's title, or our AX-resolved one when blank.
        func eff(_ win: Window) -> String {
            win.title.isEmpty
                ? (titleOverride[win.id] ?? "") : win.title
        }
        let sig = (searching ? "S:\(query);" : "")
            + (tagModeActive ? "T;" : "")
            + "D\(macDesktopOrdinal ?? -1);"
            + (opt
                ? "O\(optWindowID?.serverID ?? -1):\(optActiveWS ?? -1);"
                : "R;")
            + workspaces.map { ws in
                "\(ws.index)\(headerActive(ws) ? "*" : "")\(ws.layoutMode)|"
                + ws.windows.map {
                    "\($0.id.serverID)\(hot($0) ? "f" : "")\($0.isOnscreen ? "" : "h"):\(eff($0))"
                }.joined(separator: ",")
            }.joined(separator: ";")
        // Loading skeleton: hold while content is UNCHANGED from when
        // `--loading` fired (e.g. a refresh mid mac-desktop switch
        // still returns the previous mac desktop), but clear the instant
        // genuinely new content arrives (the new mac desktop finished
        // loading). The Controller's timer is only an upper bound.
        if skeleton {
            if sig == skeletonBaseSig { return skeletonHeight }
            skeleton = false
            Log.debug("tree: skeleton cleared (new content loaded)")
        }
        if sig == signature { return contentHeight }
        signature = sig
        rows.removeAll(); cells.removeAll(); wsBands.removeAll()

        // Resolve which windows each workspace shows (search filters by
        // window; a zero-match workspace drops out — see #202). Reused for
        // both the width pre-pass and the row build below.
        let shown: [(ws: Workspace, wins: [Window])] = workspaces.compactMap { ws in
            let wins = searching
                ? ws.windows.filter { fuzzyMatch(query, $0.appName + " " + eff($0)) }
                : ws.windows
            if searching && wins.isEmpty { return nil }
            return (ws, wins)
        }

        // Horizontal content width = the widest row's NATURAL (untruncated)
        // text width, floored at the visible clip width. Titles draw at
        // full width and the panel scrolls sideways to read overflow (B);
        // nothing is tail-truncated. Measured up front because every row
        // rect — and thus hit-testing — is built at this width.
        let clipW = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let txWin = rowPadX + 2 + iconSize + 8
        let gripSpace = headerGripW + 6
        var naturalW = sidebarWidth
        for (ws, wins) in shown {
            // Tag mode keeps the `#web` lens label as-is; workspace mode
            // uppercases the WS name (matches the header draw at the Cell).
            let baseNm = ws.name.isEmpty ? "WS\(ws.index + 1)" : ws.name
            let nm = tagModeActive ? baseNm : baseNm.uppercased()
            // One tag glyph per tag name (~14pt + gaps); "All tags" = 1 glyph.
            let tagCount = !tagModeActive ? 0
                : (nm == "All tags" ? 1 : max(1, nm.split(separator: " ").count))
            // Measure at the HEAVIEST draw weight (active = .bold name /
            // .semibold layout) so the natural width is a safe upper bound —
            // it must never be narrower than the drawn text or the
            // horizontal scroll clips. Sizes are the constants the draw uses.
            let nameW = (nm as NSString).size(
                withAttributes: [.font: uiFont(headerFontSize, .bold)]).width
                + CGFloat(tagCount) * 22
            let modeW = ws.layoutMode.isEmpty ? 0
                : (layoutBadgeLabel(ws.layoutMode) as NSString).size(
                    withAttributes: [.font: uiFont(subheadFontSize, .semibold)]).width
                    // leading layout icon (~13pt + 5 gap) when one exists
                    + (layoutModeIcon(ws.layoutMode).isEmpty ? 0 : 19)
            naturalW = max(naturalW,
                           rowPadX + gripSpace + ceil(max(nameW, modeW)) + rowPadX)
            for win in wins {
                let appW = (win.appName as NSString).size(
                    withAttributes: [.font: uiFont(windowFontSize, .semibold)]).width
                let tt = eff(win)
                let titleW = tt.isEmpty ? 0
                    : (tt as NSString).size(
                        withAttributes: [.font: uiFont(windowTitleFontSize, .semibold)]).width
                naturalW = max(naturalW, txWin + ceil(max(appW, titleW)) + rowPadX)
            }
        }
        let w = max(clipW, naturalW)
        var y: CGFloat = 6        // small top inset

        // Append one window row (TreeRow + Cell) and advance `y`. Shared
        // by the search (flat cross-WS) and normal (per-WS) passes — the
        // row-height ladder + the 13 Cell fields were an identical block
        // in both. Nested so it captures `eff` / `hot` / `w` / `y`.
        func appendWindowRow(_ win: Window, wsIndex: Int) {
            let wt = eff(win)
            let hasLabel = win.isMaster || win.isFloating
            let baseRH = wt.isEmpty ? windowRowH : windowRowTallH
            // Third line under the title holds the mark pill (left) and
            // the master / float / hidden / scratchpad / tag-chip badges —
            // present when any of those conditions holds. In tag mode the
            // chips are EVERY tag the window carries (flat list — no
            // primary tag is hidden under a header); workspace mode leaves
            // `tags` empty, so this is `false` there.
            let hasThird = hasLabel || (win.mark != nil)
                || !win.isOnscreen || (win.scratchpad != nil)
                || !win.tags.isEmpty
            var rh: CGFloat = baseRH           // compact single line
            if !wt.isEmpty || hasThird {
                rh = 34                        // top 8 + app 18 + bot 8
                if !wt.isEmpty { rh += 20 }    // gap 4 + title 16
                if hasThird { rh += 24 }       // gap 2 + badge 22
            }
            let wr = NSRect(x: 0, y: y, width: w, height: rh)
            rows.append(TreeRow(rect: wr, kind: .window(
                workspaceIndex: wsIndex, pid: win.pid,
                windowID: win.id, title: wt)))
            cells.append(Cell(row: wr, kind: 2, hot: hot(win),
                              firstHeader: false, pid: win.pid,
                              app: win.appName, title: wt,
                              text: "", mode: "",
                              isMaster: win.isMaster,
                              isFloating: win.isFloating,
                              isSticky: win.isSticky,
                              mark: win.mark,
                              isHidden: !win.isOnscreen,
                              scratchpad: win.scratchpad,
                              tags: win.tags))
            y += rh
        }

        // The "Desktop N" grab band is no longer a scrolling row — it's
        // pinned at the panel top by PanelHost's `HandleBar`, so a long
        // workspace list never scrolls the panel-move handle off-screen
        // (its label comes from `shownMacDesktopOrdinal`).

        // One grouped pass for BOTH modes: every workspace emits its
        // header + window rows. In search mode the windows are filtered
        // by the query (the WS name itself is NOT searched) and a
        // workspace with zero matches is skipped — so the headers stay
        // (you keep your bearings) while results stay tight. Non-search
        // keeps every workspace + window (an empty WS still shows its
        // header, unchanged). Previously search was a flat, header-less
        // cross-WS list; keeping the grouping is the only behavioural
        // change.
        var firstHeader = true
        for (ws, wins) in shown {
            let start = y
            // Section header. Workspace mode: one per workspace ("WS N" /
            // name) — click switches, right-click / `m` picks the layout.
            // Tag mode: ONE tag-world header — `ws.name` is the active lens
            // label (the shown tags, else `all`); the per-row `#tag` chips
            // still carry the grouping. Click is a no-op (one tag-world);
            // right-click / `m` picks the tag-world's single global layout.
            // (Tag mode was header-less before the layout-picker UI landed.)
            let hh = firstHeader ? headerFirstRowH : headerRowH
            let hr = NSRect(x: 0, y: y, width: w, height: hh)
            rows.append(TreeRow(rect: hr,
                                kind: .header(workspaceIndex: ws.index)))
            let t = ws.name.isEmpty ? "WS\(ws.index + 1)" : ws.name
            cells.append(Cell(row: hr, kind: 1, hot: headerActive(ws),
                              firstHeader: firstHeader, pid: 0, app: "",
                              title: "", text: tagModeActive ? t : t.uppercased(),
                              mode: ws.layoutMode,
                              isMaster: false, isFloating: false,
                              isSticky: false, mark: nil, isHidden: false,
                              scratchpad: nil, tags: []))
            firstHeader = false
            y += hh
            for win in wins {
                appendWindowRow(win, wsIndex: ws.index)
            }
            wsBands[ws.index] = start...(y + 3)
            y += 3
        }
        contentHeight = y + 6
        contentWidth = w
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
    /// active app (i.e. `--active`). In passive `--view tree` the
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
    ///
    /// Tag mode (#191 PR-6): the snapshot is ONE always-active synthetic
    /// workspace, so this skip suppresses hover previews for every row.
    /// That's correct for in-lens (on-screen) windows, but also drops the
    /// preview for parked (out-of-lens) windows — restoring those would
    /// need per-window lens membership plumbed to the view, deferred as a
    /// follow-up rather than threaded through the flat-render change.
    public func previewTargets()
        -> [(window: WindowID, rowAnchor: NSRect, windowFrame: CGRect?)]
    {
        enum T { case win(WindowID); case ws(Int) }
        var t: T?
        // Hover wins when the pointer is over a previewable row — this is
        // what makes hover previews work in `--active` (kbNav) mode too,
        // not just plain mode (previously kbNav short-circuited to kbSel
        // and ignored hover entirely). Keyboard nav clears `hoverIdx`
        // (see setSel), so an arrow key hands the preview to the keyboard
        // selection and the next mouseMoved hands it back to hover —
        // "most recent input wins".
        if let h = hoverIdx, rows.indices.contains(h) {
            switch rows[h].kind {
            case .window(_, _, let id, _):      t = .win(id)
            case .header(let w):                t = .ws(w)
            default:                            break
            }
        }
        if t == nil, kbNav, let s = kbSel {
            switch s {
            case .win(let id):                  t = .win(id)
            case .hdr(let w):                   t = .ws(w)
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

}
