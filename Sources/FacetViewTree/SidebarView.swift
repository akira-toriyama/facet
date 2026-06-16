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
        let isMaster: Bool     // window: shows a `master` status line
        let isFloating: Bool   // window: shows a `float` status line
        let isSticky: Bool     // window: shows a slanted "sticky" badge
        let mark: String?      // window: user mark → right-edge badge
        let isHidden: Bool     // window: Cmd+H/Cmd+M'd → dim + hidden badge
        let scratchpad: String?  // window: settled shelf → `scratchpad:NAME`
        let tags: [String]       // window: tag names → `#tag` chips (flat tag mode)
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

    /// Tag mode (`[grouping] by = "tag"`): the snapshot is ONE synthetic
    /// flat workspace, so the tree drops the workspace header — the list
    /// reads as a flat window list with `#tag` chips per row — and
    /// disables the workspace-targeting DnD (window-move / header-swap),
    /// since a flat list has nowhere to drop. Set by `update(tagMode:)`
    /// and sticky across the internal relayouts that omit the arg. (#191
    /// PR-6.)
    private var tagModeActive = false

    private var wsBands: [Int: ClosedRange<CGFloat>] = [:]
    public private(set) var signature = ""
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
    private var skeleton = false
    /// Content signature at the moment the skeleton was shown. While
    /// skeleton is up, an `update` whose signature still equals this
    /// is the SAME (pre-switch) content → keep holding; a different
    /// signature means new content loaded → drop the skeleton early.
    private var skeletonBaseSig = ""
    public private(set) var activeWS: Int?    // REAL active WS (skip-switch)

    // Optimistic selection: on click we move the highlight
    // immediately and hold briefly; the next real query reconciles
    // (reverts if the backend's focus actually failed).
    private var lastWorkspaces: [Workspace] = []
    // Mac desktop ordinal (Mission Control order) for the
    // top handle band's "Desktop N" label. nil = SkyLight
    // unavailable / single-desktop → band shows no name. Preserved
    // across internal relayouts (update's `macDesktop` arg is a
    // double-optional: omitted = keep current).
    private var macDesktopOrdinal: Int?
    /// The mac-desktop ordinal currently shown ("Desktop N"). Read by
    /// PanelHost to label the pinned `HandleBar`. nil when SkyLight is
    /// unavailable.
    public var shownMacDesktopOrdinal: Int? { macDesktopOrdinal }
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
    /// Richer drag ghost (⑨): a snapshot "card" of the lifted row(s) —
    /// the dragged WS's header + its windows, or a single window row.
    /// Shown in a borderless FLOATING WINDOW (`dragCardWindow`) so it can
    /// extend BEYOND the narrow tree panel — a subview would be clipped to
    /// the panel. `dragCard` is the window's (padded) content; the pad
    /// gives the lean (tilt) room so it doesn't clip at the window edge.
    /// Falls back to the in-panel text chip if the snapshot fails.
    private lazy var dragCard: NSImageView = {
        let v = NSImageView()
        v.wantsLayer = true
        v.imageScaling = .scaleNone
        v.layer?.masksToBounds = false       // don't clip the tilt
        v.layer?.borderWidth = 2
        return v
    }()
    private let dragCardPad: CGFloat = 26     // room for the tilt's corners
    private lazy var dragCardWindow: NSWindow = {
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
    private var cardShown = false
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
            let nameW = (nm as NSString).size(
                withAttributes: [.font: uiFont(activeHeaderFontSize, .bold)]).width
                + CGFloat(tagCount) * 22
            let modeW = ws.layoutMode.isEmpty ? 0
                : (layoutBadgeLabel(ws.layoutMode) as NSString).size(
                    withAttributes: [.font: uiFont(activeHeaderFontSize, .bold)]).width
                    // leading layout icon (~14pt + 5 gap) when one exists
                    + (layoutModeIcon(ws.layoutMode).isEmpty ? 0 : 19)
            naturalW = max(naturalW,
                           rowPadX + gripSpace + ceil(max(nameW, modeW)) + rowPadX)
            for win in wins {
                let appW = (win.appName as NSString).size(
                    withAttributes: [.font: uiFont(windowFontSize, .semibold)]).width
                let tt = eff(win)
                let titleW = tt.isEmpty ? 0
                    : (tt as NSString).size(
                        withAttributes: [.font: uiFont(windowFontSize - 1, .semibold)]).width
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

    // MARK: - Draw

    /// Loading placeholder shown via `facet --view tree --loading`.
    /// Mirrors the real layout's rhythm (caption + two window rows
    /// per section) with muted, theme-aware rounded bars.
    private func drawSkeleton() {
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                 _ alpha: CGFloat, _ radius: CGFloat = 4.5) {
            pal.muted.withAlphaComponent(alpha).setFill()
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
    /// mac desktop name band). The tree stays at 2×8 (vs the grid's 3×10)
    /// because the sidebar is narrow — a wider strip would crowd the
    /// WS name column.
    private func drawGrip(in r: NSRect, hot: Bool) {
        // The sidebar is narrow, so the tree uses a shorter tall strip
        // (±14 vs the grid / rail's ±18) — see `drawGripDots`.
        drawGripDots(in: r, tallExtent: 14,
                     color: hot ? pal.primary : pal.muted,
                     alpha: hot ? 0.85 : 0.45)
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
                pal.primary.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                pal.primary.setStroke()
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
                pal.primary.withAlphaComponent(0.7).setStroke()
                let o = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
                o.lineWidth = 1.5
                o.setLineDash([4, 3], count: 2, phase: 0)
                o.stroke()
            }
        }
        let para = NSMutableParagraphStyle()
        // No tail-truncation (no "…"): rows are laid out at the natural
        // content width (see update's pre-pass) and the panel scrolls
        // horizontally to read overflow (B). Clip rather than ellipsize so
        // a sub-pixel measurement gap never reintroduces "…".
        para.lineBreakMode = .byClipping

        let kbSelRow = kbNav ? kbSel.flatMap(kbIndex(of:)) : nil
        var winOrdinal = 0   // window-row counter for the zebra stripe
        for (i, c) in cells.enumerated() {
            let row = c.row
            switch c.kind {
            case 1:   // workspace section header — 2-line caption
                if !c.firstHeader {
                    pal.border.setStroke()
                    let sep = NSBezierPath()
                    let sy = row.minY + 9           // tighter gap above
                    sep.move(to: NSPoint(x: rowPadX, y: sy))
                    sep.line(to: NSPoint(x: bounds.width - rowPadX, y: sy))
                    sep.lineWidth = 1
                    sep.stroke()
                }
                let hp = NSMutableParagraphStyle()
                hp.lineBreakMode = .byClipping     // no "…" — see `para` (B)
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
                // Line 1: WS name / lens label (accent when active). In tag
                // mode this is the lens (a tag concept) → `secondary` to
                // match the tag colour scheme (item 14/17); workspace names
                // stay `primary`. Line 2 (layout) is `primary` either way, so
                // the two lines never collide on the same accent.
                let nameH: CGFloat = 18
                let nameColor = c.hot
                    ? (tagModeActive ? pal.secondary : pal.primary)
                    : pal.muted
                let nameX0 = rowPadX + gripSpace
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: uiFont(fs, .bold), .foregroundColor: nameColor,
                    .kern: 0.6, .paragraphStyle: hp]
                if tagModeActive {
                    // Tag mode: a `tag` glyph PER tag name (2+ tags each get
                    // their own icon), so "web chat" → 🏷 web 🏷 chat. The
                    // "All tags" show-everything label is a single status
                    // word → one leading glyph. (Tag names carry no spaces,
                    // so the adapter's space-join splits cleanly.)
                    let tags = c.text == "All tags"
                        ? [c.text]
                        : c.text.split(separator: " ").map(String.init)
                    let rightEdge = bounds.width - rowPadX
                    var x = nameX0
                    for tag in tags where x < rightEdge {
                        if let tagIcon = IconResolver.resolve(
                            "SF:tag", pointSize: 13, color: nameColor,
                            scale: .medium) {
                            let ih = min(tagIcon.size.height, 14)
                            let iw = tagIcon.size.width
                                * (ih / max(tagIcon.size.height, 1))
                            tagIcon.draw(in: NSRect(
                                x: x, y: capY + (nameH - ih) / 2,
                                width: iw, height: ih))
                            x += iw + 4
                        }
                        let tw = ceil((tag as NSString)
                            .size(withAttributes: nameAttrs).width)
                        (tag as NSString).draw(
                            in: NSRect(x: x, y: capY,
                                       width: min(tw, rightEdge - x), height: nameH),
                            withAttributes: nameAttrs)
                        x += tw + 10        // gap before the next tag's glyph
                    }
                } else {
                    (c.text as NSString).draw(
                        in: NSRect(x: nameX0, y: capY,
                                   width: bounds.width - rowPadX - nameX0,
                                   height: nameH),
                        withAttributes: nameAttrs)
                }
                // Line 2: layout-mode text — secondary semibold on the
                // active WS, `pal.muted` semibold when the WS isn't
                // active so non-focused rows recede. No pill
                // background (the WS name on line 1 carries enough
                // visual weight for the group); the color + weight
                // step alone separates the badge from body text.
                // the secondary accent is the palette's second hue
                // (terminal=amber, dracula=pink, system=systemPurple),
                // reserved for status badges so the text never
                // collides with the primary accent used by the
                // active WS-name on line 1.
                if !c.mode.isEmpty {
                    // Layout mode: a leading SF icon (item 7 — the tree is
                    // text-heavy, so the glyph lets the layout register at a
                    // glance) + the abbreviated label. Plain, no fill — same
                    // weight (bold) as the WS name above it so the two-line
                    // caption reads as one unit. `primary` on the active WS
                    // (item 10: layout = primary accent), dim when inactive
                    // so non-focused rows recede.
                    let modeColor = c.hot ? pal.primary : pal.muted
                    let mx = rowPadX + gripSpace
                    let modeY = capY + nameH + 4
                    var modeTextX = mx
                    let modeIconSpec = layoutModeIcon(c.mode)
                    // Explicit ~14pt glyph (not the menu's `.large`): the
                    // header line is only 18pt tall, so the icon is sized to
                    // sit centred with ≥2pt clearance from the kbNav outline
                    // and the line above (fixes the reported icon↔border
                    // overlap). Height-clamped so a stray large render can't
                    // bleed past the line.
                    if !modeIconSpec.isEmpty,
                       let icon = IconResolver.resolve(
                        modeIconSpec, pointSize: 13, color: modeColor,
                        scale: .medium) {
                        let ih = min(icon.size.height, 14)
                        let iw = icon.size.width * (ih / max(icon.size.height, 1))
                        icon.draw(in: NSRect(
                            x: mx, y: modeY + (18 - ih) / 2,
                            width: iw, height: ih))
                        modeTextX = mx + iw + 5
                    }
                    (layoutBadgeLabel(c.mode) as NSString).draw(
                        in: NSRect(x: modeTextX, y: modeY,
                                   width: bounds.width - rowPadX - modeTextX,
                                   height: 18),
                        withAttributes: [
                            .font: uiFont(fs, .bold),
                            .foregroundColor: modeColor,
                            .paragraphStyle: hp,
                        ])
                }

            default:  // window row
                let sel = c.hot
                let hov = (hoverIdx == i)
                let pill = row.insetBy(dx: 6, dy: 2)
                // Zebra stripe: nudge every other window row toward the
                // text color — slightly lighter on dark themes, darker
                // on light ones (theme-independent). A faint base layer
                // under any selection / hover fill.
                if winOrdinal % 2 == 1 {
                    pal.foreground.withAlphaComponent(0.05).setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                        .fill()
                }
                winOrdinal += 1
                if sel {
                    pal.selection.setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                        .fill()
                    pal.primary.setFill()
                    NSBezierPath(roundedRect: NSRect(
                        x: pill.minX, y: pill.minY + 3,
                        width: 3, height: pill.height - 6),
                        xRadius: 1.5, yRadius: 1.5).fill()
                } else if hov {
                    pal.hover.setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 7, yRadius: 7)
                        .fill()
                }
                let iconX = rowPadX + 2
                // Sticky renders as its own "sticky" badge in the block
                // below, so suppress the plain `float` label here
                // (sticky ⇒ floating; a master window can't be sticky).
                // A settled scratchpad window is force-floating, but it
                // shows its own `scratchpad:NAME` badge below instead of
                // the plain `float` label (like the sticky pill).
                let labelText: String? =
                    c.isMaster ? "master" :
                    c.isSticky ? nil :
                    c.scratchpad != nil ? nil :
                    c.isFloating ? "float" : nil
                let hasLabel = labelText != nil
                let hasTitle = !c.title.isEmpty
                let hasMark = c.mark != nil
                let hasScratch = c.scratchpad != nil
                let hasTags = !c.tags.isEmpty
                let tx = iconX + iconSize + 8
                let tw = max(bounds.width - tx - rowPadX, 0)
                // Vertical rhythm (matches the row-height calc): top pad
                // 8, app, +4 gap, title, +6 gap, third (mark / status)
                // line. App centres only on a bare single-line row.
                let appY = (hasTitle || hasLabel || hasMark
                            || c.isSticky || hasScratch || hasTags)
                    ? row.minY + 8 : row.midY - 9
                let titleY = row.minY + 28        // tucked up under the app
                // Icon centres on the whole row so it stays vertically
                // centred even when a third line (mark / master / float)
                // grows the row — without it the icon rides up to the
                // identity block and reads as top-aligned.
                let iconY = (row.midY - iconSize / 2).rounded()
                if let img = AppIcons.icon(forPID: c.pid) {
                    img.draw(in: NSRect(x: iconX, y: iconY,
                                        width: iconSize, height: iconSize))
                }
                (c.app as NSString).draw(
                    in: NSRect(x: tx, y: appY, width: tw, height: 18),
                    withAttributes: [
                        .font: uiFont(windowFontSize,
                                      sel ? .semibold : .medium),
                        // Dim a hidden (Cmd+H/Cmd+M'd) row, but keep a
                        // selected row at full strength so the highlight
                        // stays legible.
                        .foregroundColor: (sel ? pal.primary : pal.foreground)
                            .withAlphaComponent(c.isHidden && !sel ? 0.45 : 1.0),
                        .paragraphStyle: para,
                    ])
                if hasTitle {
                    (c.title as NSString).draw(
                        in: NSRect(x: tx, y: titleY,
                                   width: tw, height: 15),
                        withAttributes: [
                            .font: uiFont(windowFontSize - 1, .semibold),
                            .foregroundColor: pal.foreground.withAlphaComponent(
                                c.isHidden && !sel ? 0.45 : 1.0),
                            .paragraphStyle: para,
                        ])
                }
                // Third line: the mark pill (left), then the "sticky"
                // badge or the `scratchpad:NAME` shelf pill, then the
                // master / float / hidden label.
                if hasLabel || hasMark || c.isSticky || c.isHidden
                    || hasScratch || hasTags {
                    // Wider gap below the title before the mark / status.
                    let labelY = hasTitle ? row.minY + 51 : row.minY + 32
                    var lx = tx
                    if let mark = c.mark {
                        let markFont = uiFont(windowFontSize, .bold)
                        let maxTextW: CGFloat = 60   // long → tail-truncate
                        let textW = min(maxTextW, ceil((mark as NSString)
                            .size(withAttributes: [.font: markFont]).width))
                        let padX: CGFloat = 8
                        let pillH: CGFloat = 22   // inner padding around text
                        let pillW = textW + padX * 2
                        let pillRect = NSRect(x: lx, y: labelY - 1,
                                              width: pillW, height: pillH)
                        let markStroke = NSBezierPath(
                            roundedRect: pillRect.insetBy(dx: 0.5, dy: 0.5),
                            xRadius: 5, yRadius: 5)   // rounded rect, not capsule
                        markStroke.lineWidth = 1
                        // Mark = primary accent (green) so the user's own
                        // handle stands apart from the secondary master /
                        // float badge.
                        pal.primary.setStroke()
                        markStroke.stroke()
                        let pillPara = NSMutableParagraphStyle()
                        pillPara.alignment = .center
                        pillPara.lineBreakMode = .byTruncatingTail
                        let pillAttrs: [NSAttributedString.Key: Any] = [
                            .font: markFont,
                            .foregroundColor: pal.primary,
                            .paragraphStyle: pillPara,
                        ]
                        let textH = (mark as NSString).size(
                            withAttributes: pillAttrs).height
                        (mark as NSString).draw(
                            in: NSRect(x: lx,
                                       y: labelY - 1 + (pillH - textH) / 2 - 1.0,
                                       width: pillW, height: textH),
                            withAttributes: pillAttrs)
                        lx += pillW + 6
                    }
                    // Tags (#tag): EVERY tag this window carries (the tag-mode
                    // list is flat — there is no primary-tag header to hide
                    // one under). A `tag` glyph (replacing the old `#`) + the
                    // name in `secondary`, NO filled chip background (it read
                    // as an unwanted highlight); the glyph + accent colour
                    // already distinguish it from a mark / scratchpad. Stops
                    // before a tag would overrun the row's right edge.
                    let pillH: CGFloat = 22
                    for tag in c.tags {
                        let chipFont = uiFont(windowFontSize - 1, .medium)
                        let maxTextW: CGFloat = 90
                        let textW = min(maxTextW, ceil((tag as NSString)
                            .size(withAttributes: [.font: chipFont]).width))
                        let tagIcon = IconResolver.resolve(
                            "SF:tag", pointSize: windowFontSize - 1,
                            color: pal.secondary, scale: .medium)
                        let icH = tagIcon.map { min($0.size.height, 12) } ?? 0
                        let icW = tagIcon.map {
                            $0.size.width * (icH / max($0.size.height, 1)) } ?? 0
                        let icGap: CGFloat = tagIcon == nil ? 0 : 3
                        let pillW = icW + icGap + textW
                        if lx + pillW > tx + tw { break }   // no room → stop
                        var cx = lx
                        if let tagIcon {
                            tagIcon.draw(in: NSRect(
                                x: cx, y: labelY - 1 + (pillH - icH) / 2,
                                width: icW, height: icH))
                            cx += icW + icGap
                        }
                        let chipPara = NSMutableParagraphStyle()
                        chipPara.lineBreakMode = .byTruncatingTail
                        let chipAttrs: [NSAttributedString.Key: Any] = [
                            .font: chipFont,
                            .foregroundColor: pal.secondary,
                            .paragraphStyle: chipPara,
                        ]
                        let chipH = (tag as NSString)
                            .size(withAttributes: chipAttrs).height
                        (tag as NSString).draw(
                            in: NSRect(x: cx,
                                       y: labelY - 1 + (pillH - chipH) / 2 - 1.0,
                                       width: textW, height: chipH),
                            withAttributes: chipAttrs)
                        lx += pillW + 6
                    }
                    if c.isSticky {
                        // Sticky: `pin` + horizontal text (no slant now — it
                        // aligns with the other badges; the pin glyph already
                        // sets it apart from float).
                        lx = drawStatusPill("sticky", icon: "SF:pin",
                                            color: pal.tertiary,
                                            at: lx, labelY: labelY)
                    }
                    if let sp = c.scratchpad {
                        // Scratchpad shelf: `tray` + `scratchpad:NAME`, dim
                        // (not the mark's accent) so it reads as secondary;
                        // labelled in full so it can't be mistaken for a mark.
                        lx = drawStatusPill("scratchpad:\(sp)", icon: "SF:tray",
                                            color: pal.muted,
                                            at: lx, labelY: labelY)
                    }
                    if let labelText {
                        // master / float — icon + text, no border. master →
                        // `crown` + `primary`; float → `macwindow` +
                        // `foreground` (matches the "Desktop N" band label).
                        lx = drawStatusPill(
                            labelText,
                            icon: c.isMaster ? "SF:crown" : "SF:macwindow",
                            color: c.isMaster ? pal.primary : pal.foreground,
                            at: lx, labelY: labelY)
                    }
                    if c.isHidden {
                        // Hidden (Cmd+H / minimized): `eye.slash` + dim text —
                        // confirming the dimmed row is hidden, not gone. Click
                        // restores it. (Never master/float/sticky, so it's the
                        // only badge on its row.)
                        lx = drawStatusPill("hidden", icon: "SF:eye.slash",
                                            color: pal.muted,
                                            at: lx, labelY: labelY)
                    }
                }
            }

            // Keyboard cursor: an accent outline distinct from the
            // selected-window pill (fill) and hover (faint fill).
            if let kbSelRow, kbSelRow == i {
                let r = (c.kind == 2 ? row.insetBy(dx: 6, dy: 2)
                                     : row.insetBy(dx: 6, dy: 4))
                pal.primary.setStroke()
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
                    (pal.background ?? .windowBackgroundColor)
                        .withAlphaComponent(0.55).setFill()
                    NSBezierPath(roundedRect: row.rect.insetBy(dx: 4, dy: 1),
                                 xRadius: 5, yRadius: 5).fill()
                }
            }
        }

    }

    /// Draw an outlined status badge — an optional leading SF icon then
    /// centred text — at `lx` on a window row's third line, returning the
    /// advanced x. Shared by the master / float / sticky / hidden /
    /// scratchpad badges so they read uniformly alongside the rest of the
    /// icon-bearing UI (item 7 — the text-heavy tree gets icon support).
    /// `stroke` outlines the pill; `textColor` tints BOTH the label and
    /// the icon; `oblique` slants the glyphs (sticky); `maxTextW`
    /// tail-truncates long names (e.g. `scratchpad:NAME`).
    /// Draw a window-state badge — an optional leading SF icon then text — at
    /// `lx` on a window row's third line, returning the advanced x. Borderless
    /// + horizontal (no pill outline, no slant): the glyph + `color` carry the
    /// meaning, matching the tag chips' clean icon+text look. Shared by the
    /// master / float / sticky / hidden / scratchpad badges.
    private func drawStatusPill(_ text: String, icon: String, color: NSColor,
                                maxTextW: CGFloat = 130,
                                at lx: CGFloat, labelY: CGFloat) -> CGFloat {
        let font = uiFont(windowFontSize, .semibold)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: para]
        let textW = min(maxTextW, ceil((text as NSString)
            .size(withAttributes: [.font: font]).width))
        let pillH: CGFloat = 22
        let iconImg = icon.isEmpty ? nil
            : IconResolver.resolve(icon, pointSize: 14,
                                   color: color, scale: .medium)
        let iconH = iconImg.map { min($0.size.height, 15) } ?? 0
        let iconW = iconImg.map { $0.size.width * (iconH / max($0.size.height, 1)) } ?? 0
        let iconGap: CGFloat = iconImg == nil ? 0 : 4
        var cx = lx
        if let iconImg {
            iconImg.draw(in: NSRect(
                x: cx, y: labelY - 1 + (pillH - iconH) / 2,
                width: iconW, height: iconH))
            cx += iconW + iconGap
        }
        let textH = (text as NSString).size(withAttributes: attrs).height
        (text as NSString).draw(
            in: NSRect(x: cx, y: labelY - 1 + (pillH - textH) / 2 - 1.0,
                       width: textW, height: textH),
            withAttributes: attrs)
        return cx + textW + 10   // past the text + a gap to the next badge
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

        // (Double-click-to-reset-geometry now lives on the pinned
        // HandleBar, not on a scrolling row.)

        var mode = 0          // 0 undecided · 1 panel-move · 2 window-drag
        var dragWS = 0
        var dragWindowID = WindowID(serverID: 0)
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        loop: while let ev = win.nextEvent(matching: mask) {
            let cp = convert(ev.locationInWindow, from: nil)
            switch ev.type {
            case .leftMouseUp:
                // mode 1 (panel move) needs nothing on mouseUp — the
                // move applied live during the drag and geometry is
                // session-only now (sticks via `[tree]` config, not
                // UserDefaults).
                if mode == 2 {
                    let tgt = wsBands.first { $0.value.contains(cp.y) }?.key
                    if let tgt, tgt != dragWS {
                        // M9-1: background move — file the window into
                        // the target WS without switching to it or
                        // focus-following. This matches the grid drop
                        // and the keyboard lift; the tree mouse drop
                        // was the lone exception. No setOptimistic (it
                        // would mislabel the active WS) — the reconcile
                        // relocates the row; prevApp is restored below
                        // so focus stays put.
                        let id = dragWindowID
                        let bk = backend
                        cliQueue.async {
                            bk.moveWindow(id, toWorkspaceIndex: tgt)
                        }
                        controller?.scheduleReconcile(after: 0.05)
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
                    // ⌘+drag is always a panel-move; so is ANY drag in tag
                    // mode, where the flat list has no workspace to drop a
                    // window / swap a header onto (DnD retag is off — #191
                    // PR-6). Retagging is via the row context menu / CLI.
                    if ev.modifierFlags.contains(.command) || tagModeActive {
                        mode = 1                       // ⌘+drag / tag mode → move
                    } else {
                        switch row?.kind {
                        case .none, .search?:
                            mode = 1                   // empty / search → move
                        case .window(let ws, _, let wid, _)?:
                            mode = 2
                            dragWS = ws
                            dragWindowID = wid
                            draggingWid = (ws, wid)
                            if let rr = row?.rect,
                               let c = cells.first(where: {
                                   $0.row == rr && $0.kind == 2
                               }) {
                                dragLabel = c.title.isEmpty
                                    ? c.app : "\(c.app)  \(c.title)"
                            }
                            // ⑨ richer ghost: lift the window's row as a
                            // snapshot card; fall back to the text chip.
                            if !showDragCard(rect: dragRect(forWindow: wid)) {
                                showChip(dragLabel ?? "")
                            }
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
                            // ⑨ richer ghost: lift the whole WS section
                            // (header + windows) as a snapshot card.
                            if !showDragCard(rect: dragRect(forWS: ws)) {
                                showChip(swapChipLabel(for: ws))
                            }
                            lastDropWS = nil
                        }
                    }
                }
                if mode == 1 {
                    // Hand the panel move to the WINDOW SERVER via
                    // performDrag(with:) — the same machinery a native title
                    // bar uses. It tracks at compositor rate (perfect lockstep
                    // with the cursor, zero per-event main-thread work, no
                    // coalescing / pointer-acceleration drift) and translates
                    // the addChildWindow pet overlay for free. The
                    // .nonactivatingPanel style keeps kCGSPreventsActivation
                    // set, so this never steals focus / activates facet. It
                    // runs its OWN modal loop until mouseUp, so it only fits the
                    // pure-move path: modes 2/3 (window DnD / header swap) keep
                    // the manual loop below because they need per-event ghost /
                    // drop-band hooks. Threshold-gated — we only reach here once
                    // a real drag is confirmed, so plain clicks and the handle
                    // double-click (handled above) are untouched. On return the
                    // window has settled at its drop point; re-derive the
                    // persisted anchor + pet inset, then exit the loop (the
                    // mouseUp was consumed by performDrag).
                    win.performDrag(with: ev)
                    controller?.syncPanelAfterDrag()
                    break loop
                } else if mode == 2 || mode == 3 {
                    dropWS = wsBands.first { $0.value.contains(cp.y) }?.key
                    if let t = dropWS, t != dragWS {
                        NSCursor.closedHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                    // Move just the ghost (cheap → keeps up at speed) +
                    // lean it toward the drag direction (⑨).
                    moveDragGhost(to: cp)
                    tiltDragGhost(deltaX: ev.deltaX)
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
        hideDragGhosts()
        NSCursor.arrow.set()
        // Restore the previously-frontmost app. A tree drag activates
        // facet only so the drag cursor shows (see mouseDown top); the
        // M9-1 drop is a background move that never takes focus, so
        // focus always returns to whoever was frontmost.
        if let prev = prevApp {
            prev.activate()
            prevApp = nil
        }
        needsDisplay = true
    }

    private func showChip(_ label: String) {
        chip.stringValue = label
        chip.font = uiFont(windowFontSize, .semibold)
        chip.textColor = pal.background ?? .white
        chip.layer?.backgroundColor = pal.primary.cgColor
        chip.sizeToFit()
        let w = min(chip.frame.width + 20, bounds.width - 16)
        chip.frame = NSRect(x: chip.frame.minX, y: chip.frame.minY,
                            width: w, height: 22)
        chip.isHidden = false
    }

    // MARK: - Drag card (⑨ — snapshot the lifted rows)

    /// Union rect of a workspace's header + window rows.
    private func dragRect(forWS ws: Int) -> NSRect? {
        var r: NSRect?
        for row in rows {
            let hit: Bool
            switch row.kind {
            case .header(let w):       hit = (w == ws)
            case .window(let w, _, _, _): hit = (w == ws)
            default:                   hit = false
            }
            if hit { r = r.map { $0.union(row.rect) } ?? row.rect }
        }
        return r
    }

    /// A single window row's rect.
    private func dragRect(forWindow id: WindowID) -> NSRect? {
        rows.first {
            if case .window(_, _, let wid, _) = $0.kind { return wid == id }
            return false
        }?.rect
    }

    /// Show the snapshot card for `rect` (capped to ~60% panel height so a
    /// tall WS shows its top) in the floating window. Returns false → the
    /// caller falls back to the in-panel chip.
    @discardableResult
    private func showDragCard(rect: NSRect?) -> Bool {
        guard var r = rect?.intersection(bounds), r.width > 1, r.height > 1
        else { return false }
        let maxH = max(40, bounds.height * 0.6)
        if r.height > maxH { r.size.height = maxH }   // top portion only
        guard let img = snapshotRegion(r) else { return false }
        dragCard.image = img
        dragCard.frame = NSRect(x: dragCardPad, y: dragCardPad,
                                width: r.width, height: r.height)
        dragCard.layer?.borderColor = pal.primary.withAlphaComponent(0.9).cgColor
        dragCard.layer?.backgroundColor = (pal.background ?? NSColor(white: 0.10, alpha: 1)).cgColor
        dragCardWindow.setContentSize(NSSize(width: r.width + dragCardPad * 2,
                                             height: r.height + dragCardPad * 2))
        // Semi-transparent (dnd-kit style) so the drop-target band shows
        // through the lifted card — the drop is easier to predict (⑨).
        dragCardWindow.alphaValue = dragGhostAlpha
        positionDragCardWindow()
        dragCardWindow.orderFront(nil)
        chip.isHidden = true
        cardShown = true
        return true
    }

    /// Place the card window just below-right of the live cursor (screen
    /// coords); the card itself is inset by `dragCardPad`.
    private func positionDragCardWindow() {
        let m = NSEvent.mouseLocation               // screen, y-up
        dragCardWindow.setFrameTopLeftPoint(
            NSPoint(x: m.x + 14 - dragCardPad, y: m.y - 12 + dragCardPad))
    }

    /// Move the visible drag ghost to follow the cursor — the floating
    /// card window (screen coords) or, as fallback, the in-panel chip.
    private func moveDragGhost(to cp: NSPoint) {
        if cardShown { positionDragCardWindow(); return }
        chip.setFrameOrigin(NSPoint(
            x: min(max(cp.x + 14, 4), bounds.width - chip.frame.width - 4),
            y: max(4, cp.y - 12)))
    }

    /// Lean the lifted card toward the drag direction (⑨) — like a card
    /// dangling from the cursor. Driven by each move's horizontal delta;
    /// eases toward 0 when the motion is vertical / stops.
    private var dragTilt: CGFloat = 0
    private func tiltDragGhost(deltaX: CGFloat) {
        let target = max(-dragTiltMax, min(dragTiltMax, deltaX * dragTiltPerPx))
        dragTilt += (target - dragTilt) * 0.4          // smooth
        let layer = cardShown ? dragCard.layer : chip.layer
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.transform = CATransform3DMakeRotation(dragTilt, 0, 0, 1)
        CATransaction.commit()
    }

    private func hideDragGhosts() {
        chip.isHidden = true
        dragCardWindow.orderOut(nil)
        dragCard.image = nil
        cardShown = false
        // Reset the lean.
        dragTilt = 0
        dragCard.layer?.transform = CATransform3DIdentity
        chip.layer?.transform = CATransform3DIdentity
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
        case .search:
            break
        case .header(let i):
            // Tag-world header (tag mode): one tag-world, nothing to switch
            // to — the layout picker is on right-click / `m`. Plain click /
            // Enter is a no-op (no spurious WS switch on the synthetic WS).
            if tagModeActive { return }
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
            // outline (drawn only while `kbNav` is on) doesn't
            // strand on the previously selected row beside the new
            // sel fill. A plain click does NOT turn kbNav on (since
            // #66 the panel takes key only via --active / the
            // Desktop-header menu); this just pre-syncs the cursor.
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
            // Keep the kb-nav cursor (drawn only while `kbNav` is
            // on) in sync with the click target, otherwise the
            // outline strands on the previous selection beside the
            // new sel fill. (A plain click doesn't enable kbNav —
            // see the header case above.)
            kbSel = .win(id)
            // A *hidden* row (Cmd+H'd / minimized window — hide-reclaim
            // pulled its tile slot, `isOnscreen == false`) is restored
            // on click: the backend un-hides / un-minimizes + focuses,
            // and the next reconcile re-tiles it. A normal row just
            // focuses. Memory: `facet-hide-reclaim-decisions`.
            let hidden = lastWorkspaces.first { $0.index == i }?
                .windows.first { $0.id == id }?.isOnscreen == false
            let window = Window(id: id, pid: pid, appName: "",
                                title: title, isFocused: false,
                                isFloating: false, frame: nil)
            let bk = backend
            let ctrl = controller
            cliQueue.async {
                if needSwitch {
                    bk.switchWorkspace(toIndex: i)
                }
                if hidden {
                    bk.revealWindow(id)
                } else {
                    Task { @MainActor in
                        ctrl?.focusWindow(window, postSwitch: needSwitch)
                    }
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
        // Keyboard nav takes the preview back from hover (and clears the
        // stale hover highlight). previewTargets() prefers hoverIdx, so
        // without this an arrow key wouldn't move the preview while the
        // mouse rests on a row. Next mouseMoved re-sets hoverIdx.
        hoverIdx = nil
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
        // Tag mode is a flat list with no workspace to move a window /
        // swap a header into, so the lift gesture is a no-op (#191 PR-6).
        guard !tagModeActive else { return }
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

    /// Commit the lift: a window moves to the target WS (a background
    /// move — no switch, no focus-follow — same as the mouse drop
    /// since M9-1); a header swaps its WS's contents with the target.
    /// Returns true if a lift was in progress.
    @discardableResult
    public func kbCommitLift() -> Bool {
        guard let s = kbLifted else { return false }
        let tgt = kbDropWS
        kbLifted = nil; kbDropWS = nil
        needsDisplay = true
        guard let tgt else { return true }
        switch s {
        case .win(let id):
            // Move-only background move (same model as the mouse drop
            // since M9-1): "file" the window into the target WS and
            // stay put — no switch, so don't claim tgt is active (no
            // setOptimistic, which would mislabel the active WS). The
            // reconcile relocates the row; kbSel follows it.
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
    /// same menu right-click shows (window actions / workspace layout).
    /// Anchored OUTSIDE the tree, just past the panel's right edge
    /// (`f.maxX + 8`, the same placement as the `t` tag-manage panel)
    /// and level with the selected row's top — so the menu sits *beside*
    /// the target window instead of covering it (dropping it inside the
    /// tree hid the very row the user is acting on). (Space is the lift
    /// gesture in Theme A.) facet stays --active; pick with the mouse or
    /// Esc.
    public func kbContextMenu() {
        guard let s = kbSel, let i = kbIndex(of: s),
              let win = window else { return }
        let r = rows[i].rect
        let rowTop = win.convertPoint(toScreen:
            convert(NSPoint(x: r.minX, y: r.minY), to: nil))
        let scr = NSPoint(x: win.frame.maxX + 8, y: rowTop.y)
        // Keyboard path → type-to-filter menu (the tree panel keeps key, so
        // PopupMenu's key monitor receives the typed query).
        switch rows[i].kind {
        case .header(let ws):
            headerMenu(at: scr, workspaceIndex: ws, filterable: true)
        case .window(let ws, let pid, let id, let title):
            showWindowMenu(at: scr, workspaceIndex: ws,
                           pid: pid, windowID: id, title: title, filterable: true)
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
            headerMenu(at: scr, workspaceIndex: ws)
        case .window(let ws, let pid, let id, let title):
            showWindowMenu(at: scr, workspaceIndex: ws,
                           pid: pid, windowID: id, title: title)
        default:
            break
        }
    }

    // The header (layout) + window (ops) menus are shared with grid /
    // rail via `ViewContextMenu` (FacetView) so all three views show the
    // identical themed popup (③).
    /// Header right-click / `m` menu. Workspace mode → the layout picker
    /// directly. Tag mode → a two-facet menu (Layout + Select tags), since
    /// a tag-world also owns a lens (which tags are shown).
    private func headerMenu(at scr: NSPoint, workspaceIndex ws: Int,
                            filterable: Bool = false) {
        if tagModeActive {
            // Tag mode: one sectioned menu (Layout + Select tags). Not
            // filterable — the layout list is short and `Select tags` opens
            // its own filterable checklist.
            showTagWorldMenu(at: scr, workspaceIndex: ws)
        } else {
            showLayoutMenu(at: scr, workspaceIndex: ws, filterable: filterable)
        }
    }

    private func showTagWorldMenu(at scr: NSPoint, workspaceIndex ws: Int) {
        let modes = backend.layoutModes.filter {
            LayoutGrouping.isCompatible(mode: $0, with: .tag)
        }
        let cur = lastWorkspaces.first { $0.index == ws }?.layoutMode
        let bk = backend
        ViewContextMenu.showTagWorld(
            at: scr, layoutModes: modes, currentLayout: cur, palette: pal,
            onPickLayout: { mode in
                cliQueue.async { bk.setLayoutMode(workspaceIndex: ws, mode: mode) }
            },
            onSelectTags: { [weak self] in
                self?.controller?.openLensSelector(at: scr) },
            // "All tags" (item 15/16): lens = every tag = show everything.
            // `autoFocus: false` keeps the tree from losing key to a window
            // in the new union.
            onAllTags: { cliQueue.async { bk.setLens(.all, autoFocus: false) } })
    }

    private func showLayoutMenu(at scr: NSPoint, workspaceIndex ws: Int,
                                filterable: Bool = false) {
        ViewContextMenu.showLayout(at: scr, backend: backend,
                                   workspaceIndex: ws, workspaces: lastWorkspaces,
                                   palette: pal, filterable: filterable,
                                   tagMode: tagModeActive)
    }

    private func showWindowMenu(at scr: NSPoint,
                                workspaceIndex ws: Int,
                                pid: Int,
                                windowID id: WindowID,
                                title: String,
                                filterable: Bool = false) {
        ViewContextMenu.showWindow(
            at: scr, backend: backend, workspaceIndex: ws,
            workspaces: lastWorkspaces, pid: pid, windowID: id, title: title,
            palette: pal,
            tagMode: tagModeActive,
            filterable: filterable,
            onOpenTagEditor: { [weak self] wid, pid, app, title, tags, anchor in
                self?.controller?.openTagEditor(
                    forWindow: wid, pid: pid, appName: app, title: title,
                    currentTags: tags, at: anchor)
            }
        ) { [weak self] ops, window, ws in
            self?.controller?.runWindowOps(ops, on: window, workspaceIndex: ws)
        }
    }
}
