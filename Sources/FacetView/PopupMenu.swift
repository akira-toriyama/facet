// In-process popup menu — fully drawn with `pal`, keyboard-navigable,
// closes on any click outside or Escape. Replaces NSMenu for the
// right-click window menu and the layout-mode picker so the menu can
// match the panel's theme (NSMenu can't).
//
// Singleton (`PopupMenu.shared`) because at most one popup is open at
// a time and the global mouse / key monitors need a fixed owner to
// detach themselves cleanly.

import AppKit

public final class PopupMenuView: NSView {
    public var header = ""
    public var items: [String] = []
    public var checkedIndex: Int?
    public var onPick: ((Int) -> Void)?
    public var sel: Int?                       // highlighted item (mouse + keyboard)

    /// Indices in `items` that are non-pickable SECTION LABELS (drawn dim,
    /// skipped by keyboard nav + clicks). Lets one menu group items under
    /// inline headers (the tag-world menu's `Layout` / `Tags` sections).
    /// Only honored in the non-filterable path. Empty = a flat menu.
    public var headerRows: Set<Int> = []

    /// Per-row icon specs (`SF:<name>` etc., resolved by `IconResolver`),
    /// PARALLEL to the FULL item list (`allItems`) — looked up by the
    /// original index so filtering keeps them aligned. Empty / all-empty =
    /// a text-only menu (the icon column collapses, preserving the old
    /// layout). Section-label rows ignore their slot. (item 7)
    public var icons: [String] = []

    /// Per-row icon + text tint (PARALLEL to `allItems`; `nil` = the
    /// default `primary`-if-current / `foreground` rule). Drives the
    /// layout→primary / tag→secondary colour scheme (item 10) and the
    /// destructive→error accent, computed by the menu builder.
    public var rowTints: [NSColor?] = []

    /// Reserved icon-column width — non-zero only when at least one row
    /// carries an icon, so text-only menus keep their original indent.
    /// Wide enough for a `.large`-scale SF Symbol (~20pt) plus breathing
    /// room.
    private var iconColW: CGFloat { icons.contains { !$0.isEmpty } ? 26 : 0 }
    /// Left edge of the label text: checkmark gutter (+18) then the icon
    /// column when present.
    private var textIndent: CGFloat { Self.padX + 18 + iconColW }

    /// Palette the menu is drawn in (PR-B). Set by `PopupMenu.show` to
    /// the INVOKING surface's palette, so a menu popped from the tree /
    /// grid / rail matches that surface's per-view theme.
    public var palette: ResolvedPalette = resolve(.terminal)

    /// Move the keyboard selection one step in `d`'s direction, skipping
    /// section-label rows (`headerRows`) and stopping at the ends.
    public func move(_ d: Int) {
        guard !items.isEmpty else { return }
        let dir = d >= 0 ? 1 : -1
        var i = sel ?? (dir > 0 ? -1 : items.count)
        repeat { i += dir } while i >= 0 && i < items.count
            && headerRows.contains(i)
        if i >= 0, i < items.count { sel = i; needsDisplay = true }
    }

    /// Activate the keyboard-selected item (closes the menu first,
    /// matching mouse-click behavior).
    public func pickSelected() {
        guard let s = sel else { return }
        let pick = onPick
        PopupMenu.shared.close()
        pick?(origIndex(s))
    }

    static let padX: CGFloat = 14
    static let headerH: CGFloat = 26
    static let sepH: CGFloat = 9
    static let rowH: CGFloat = 26
    static let padV: CGFloat = 6
    static let fieldH: CGFloat = 30
    static let fieldGap: CGFloat = 6

