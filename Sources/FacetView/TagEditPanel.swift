// Per-window tag-edit checklist panel (Phase 9 / Cluster A — R10).
//
// The twin of `PopupMenu`: a singleton (`TagEditPanel.shared`) drawn purely
// with `pal`, flipped at the screen edge, and closed on Esc / outside-click /
// a click on any other row. Unlike `PopupMenu` it hosts a real `NSTextField`
// (the filter / new-tag-name box) so it must be able to take key + IME — it
// is a `KeyablePanel` (`wantsKey = true`) and the Controller flips the app to
// a regular, active app around show()/close() (the activation-policy dance the
// tree panel already uses for keyboard nav).
//
// WINDOW mode only: the per-window checklist opened from the window-ops menu
// "Tag…" item. Header = the window's app icon + name / title; rows are
// checkboxes (checked = this window carries the tag); a "+ Create" row
// auto-vivifies + checks a new tag. Toggling calls `onToggle(name, wantOn)`,
// which the Controller maps to `backend.addTag` / `removeTag`.
//
// This is the restored pre-pivot panel (deleted in #319) trimmed to WINDOW
// mode and adapted to the `Set<String>` tag model. The pre-pivot MANAGE mode
// (vocabulary rename / delete, the global `t` key) is NOT carried here — that
// is tag-vocabulary work and lands in Cluster C. v1 is NAME ONLY (no colour /
// description).

import AppKit
import FacetCore

/// One rendered row of the list.
enum TagEditRow {
    case tag(name: String, checked: Bool)
    case create(name: String)
}

// MARK: - List view (the scrollable rows)

