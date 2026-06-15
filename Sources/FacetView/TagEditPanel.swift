// Per-window tag-edit checklist panel (#4) — a GitHub-"Apply labels"-style
// floating, KEY-FOCUSABLE modal for adding / removing a window's tags.
//
// The twin of `PopupMenu`: a singleton (`TagEditPanel.shared`) drawn purely
// with `pal`, anchored beside the row the ops menu was raised on, flipped at
// the screen edge, and closed on Esc / outside-click / a click on any
// other row. Unlike `PopupMenu` it hosts a real `NSTextField` (the filter /
// new-tag-name box) so it must be able to take key + IME — it is a
// `KeyablePanel` (`wantsKey = true`) and the Controller flips the app to a
// regular, active app around show()/close() (the activation-policy dance the
// tree panel already uses for `--active`).
//
// v1 is NAME ONLY (no colour / description). The checklist shows every
// defined tag with a checkbox (checked = on this window); typing filters the
// list AND becomes a new-tag name — a "+ Create" row appears when the typed
// name matches no existing tag, and choosing it auto-vivifies the tag and
// checks it (`addTag(_:toWindow:)` auto-vivifies, so create == toggle-on).
//
// The panel owns its checklist state (vocabulary + this window's tags +
// filter) and mutates it optimistically; backend writes + the tree refresh
// are the Controller's job via the onToggle / onCreate callbacks.

import AppKit
import FacetCore

/// One rendered row of the checklist.
enum TagEditRow {
    case tag(name: String, checked: Bool)
    case create(name: String)
}

// MARK: - List view (the scrollable checkbox rows)

/// Draws the checkbox rows with `pal`, mirroring `PopupMenuView`'s row /
/// selection look. Hover and keyboard selection are one highlight (the
/// pick-one-menu model). Clicking a row reports its index; the panel decides
/// what activating it means (toggle a tag, or create a new one).
final class TagEditListView: NSView {
    var rows: [TagEditRow] = []
    var sel: Int = 0
    var palette: ResolvedPalette = resolve(.terminal)
    var onPick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    static let rowH: CGFloat = 28
    static let padX: CGFloat = 12

    override var isFlipped: Bool { true }

    func contentHeight() -> CGFloat {
        CGFloat(max(rows.count, 1)) * Self.rowH
    }

    private func rowIndex(at p: NSPoint) -> Int? {
        let i = Int(p.y / Self.rowH)
        return (i >= 0 && i < rows.count) ? i : nil
    }

    override func draw(_ dirty: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        guard !rows.isEmpty else {
            // Empty vocabulary + empty filter: a quiet hint, not a blank box.
            let a: [NSAttributedString.Key: Any] = [
                .font: uiFont(12, .regular),
                .foregroundColor: palette.muted,
                .paragraphStyle: para,
            ]
            ("Type to create a tag" as NSString).draw(
                in: NSRect(x: Self.padX, y: 6,
                           width: bounds.width - Self.padX * 2,
                           height: Self.rowH - 6),
                withAttributes: a)
            return
        }

        for (i, row) in rows.enumerated() {
            let r = NSRect(x: 0, y: CGFloat(i) * Self.rowH,
                           width: bounds.width, height: Self.rowH)
            if i == sel {
                let pill = r.insetBy(dx: 4, dy: 2)
                palette.selection.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
                palette.primary.setStroke()
                let o = NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1),
                                     xRadius: 6, yRadius: 6)
                o.lineWidth = 1.5; o.stroke()
            }
            let boxSide: CGFloat = 14
            let boxY = r.minY + (Self.rowH - boxSide) / 2
            let boxRect = NSRect(x: Self.padX, y: boxY,
                                 width: boxSide, height: boxSide)
            let textRect = NSRect(x: Self.padX + boxSide + 8, y: r.minY + 5,
                                  width: r.width - (Self.padX * 2 + boxSide + 8),
                                  height: Self.rowH - 6)
            switch row {
            case let .tag(name, checked):
                let box = NSBezierPath(roundedRect: boxRect,
                                       xRadius: 3, yRadius: 3)
                if checked {
                    palette.primary.setFill(); box.fill()
                    let mark: [NSAttributedString.Key: Any] = [
                        .font: uiFont(11, .bold),
                        .foregroundColor: palette.background ?? .white,
                    ]
                    ("✓" as NSString).draw(
                        in: boxRect.offsetBy(dx: 2.5, dy: 0.5), withAttributes: mark)
                } else {
                    palette.muted.setStroke(); box.lineWidth = 1; box.stroke()
                }
                ("#\(name)" as NSString).draw(
                    in: textRect,
                    withAttributes: [
                        .font: uiFont(13, checked ? .semibold : .regular),
                        .foregroundColor: checked ? palette.primary
                                                  : palette.foreground,
                        .paragraphStyle: para,
                    ])
            case let .create(name):
                ("+" as NSString).draw(
                    in: boxRect.offsetBy(dx: 2, dy: -1),
                    withAttributes: [.font: uiFont(15, .bold),
                                     .foregroundColor: palette.primary])
                ("Create \"#\(name)\"" as NSString).draw(
                    in: textRect,
                    withAttributes: [
                        .font: uiFont(13, .semibold),
                        .foregroundColor: palette.primary,
                        .paragraphStyle: para,
                    ])
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved],
            owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        if let i = rowIndex(at: convert(e.locationInWindow, from: nil)),
           i != sel { onHover?(i) }
    }

    override func mouseUp(with e: NSEvent) {
        if let i = rowIndex(at: convert(e.locationInWindow, from: nil)) {
            onPick?(i)
        }
    }
}