    /// Filter box (the `m` / keyboard path): when on, a `⌕` box sits between
    /// the header and the rows and the menu becomes type-to-filter, matching
    /// the `t` tag panel. `allItems` is the full list, `items` the filtered
    /// subset shown, `rowMap` maps a shown row back to its index in `allItems`
    /// (what `onPick` reports). `filter` is the typed string, accumulated by
    /// `PopupMenu`'s key monitor — there is NO real `NSTextField`: a filterable
    /// menu must not take key focus or the tree panel resigns key and its
    /// kbNav tears down (only `TagEditPanel` is guarded in `handlePanelKeyChange`).
    /// The labels are ASCII menu verbs, so the drawn box (no caret blink / IME)
    /// is indistinguishable in use.
    public var filterable = false
    public var allItems: [String] = []
    public var rowMap: [Int] = []
    public var filter = ""

    public override var isFlipped: Bool { true }

    /// Extra vertical band the filter box claims (0 when not filterable).
    private var fieldBand: CGFloat { filterable ? Self.fieldGap + Self.fieldH : 0 }
    /// Y of the first item row — below the header, the filter band and the
    /// divider. Collapses to the original layout when not filterable.
    private var rowsTop: CGFloat { Self.padV + Self.headerH + fieldBand + Self.sepH }
    /// Map a shown-row index to the original `allItems` index (`onPick`'s
    /// contract). Identity when `rowMap` is empty (non-filterable menus).
    private func origIndex(_ shown: Int) -> Int {
        (shown >= 0 && shown < rowMap.count) ? rowMap[shown] : shown
    }

    public func contentSize() -> NSSize {
        let hf = uiFont(12, .bold)
        let rf = uiFont(13, .regular)
        var w = (header as NSString)
            .size(withAttributes: [.font: hf]).width
        // Width keys off the FULL list (so it doesn't jitter as you filter)
        // plus the placeholder, when filterable.
        for m in (filterable ? allItems : items) {
            w = max(w, (m as NSString).size(withAttributes: [.font: rf]).width)
        }
        if filterable {
            w = max(w, ("Filter…" as NSString)
                .size(withAttributes: [.font: rf]).width + 20)
        }
        let width = min(max(w + Self.padX * 2 + 26 + iconColW, 170), 340)
        // Reserve a row for the "no match" hint so the box never collapses.
        let rowCount = filterable ? max(items.count, 1) : items.count
        let h = Self.padV + Self.headerH + fieldBand + Self.sepH
            + CGFloat(rowCount) * Self.rowH + Self.padV
        return NSSize(width: width, height: h)
    }

    private func rowIndex(at p: NSPoint) -> Int? {
        let top = rowsTop
        guard p.y >= top else { return nil }
        let i = Int((p.y - top) / Self.rowH)
        return (i >= 0 && i < items.count && !headerRows.contains(i)) ? i : nil
    }

    public override func draw(_ dirty: NSRect) {
        let bg = palette.background ?? NSColor.windowBackgroundColor
        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 9, yRadius: 9)
        bg.setFill(); card.fill()
        palette.border.setStroke(); card.lineWidth = 1; card.stroke()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        (header as NSString).draw(
            in: NSRect(x: Self.padX, y: Self.padV + 5,
                       width: bounds.width - Self.padX * 2,
                       height: Self.headerH),
            withAttributes: [.font: uiFont(12, .bold),
                             .foregroundColor: palette.primary,
                             .paragraphStyle: para])