/// Draws the rows with `pal`, mirroring `PopupMenuView`'s row / selection
/// look. Hover and keyboard selection are one highlight (the pick-one-menu
/// model). Each row carries a checkbox; clicking reports the index.
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

        let boxSide: CGFloat = 14
        for (i, row) in rows.enumerated() {
            let r = NSRect(x: 0, y: CGFloat(i) * Self.rowH,
                           width: bounds.width, height: Self.rowH)
            if i == sel {
                // Tag UI uses the `secondary` accent throughout (the selection
                // outline, the checked box / text, the Create row), matching
                // the tree's tag chips + the menus' TAGS section, so
                // "tag-related" reads one colour. Layout stays `primary`.
                let pill = r.insetBy(dx: 4, dy: 2)
                palette.secondary.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
                palette.secondary.setStroke()
                let o = NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1),
                                     xRadius: 6, yRadius: 6)
                o.lineWidth = 1.5; o.stroke()
            }
            let boxY = r.minY + (Self.rowH - boxSide) / 2
            let boxRect = NSRect(x: Self.padX, y: boxY,
                                 width: boxSide, height: boxSide)
            func textRect(from x: CGFloat) -> NSRect {
                NSRect(x: x, y: r.minY + 5,
                       width: r.width - x - Self.padX, height: Self.rowH - 6)
            }
            let gutterX = Self.padX + boxSide + 8
            switch row {
            case let .tag(name, checked):
                let textRect = textRect(from: gutterX)
                let box = NSBezierPath(roundedRect: boxRect,
                                       xRadius: 3, yRadius: 3)
                if checked {
                    palette.secondary.setFill(); box.fill()
                    ("✓" as NSString).draw(
                        in: boxRect.offsetBy(dx: 2.5, dy: 0.5),
                        withAttributes: [.font: uiFont(11, .bold),
                                         .foregroundColor: palette.background ?? .white])
                } else {
                    palette.muted.setStroke(); box.lineWidth = 1; box.stroke()
                }
                // A `tag` glyph stands in for the `#` prefix, then the bare
                // name. Always `secondary` (tags); checked adds weight + the
                // filled box, not a colour change.
                var nameX = textRect.minX
                if let tagIcon = IconResolver.resolve(
                    "SF:tag", pointSize: 12, color: palette.secondary,
                    scale: .medium) {
                    let ih = min(tagIcon.size.height, 13)
                    let iw = tagIcon.size.width * (ih / max(tagIcon.size.height, 1))
                    tagIcon.draw(in: NSRect(
                        x: textRect.minX,
                        y: textRect.minY + (textRect.height - ih) / 2,
                        width: iw, height: ih))
                    nameX = textRect.minX + iw + 5
                }
                (name as NSString).draw(
                    in: NSRect(x: nameX, y: textRect.minY,
                               width: textRect.maxX - nameX, height: textRect.height),
                    withAttributes: [
                        .font: uiFont(13, checked ? .semibold : .regular),
                        .foregroundColor: palette.secondary,
                        .paragraphStyle: para,
                    ])
            case let .create(name):
                ("+" as NSString).draw(
                    in: boxRect.offsetBy(dx: 2, dy: -1),
                    withAttributes: [.font: uiFont(15, .bold),
                                     .foregroundColor: palette.secondary])
                ("Create \"#\(name)\"" as NSString).draw(
                    in: textRect(from: gutterX),
                    withAttributes: [
                        .font: uiFont(13, .semibold),
                        .foregroundColor: palette.secondary,
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

/// The panel's content view: draws the rounded card, the header (app icon +
/// app name / title — the tree window-row look), the filter-box outline and
/// the divider. The filter `NSTextField` and the list scroll view are subviews.
final class TagEditContainerView: NSView {
    var appName = ""
    var title = ""
    var icon: NSImage?
    var palette: ResolvedPalette = resolve(.terminal)

    static let padX: CGFloat = 12
    static let padV: CGFloat = 10
    static let iconSize: CGFloat = 28           // matches the tree's app icon
    static let fieldH: CGFloat = 30
    static let fieldGap: CGFloat = 8

    /// Header band height: a single compact title line when there's no app
    /// icon, the taller icon + two-line block when one resolved.
    var headerH: CGFloat { icon == nil ? 24 : 40 }

    override var isFlipped: Bool { true }

    /// Top of the filter box (below the header band).
    var fieldTop: CGFloat { Self.padV + headerH + Self.fieldGap }
    /// Top of the list area (below the filter box + divider).
    var listTop: CGFloat { fieldTop + Self.fieldH + Self.fieldGap }

    override func draw(_ dirty: NSRect) {
        // Card. Accent border (1.5pt) like the main panel — always `primary`
        // (the frame is panel chrome; only the contents are secondary).
        let bg = palette.background ?? NSColor.windowBackgroundColor
        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 9, yRadius: 9)
        bg.setFill(); card.fill()
        palette.primary.setStroke(); card.lineWidth = 1.5; card.stroke()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        if icon == nil {
            // No resolvable app icon: a compact app-name title, flush left.
            (appName as NSString).draw(
                in: NSRect(x: Self.padX, y: Self.padV + (headerH - 18) / 2,
                           width: bounds.width - Self.padX * 2, height: 18),
                withAttributes: [.font: uiFont(13, .semibold),
                                 .foregroundColor: palette.foreground,
                                 .paragraphStyle: para])
        } else {
            // Mirror the tree window row: app icon + app name / title.
            let iconY = Self.padV + (headerH - Self.iconSize) / 2
            icon?.draw(in: NSRect(x: Self.padX, y: iconY,
                                  width: Self.iconSize, height: Self.iconSize))
            let tx = Self.padX + Self.iconSize + 8
            let textW = max(bounds.width - tx - Self.padX, 0)
            let hasTitle = !title.isEmpty
            let appY = hasTitle ? Self.padV + 3
                                : Self.padV + (headerH - 18) / 2
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
        }

        // Filter box
        let fieldBox = NSRect(x: Self.padX, y: fieldTop,
                              width: bounds.width - Self.padX * 2,
                              height: Self.fieldH)
        let fb = NSBezierPath(roundedRect: fieldBox, xRadius: 7, yRadius: 7)
        (bg.blended(withFraction: 0.06, of: .white) ?? bg).setFill(); fb.fill()
        palette.border.setStroke(); fb.lineWidth = 1; fb.stroke()
        // The search/filter affordance (matches the tree's SearchBar + the
        // PopupMenu filter).
        if let icon = IconResolver.resolve(
            "SF:magnifyingglass", pointSize: 13, color: palette.muted) {
            let isz = icon.size
            icon.draw(in: NSRect(x: Self.padX + 8,
                                 y: fieldTop + (Self.fieldH - isz.height) / 2,
                                 width: isz.width, height: isz.height))
        }
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
    private weak var scroll: NSScrollView?
    private var monitors: [Any] = []

    private var allTags: [String] = []
    private var checked: Set<String> = []
    private var palette: ResolvedPalette = resolve(.terminal)

    private var onToggle: ((String, Bool) -> Void)?
    private var onCreate: ((String) -> Void)?
    private var onCloseCB: (() -> Void)?
    private var closing = false

    private static let maxVisibleRows = 10

    public var isOpen: Bool { panel != nil }

    private override init() { super.init() }

    // MARK: Entry point

    /// WINDOW mode: the per-window checklist anchored at `screenPt`. `allTags`
    /// is the union of tags currently in use (computed view-side from the
    /// snapshot); `checkedTags` is the target window's own tags. `onToggle`
    /// fires on every check/uncheck; `onCreate` on a new-tag "+ Create".
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
        close()
        self.allTags = allTags
        self.checked = checkedTags
        self.palette = palette
        self.onToggle = onToggle
        self.onCreate = onCreate
        self.onCloseCB = onClose
        present(at: screenPt, appName: appName, title: title, pid: pid)
    }

    /// Build + present the panel from the already-set instance state. `onClose`
    /// fires exactly once on any close path.
    private func present(at screenPt: NSPoint,
                         appName: String, title: String, pid: Int) {
        closing = false

        let width = panelWidth(appName: appName, title: title)
        let listW = width - TagEditContainerView.padX * 2
        // Reserve one extra row so a "+ Create" row stays visible.
        let visibleRows = min(max(allTags.count, 1) + 1, Self.maxVisibleRows)
        let listH = CGFloat(visibleRows) * TagEditListView.rowH
        // Resolve the icon once: the container derives its headerH from
        // `icon == nil`, so the panel-level layout must use the SAME value.
        let icon: NSImage? = pid == 0 ? nil : AppIcons.icon(forPID: pid)
        let headerH: CGFloat = icon == nil ? 24 : 40
        let listTop = TagEditContainerView.padV + headerH
            + TagEditContainerView.fieldGap + TagEditContainerView.fieldH
            + TagEditContainerView.fieldGap
        let height = listTop + listH + TagEditContainerView.padV

        let origin = placePopupOrigin(anchor: screenPt,
                                      size: NSSize(width: width, height: height))

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
        cont.icon = icon
        cont.palette = palette

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

        let list = TagEditListView(frame: NSRect(
            x: 0, y: 0, width: listW, height: listH))
        list.palette = palette
        list.onPick = { [weak self] i in self?.activate(i) }
        list.onHover = { [weak self] i in
            self?.listView?.sel = i
            self?.listView?.needsDisplay = true
        }
        let scroll = NSScrollView(frame: NSRect(
            x: TagEditContainerView.padX, y: cont.listTop,
            width: listW, height: listH))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        let scroller = ThemedScroller()
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
        self.scroll = scroll

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

    /// Rebuild the visible rows from the current filter text.
    private func recompute() {
        let raw = field?.stringValue ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let visible = trimmed.isEmpty
            ? allTags
            : allTags.filter { $0.localizedCaseInsensitiveContains(trimmed) }
        var rows: [TagEditRow] = visible.map {
            .tag(name: $0, checked: checked.contains($0))
        }
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
        resizeToFit()
    }

    /// Grow / shrink the panel so the vocabulary fits (capped at
    /// `maxVisibleRows`, scrolling beyond). Keyed on `allTags` (not the
    /// filtered rows), so add resizes the panel while plain filtering leaves
    /// the height steady. The top edge stays pinned; growth extends downward.
    private func resizeToFit() {
        guard let panel = panel, let cont = container, let scroll = scroll
        else { return }
        let visibleRows = min(max(allTags.count, 1) + 1, Self.maxVisibleRows)
        let listH = CGFloat(visibleRows) * TagEditListView.rowH
        let newHeight = cont.listTop + listH + TagEditContainerView.padV
        if abs(newHeight - panel.frame.height) > 0.5 {
            let top = panel.frame.maxY
            var f = panel.frame
            f.size.height = newHeight
            f.origin.y = clampTopPinnedY(top: top, height: newHeight)
            panel.setFrame(f, display: true)
        }
        scroll.frame = NSRect(x: TagEditContainerView.padX, y: cont.listTop,
                              width: scroll.frame.width, height: listH)
    }

    private func move(_ d: Int) {
        guard let list = listView, !list.rows.isEmpty else { return }
        list.sel = min(max(list.sel + d, 0), list.rows.count - 1)
        list.needsDisplay = true
        let r = NSRect(x: 0, y: CGFloat(list.sel) * TagEditListView.rowH,
                       width: list.frame.width, height: TagEditListView.rowH)
        list.scrollToVisible(r)
    }

    private func activateSelected() {
        if let s = listView?.sel { activate(s) }
    }

    /// Activate row `i`: toggle a tag, or create + check a new one. The panel
    /// stays open so several tags can be toggled in one session.
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
            selectLast()              // reveal the freshly-created tag
        }
    }

    /// Select + scroll to the last row (the just-created tag, appended to the
    /// end after the filter clears).
    private func selectLast() {
        guard let list = listView, !list.rows.isEmpty else { return }
        list.sel = list.rows.count - 1
        list.needsDisplay = true
        list.scrollToVisible(NSRect(
            x: 0, y: CGFloat(list.sel) * TagEditListView.rowH,
            width: list.frame.width, height: TagEditListView.rowH))
    }

    // MARK: - Geometry

    private func panelWidth(appName: String, title: String) -> CGFloat {
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

    // MARK: - Event monitors

    private func installMonitors() {
        // Click in another app closes the panel.
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { _ in
                MainActor.assumeIsolated {
                    guard !PopupMenu.shared.isOpen else { return }
                    TagEditPanel.shared.close()
                }
            }) as Any)
        // Keys + clicks inside facet.
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] ev in
            guard let self, let panel = self.panel else { return ev }
            if PopupMenu.shared.isOpen { return ev }
            if ev.type == .keyDown {
                // IME composing: let the field handle everything.
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
            // A click anywhere but our own panel closes it. The click still
            // falls through (monitors observe, don't swallow) so the row's
            // normal action runs — closing without retargeting, per spec.
            if ev.window !== panel { self.close() }
            return ev
        } as Any)
    }

    // MARK: - NSTextFieldDelegate

    public func controlTextDidChange(_ note: Notification) {
        recompute()
    }
}