// MARK: - Container (card background + header, hosts field & list)

/// The panel's content view: draws the rounded card, the header (the same
/// app-icon + app-name / window-title layout the tree row uses, so the user
/// recognises which window they're tagging), the filter-box outline and the
/// divider. The filter `NSTextField` and the list scroll view are subviews.
/// No ✕ — closing is Esc / outside-click / another-row-click, matching the
/// twin `PopupMenu`.
final class TagEditContainerView: NSView {
    var appName = ""
    var title = ""
    var icon: NSImage?
    var palette: ResolvedPalette = resolve(.terminal)

    static let padX: CGFloat = 12
    static let padV: CGFloat = 10
    static let iconSize: CGFloat = 28        // matches the tree's app icon
    static let headerH: CGFloat = 40         // icon + app line + title line
    static let fieldH: CGFloat = 30
    static let fieldGap: CGFloat = 8

    override var isFlipped: Bool { true }

    /// Top of the filter box (below the header band).
    var fieldTop: CGFloat { Self.padV + Self.headerH + Self.fieldGap }
    /// Top of the list area (below the filter box + divider).
    var listTop: CGFloat { fieldTop + Self.fieldH + Self.fieldGap }

    override func draw(_ dirty: NSRect) {
        // Card
        let bg = palette.background ?? NSColor.windowBackgroundColor
        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 9, yRadius: 9)
        bg.setFill(); card.fill()
        palette.border.setStroke(); card.lineWidth = 1; card.stroke()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        // Header — mirror the tree window row: app icon (left, vertically
        // centred) + app name (line 1) + window title (line 2, dimmed).
        let iconY = Self.padV + (Self.headerH - Self.iconSize) / 2
        icon?.draw(in: NSRect(x: Self.padX, y: iconY,
                              width: Self.iconSize, height: Self.iconSize))
        let tx = Self.padX + Self.iconSize + 8
        let textW = max(bounds.width - tx - Self.padX, 0)
        let hasTitle = !title.isEmpty
        let appY = hasTitle ? Self.padV + 3
                            : Self.padV + (Self.headerH - 18) / 2
        (appName as NSString).draw(
            in: NSRect(x: tx, y: appY, width: textW, height: 18),
            withAttributes: [.font: uiFont(13, .semibold),
                             .foregroundColor: palette.foreground,
                             .paragraphStyle: para])
        if hasTitle {
            (title as NSString).draw(
                in: NSRect(x: tx, y: Self.padV + 21, width: textW, height: 15),
                withAttributes: [.font: uiFont(11, .regular),
                                 .foregroundColor: palette.muted,
                                 .paragraphStyle: para])
        }
        // Filter-box outline
        let fieldBox = NSRect(x: Self.padX, y: fieldTop,
                              width: bounds.width - Self.padX * 2,
                              height: Self.fieldH)
        let fb = NSBezierPath(roundedRect: fieldBox, xRadius: 7, yRadius: 7)
        (bg.blended(withFraction: 0.06, of: .white) ?? bg).setFill(); fb.fill()
        palette.border.setStroke(); fb.lineWidth = 1; fb.stroke()
        // ⌕ glyph in the filter box
        ("⌕" as NSString).draw(
            at: NSPoint(x: Self.padX + 8, y: fieldTop + 7),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: palette.muted])
        // Divider above the list
        let sy = listTop - Self.fieldGap / 2
        palette.border.setStroke()
        let sp = NSBezierPath()
        sp.move(to: NSPoint(x: Self.padX, y: sy))
        sp.line(to: NSPoint(x: bounds.width - Self.padX, y: sy))
        sp.stroke()
    }
}

// MARK: - Panel controller

@MainActor
public final class TagEditPanel: NSObject, NSTextFieldDelegate {
    public static let shared = TagEditPanel()

    private var panel: KeyablePanel?
    private weak var container: TagEditContainerView?
    private var field: NSTextField?
    private weak var listView: TagEditListView?
    private var monitors: [Any] = []