        // Filter box (mirrors the `t` panel's ⌕ field) — drawn, not a real
        // NSTextField; `filter` is fed by PopupMenu's key monitor.
        if filterable {
            let fb = NSRect(x: Self.padX,
                            y: Self.padV + Self.headerH + Self.fieldGap,
                            width: bounds.width - Self.padX * 2,
                            height: Self.fieldH)
            let path = NSBezierPath(roundedRect: fb, xRadius: 7, yRadius: 7)
            (bg.blended(withFraction: 0.06, of: .white) ?? bg).setFill(); path.fill()
            palette.border.setStroke(); path.lineWidth = 1; path.stroke()
            if let icon = IconResolver.resolve(
                "SF:magnifyingglass", pointSize: 13, color: palette.muted) {
                let isz = icon.size
                icon.draw(in: NSRect(x: fb.minX + 8,
                                     y: fb.minY + (fb.height - isz.height) / 2,
                                     width: isz.width, height: isz.height))
            }
            let textX = fb.minX + 28
            let textRect = NSRect(x: textX, y: fb.minY + 6,
                                  width: fb.maxX - textX - 8, height: fb.height - 12)
            if filter.isEmpty {
                ("Filter…" as NSString).draw(
                    in: textRect,
                    withAttributes: [.font: uiFont(13, .regular),
                                     .foregroundColor: palette.muted,
                                     .paragraphStyle: para])
            } else {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: uiFont(13, .regular),
                    .foregroundColor: palette.foreground,
                    .paragraphStyle: para]
                (filter as NSString).draw(in: textRect, withAttributes: attrs)
                let tw = (filter as NSString)
                    .size(withAttributes: [.font: uiFont(13, .regular)]).width
                let caretX = min(textX + tw + 1.5, textRect.maxX)
                palette.primary.setStroke()
                let caret = NSBezierPath()
                caret.move(to: NSPoint(x: caretX, y: fb.minY + 7))
                caret.line(to: NSPoint(x: caretX, y: fb.maxY - 7))
                caret.lineWidth = 1.5; caret.stroke()
            }
        }

        let sy = rowsTop - Self.sepH / 2
        palette.border.setStroke()
        let sp = NSBezierPath()
        sp.move(to: NSPoint(x: Self.padX, y: sy))
        sp.line(to: NSPoint(x: bounds.width - Self.padX, y: sy))
        sp.stroke()

        let top = rowsTop
        // Filtered to nothing: a quiet hint instead of a blank gap.
        if filterable, items.isEmpty {
            ("No match" as NSString).draw(
                in: NSRect(x: Self.padX + 18, y: top + 5,
                           width: bounds.width - Self.padX * 2 - 18,
                           height: Self.rowH - 6),
                withAttributes: [.font: uiFont(13, .regular),
                                 .foregroundColor: palette.muted,
                                 .paragraphStyle: para])
        }
        for (i, m) in items.enumerated() {
            let r = NSRect(x: 0, y: top + CGFloat(i) * Self.rowH,
                           width: bounds.width, height: Self.rowH)
            if headerRows.contains(i) {
                // Section label: dim + bold, no fill / checkmark / indent.
                (m.uppercased() as NSString).draw(
                    in: NSRect(x: Self.padX, y: r.minY + 7,
                               width: r.width - Self.padX * 2,
                               height: r.height - 7),
                    withAttributes: [.font: uiFont(10, .bold),
                                     .foregroundColor: palette.muted,
                                     .paragraphStyle: para])
                continue
            }
            if sel == i {
                let pill = r.insetBy(dx: 5, dy: 2)
                palette.selection.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
                palette.primary.setStroke()
                let o = NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1),
                                     xRadius: 6, yRadius: 6)
                o.lineWidth = 1.5; o.stroke()
            }
            let isCur = (origIndex(i) == checkedIndex)
            // Per-row tint (item 10: layout→primary, tag→secondary,
            // destructive→error) overrides the default current/normal rule.
            let tint = origIndex(i) < rowTints.count ? rowTints[origIndex(i)] : nil
            let fg = tint ?? (isCur ? palette.primary : palette.foreground)
            // Leading icon (item 7) — drawn in the reserved column between
            // the checkmark gutter and the label, tinted to match the row.
            let iconSpec = origIndex(i) < icons.count ? icons[origIndex(i)] : ""
            if iconColW > 0, !iconSpec.isEmpty,
               let icon = IconResolver.resolve(iconSpec, fontSize: 13, color: fg) {
                let isz = icon.size
                icon.draw(in: NSRect(
                    x: Self.padX + 18 + (iconColW - isz.width) / 2,
                    y: r.minY + (Self.rowH - isz.height) / 2,
                    width: isz.width, height: isz.height))
            }
            (m as NSString).draw(
                in: NSRect(x: textIndent, y: r.minY + 5,
                           width: r.width - textIndent - Self.padX,
                           height: r.height - 6),
                withAttributes: [
                    .font: uiFont(13, isCur ? .semibold : .regular),
                    .foregroundColor: fg,
                    .paragraphStyle: para,
                ])
            if isCur {
                ("✓" as NSString).draw(
                    in: NSRect(x: Self.padX, y: r.minY + 5,
                               width: 16, height: r.height - 6),
                    withAttributes: [.font: uiFont(12, .bold),
                                     .foregroundColor: palette.primary])
            }
        }
    }

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
        // Mouse hover and keyboard selection are ONE highlight in a
        // pick-one menu (NSMenu / VS Code model): moving the pointer over
        // a row makes it THE selection, so Enter/click act on the same
        // row the eye is on. Don't clear when the pointer slips off a row
        // — keep the last highlighted item (no flicker, kb nav survives).
        if let i = rowIndex(at: convert(e.locationInWindow, from: nil)),
           i != sel { sel = i; needsDisplay = true }
    }

    public override func mouseUp(with e: NSEvent) {
        if let i = rowIndex(at: convert(e.locationInWindow, from: nil)) {
            let pick = onPick
            PopupMenu.shared.close()
            pick?(origIndex(i))
        }
    }
}