    // Checklist state (owned + mutated optimistically by the panel).
    private var allTags: [String] = []
    private var checked: Set<String> = []
    private var palette: ResolvedPalette = resolve(.terminal)
    private var onToggle: ((String, Bool) -> Void)?
    private var onCreate: ((String) -> Void)?
    private var onCloseCB: (() -> Void)?
    private var closing = false

    /// Cap on visible rows before the list scrolls. The panel height is
    /// fixed at show() time; filtering scrolls within (GitHub's label
    /// dropdown is a fixed-height scroll box too).
    private static let maxVisibleRows = 10

    public var isOpen: Bool { panel != nil }

    private override init() { super.init() }

    /// Present the checklist anchored at `screenPt` (the point the ops menu
    /// was raised on — the panel's top-left, flipped up if it would overflow
    /// the screen bottom). `onClose` fires exactly once on any close path.
    public func show(at screenPt: NSPoint,
                     appName: String,
                     title: String,
                     pid: Int,
                     allTags: [String],
                     checkedTags: Set<String>,
                     palette: ResolvedPalette,
                     onToggle: @escaping (String, Bool) -> Void,
                     onCreate: @escaping (String) -> Void,
                     onClose: @escaping () -> Void) {
        close()                                   // tear down any prior panel
        closing = false
        self.allTags = allTags
        self.checked = checkedTags
        self.palette = palette
        self.onToggle = onToggle
        self.onCreate = onCreate
        self.onCloseCB = onClose

        let width = panelWidth(appName: appName, title: title)
        let listW = width - TagEditContainerView.padX * 2
        // Fixed panel height: header + filter + up to maxVisibleRows of list.
        // Reserve one extra row so a "+ Create" row (appended while filtering)
        // is visible without scrolling.
        let visibleRows = min(max(allTags.count, 1) + 1, Self.maxVisibleRows)
        let listH = CGFloat(visibleRows) * TagEditListView.rowH
        let listTop = TagEditContainerView.padV + TagEditContainerView.headerH
            + TagEditContainerView.fieldGap + TagEditContainerView.fieldH
            + TagEditContainerView.fieldGap
        let height = listTop + listH + TagEditContainerView.padV

        var origin = NSPoint(x: screenPt.x, y: screenPt.y - height)
        if let vis = NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 4),
                           vis.maxX - width - 4)
            if origin.y < vis.minY + 4 { origin.y = screenPt.y }   // flip up
            origin.y = min(origin.y, vis.maxY - height - 4)
        }

        let pnl = KeyablePanel(
            contentRect: NSRect(origin: origin,
                                size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        pnl.wantsKey = true
        pnl.isFloatingPanel = true
        pnl.level = .popUpMenu
        pnl.backgroundColor = .clear
        pnl.isOpaque = false
        pnl.hasShadow = true
        pnl.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                  .fullScreenAuxiliary]

        let cont = TagEditContainerView(
            frame: NSRect(x: 0, y: 0, width: width, height: height))
        cont.appName = appName
        cont.title = title
        cont.icon = AppIcons.icon(forPID: pid)
        cont.palette = palette

        // Filter / new-tag field (borderless; the container draws its box).
        let f = NSTextField(frame: NSRect(
            x: TagEditContainerView.padX + 24,
            y: cont.fieldTop + 6,
            width: width - TagEditContainerView.padX * 2 - 32,
            height: TagEditContainerView.fieldH - 12))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.font = uiFont(13, .regular)
        f.textColor = palette.foreground
        f.placeholderAttributedString = NSAttributedString(
            string: "Filter or create…",
            attributes: [.foregroundColor: palette.muted,
                         .font: uiFont(13, .regular)])
        f.delegate = self
        cont.addSubview(f)

        // Scrollable checklist.
        let list = TagEditListView(frame: NSRect(
            x: 0, y: 0, width: listW, height: listH))
        list.palette = palette
        list.onPick = { [weak self] i in self?.activate(i) }
        list.onHover = { [weak self] i in
            guard let self else { return }
            self.listView?.sel = i
            self.listView?.needsDisplay = true
        }
        let scroll = NSScrollView(frame: NSRect(
            x: TagEditContainerView.padX, y: cont.listTop,
            width: width - TagEditContainerView.padX * 2, height: listH))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let scroller = ThemedScroller()
        // ThemedScroller paints with a paletteBox; give it a fixed one.
        scroller.paletteBox = PaletteBox(palette)
        scroll.verticalScroller = scroller
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = list
        cont.addSubview(scroll)

        pnl.contentView = cont
        self.panel = pnl
        self.container = cont
        self.field = f
        self.listView = list

        recompute()
        pnl.makeKeyAndOrderFront(nil)
        pnl.makeFirstResponder(f)

        installMonitors()
    }

    /// Close on any path. Idempotent; fires `onClose` exactly once so the
    /// Controller can revert the activation policy on EVERY close path.
    public func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        container = nil
        field = nil
        listView = nil
        let cb = onCloseCB
        onCloseCB = nil
        onToggle = nil; onCreate = nil
        allTags = []; checked = []
        if !closing { closing = true; cb?() }
    }

    // MARK: - Filtering / rows

    private var isComposing: Bool {
        (field?.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    /// Rebuild the visible rows from the current filter text + checked set,
    /// keep the keyboard selection in range, and repaint.
    private func recompute() {
        let raw = field?.stringValue ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let visible = trimmed.isEmpty
            ? allTags
            : allTags.filter { $0.localizedCaseInsensitiveContains(trimmed) }
        var rows: [TagEditRow] = visible.map {
            .tag(name: $0, checked: checked.contains($0))
        }
        // "+ Create" when the typed (normalized) name isn't already defined.
        if !trimmed.isEmpty, let norm = TagName.normalized(raw),
           !allTags.contains(norm) {
            rows.append(.create(name: norm))
        }
        guard let list = listView else { return }
        list.rows = rows
        list.sel = rows.isEmpty ? 0 : min(max(list.sel, 0), rows.count - 1)
        list.frame = NSRect(x: 0, y: 0,
                            width: list.frame.width,
                            height: list.contentHeight())
        list.needsDisplay = true
    }

    private func move(_ d: Int) {
        guard let list = listView, !list.rows.isEmpty else { return }
        list.sel = min(max(list.sel + d, 0), list.rows.count - 1)
        list.needsDisplay = true
        // Keep the selected row visible in the scroll view.
        let r = NSRect(x: 0, y: CGFloat(list.sel) * TagEditListView.rowH,
                       width: list.frame.width, height: TagEditListView.rowH)
        list.scrollToVisible(r)
    }

    /// Activate row `i`: toggle a tag (stays open), or create + check a new
    /// one (clears the filter so the full list shows it checked).
    private func activate(_ i: Int) {
        guard let list = listView, i >= 0, i < list.rows.count else { return }
        switch list.rows[i] {
        case let .tag(name, _):
            let now = !checked.contains(name)
            if now { checked.insert(name) } else { checked.remove(name) }
            onToggle?(name, now)
            recompute()
        case let .create(name):
            checked.insert(name)
            if !allTags.contains(name) { allTags.append(name) }
            onCreate?(name)
            field?.stringValue = ""
            recompute()
        }
    }

    // MARK: - Geometry

    private func panelWidth(appName: String, title: String) -> CGFloat {
        // Header text sits right of the app icon.
        let headerLead = TagEditContainerView.iconSize + 8
        var w = max(
            (appName as NSString).size(withAttributes: [.font: uiFont(13, .semibold)]).width,
            (title as NSString).size(withAttributes: [.font: uiFont(11, .regular)]).width)
            + headerLead
        let rf = uiFont(13, .regular)
        for t in allTags {
            w = max(w, ("#\(t)" as NSString)
                .size(withAttributes: [.font: rf]).width + 44)
        }
        return min(max(w + TagEditContainerView.padX * 2, 240), 420)
    }

    // MARK: - Event monitors (Esc / nav / typing / outside-click)

    private func installMonitors() {
        // Click in another app closes the panel.
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { _ in
                MainActor.assumeIsolated { TagEditPanel.shared.close() }
            }) as Any)
        // Keys + clicks inside facet.
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] ev in
            guard let self, let panel = self.panel else { return ev }
            if ev.type == .keyDown {
                // While the IME has marked text, let the field handle
                // Enter (commit) / Esc (cancel) / arrows (candidates).
                if self.isComposing { return ev }
                let c = ev.charactersIgnoringModifiers?.lowercased()
                let ctrl = ev.modifierFlags.contains(.control)
                switch ev.keyCode {
                case 53:      self.close();              return nil  // Esc
                case 36, 76:  self.activateSelected();   return nil  // Return
                case 125:     self.move(1);              return nil  // ↓
                case 126:     self.move(-1);             return nil  // ↑
                default:
                    if ctrl, c == "n" { self.move(1);  return nil }
                    if ctrl, c == "p" { self.move(-1); return nil }
                    return ev                           // typing → filter
                }
            }
            // A click anywhere but our own panel closes it (clicking a
            // different tree row, the desktop, etc.). The click still falls
            // through (monitors observe, don't swallow) so the row's normal
            // action runs — closing without retargeting, per spec.
            if ev.window !== panel { self.close() }
            return ev
        } as Any)
    }

    private func activateSelected() {
        if let s = listView?.sel { activate(s) }
    }

    // MARK: - NSTextFieldDelegate

    public func controlTextDidChange(_ note: Notification) {
        recompute()
    }
}