@MainActor
public final class PopupMenu {
    public static let shared = PopupMenu()
    private var panel: NSPanel?
    private weak var menuView: PopupMenuView?
    private var monitors: [Any] = []
    private var filterable = false
    private var allItems: [String] = []
    private var filter = ""
    public var isOpen: Bool { panel != nil }

    private init() {}

    /// `filterable` adds a `⌕` box and type-to-filter (the `m` keyboard path,
    /// mirroring the `t` tag panel). Only pass it from a surface that KEEPS key
    /// focus (the tree panel in `--active`): the menu deliberately never becomes
    /// key — were it a real `KeyablePanel` the tree would resign key and its
    /// kbNav would tear down — so the typed string is captured by this object's
    /// local key monitor below (which only fires while facet is key).
    public func show(at screenPt: NSPoint,
                     header: String,
                     items: [String],
                     checkedIndex: Int?,
                     palette: ResolvedPalette,
                     filterable: Bool = false,
                     headerRows: Set<Int> = [],
                     icons: [String] = [],
                     rowTints: [NSColor?] = [],
                     onPick: @escaping (Int) -> Void) {
        close()
        self.filterable = filterable
        self.allItems = items
        self.filter = ""
        let v = PopupMenuView()
        v.palette = palette
        v.header = header
        v.items = items
        v.filterable = filterable
        v.headerRows = headerRows
        v.icons = icons
        v.rowTints = rowTints
        v.allItems = items
        v.rowMap = Array(items.indices)
        v.checkedIndex = checkedIndex
        v.onPick = onPick
        // kb start point: the checked row, else the first non-section row.
        v.sel = checkedIndex
            ?? items.indices.first { !headerRows.contains($0) }
        menuView = v
        let size = v.contentSize()

        var origin = NSPoint(x: screenPt.x, y: screenPt.y - size.height)
        if let vis = NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 4),
                           vis.maxX - size.width - 4)
            if origin.y < vis.minY + 4 { origin.y = screenPt.y }  // flip up
            origin.y = min(origin.y, vis.maxY - size.height - 4)
        }
        let pnl = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        pnl.isFloatingPanel = true
        pnl.level = .popUpMenu
        pnl.backgroundColor = .clear
        pnl.isOpaque = false
        pnl.hasShadow = true
        pnl.becomesKeyOnlyIfNeeded = true
        pnl.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                  .fullScreenAuxiliary]
        v.frame = NSRect(origin: .zero, size: size)
        pnl.contentView = v
        pnl.orderFrontRegardless()
        panel = pnl

        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { _ in
                MainActor.assumeIsolated { Self.shared.close() }
            }) as Any)
        // Esc-to-close even when facet isn't the active app. The local
        // keyDown monitor below only fires while facet is key (e.g.
        // --active kb-nav); a right-click menu opens without activating
        // facet, so Esc would otherwise never reach it. Global monitors
        // observe (can't swallow) — fine for Esc: closing is all we need.
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown],
            handler: { ev in
                guard ev.keyCode == 53 else { return }   // Esc
                MainActor.assumeIsolated { Self.shared.close() }
            }) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] ev in
            guard let self else { return ev }
            if ev.type == .keyDown {
                // Keyboard-navigable; swallow all keys while open so
                // they don't leak to facet / the window behind.
                let raw = ev.charactersIgnoringModifiers
                let c = raw?.lowercased()
                let ctrl = ev.modifierFlags.contains(.control)
                let cmd = ev.modifierFlags.contains(.command)
                switch ev.keyCode {
                case 53:      self.close()                      // Esc
                case 36, 76:  self.menuView?.pickSelected()     // Return
                case 125:     self.menuView?.move(1)            // ↓
                case 126:     self.menuView?.move(-1)           // ↑
                case 51 where self.filterable:                  // Delete
                    if !self.filter.isEmpty {
                        self.filter.removeLast(); self.applyFilter()
                    }
                default:
                    if self.filterable {
                        // Type-to-filter: letters build the query; only the
                        // arrows + ctrl-n/p navigate (j/k are filter input now).
                        if ctrl, c == "n" { self.menuView?.move(1) }
                        else if ctrl, c == "p" { self.menuView?.move(-1) }
                        else if !ctrl, !cmd, let ch = raw, ch.count == 1,
                                let s = ch.unicodeScalars.first,
                                s.value >= 0x20, s.value != 0x7F,
                                s.value < 0xF700 {   // exclude fn-key PUA block
                            self.filter.append(ch); self.applyFilter()
                        }
                    } else {
                        if c == "j" || (ctrl && c == "n") {
                            self.menuView?.move(1)
                        } else if c == "k" || (ctrl && c == "p") {
                            self.menuView?.move(-1)
                        }
                    }
                }
                return nil
            }
            if ev.window !== self.panel { self.close() }  // click outside
            return ev
        } as Any)
    }

    /// Rebuild the shown rows from `filter` and resize the panel (top-pinned),
    /// mirroring the `t` panel. Substring, case-insensitive; `rowMap` keeps
    /// `onPick` reporting the original `allItems` index.
    private func applyFilter() {
        guard let v = menuView else { return }
        let q = filter.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            v.items = allItems
            v.rowMap = Array(allItems.indices)
        } else {
            var shown: [String] = []
            var map: [Int] = []
            for (i, label) in allItems.enumerated()
            where label.localizedCaseInsensitiveContains(q) {
                shown.append(label); map.append(i)
            }
            v.items = shown; v.rowMap = map
        }
        v.filter = filter
        // Highlight the top match so type → Return picks it (command-menu
        // convention); empty result clears the selection.
        v.sel = v.items.isEmpty ? nil : 0
        resizeKeepingTop()
        v.needsDisplay = true
    }

    /// Resize the panel to the current content height, keeping its top edge
    /// fixed (the menu hangs from the row it was opened at). Width is stable
    /// (keyed off the full list), so only height moves; clamped on-screen.
    private func resizeKeepingTop() {
        guard let pnl = panel, let v = menuView else { return }
        let size = v.contentSize()
        guard abs(size.height - pnl.frame.height) > 0.5 else { return }
        let top = pnl.frame.maxY
        var f = pnl.frame
        f.size.height = size.height
        f.origin.y = top - size.height
        if let vis = NSScreen.main?.visibleFrame {
            f.origin.y = max(f.origin.y, vis.minY + 4)
            f.origin.y = min(f.origin.y, vis.maxY - size.height - 4)
        }
        pnl.setFrame(f, display: true)
        v.frame = NSRect(origin: .zero, size: f.size)
    }

    public func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        filterable = false
        allItems = []
        filter = ""
    }
}
