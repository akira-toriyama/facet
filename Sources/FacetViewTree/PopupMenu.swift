// In-process popup menu — fully drawn with `pal`, keyboard-navigable,
// closes on any click outside or Escape. Replaces NSMenu for the
// right-click window menu and the layout-mode picker so the menu can
// match the panel's theme (NSMenu can't).
//
// Singleton (`PopupMenu.shared`) because at most one popup is open at
// a time and the global mouse / key monitors need a fixed owner to
// detach themselves cleanly.

import AppKit
import FacetView

public final class PopupMenuView: NSView {
    public var header = ""
    public var items: [String] = []
    public var checkedIndex: Int?
    public var onPick: ((Int) -> Void)?
    private var hover: Int?
    public var sel: Int?                       // keyboard-highlighted item

    /// Move the keyboard selection (clamped to [0, items.count - 1]).
    public func move(_ d: Int) {
        guard !items.isEmpty else { return }
        sel = min(max((sel ?? 0) + d, 0), items.count - 1)
        needsDisplay = true
    }

    /// Activate the keyboard-selected item (closes the menu first,
    /// matching mouse-click behavior).
    public func pickSelected() {
        guard let s = sel else { return }
        let pick = onPick
        PopupMenu.shared.close()
        pick?(s)
    }

    static let padX: CGFloat = 14
    static let headerH: CGFloat = 26
    static let sepH: CGFloat = 9
    static let rowH: CGFloat = 26
    static let padV: CGFloat = 6

    public override var isFlipped: Bool { true }

    public func contentSize() -> NSSize {
        let hf = uiFont(12, .bold)
        let rf = uiFont(13, .regular)
        var w = (header as NSString)
            .size(withAttributes: [.font: hf]).width
        for m in items {
            w = max(w, (m as NSString).size(withAttributes: [.font: rf]).width)
        }
        let width = min(max(w + Self.padX * 2 + 26, 170), 340)
        let h = Self.padV + Self.headerH + Self.sepH
            + CGFloat(items.count) * Self.rowH + Self.padV
        return NSSize(width: width, height: h)
    }

    private func rowIndex(at p: NSPoint) -> Int? {
        let top = Self.padV + Self.headerH + Self.sepH
        guard p.y >= top else { return nil }
        let i = Int((p.y - top) / Self.rowH)
        return (i >= 0 && i < items.count) ? i : nil
    }

    public override func draw(_ dirty: NSRect) {
        let bg = pal.bg ?? NSColor.windowBackgroundColor
        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 9, yRadius: 9)
        bg.setFill(); card.fill()
        pal.divider.setStroke(); card.lineWidth = 1; card.stroke()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        (header as NSString).draw(
            in: NSRect(x: Self.padX, y: Self.padV + 5,
                       width: bounds.width - Self.padX * 2,
                       height: Self.headerH),
            withAttributes: [.font: uiFont(12, .bold),
                             .foregroundColor: pal.accent,
                             .paragraphStyle: para])
        let sy = Self.padV + Self.headerH + Self.sepH / 2
        pal.divider.setStroke()
        let sp = NSBezierPath()
        sp.move(to: NSPoint(x: Self.padX, y: sy))
        sp.line(to: NSPoint(x: bounds.width - Self.padX, y: sy))
        sp.stroke()

        let top = Self.padV + Self.headerH + Self.sepH
        for (i, m) in items.enumerated() {
            let r = NSRect(x: 0, y: top + CGFloat(i) * Self.rowH,
                           width: bounds.width, height: Self.rowH)
            if sel == i {
                let pill = r.insetBy(dx: 5, dy: 2)
                pal.selFill.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
                pal.accent.setStroke()
                let o = NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1),
                                     xRadius: 6, yRadius: 6)
                o.lineWidth = 1.5; o.stroke()
            } else if hover == i {
                pal.hoverFill.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 5, dy: 2),
                             xRadius: 6, yRadius: 6).fill()
            }
            let isCur = (i == checkedIndex)
            (m as NSString).draw(
                in: NSRect(x: Self.padX + 18, y: r.minY + 5,
                           width: r.width - Self.padX * 2 - 18,
                           height: r.height - 6),
                withAttributes: [
                    .font: uiFont(13, isCur ? .semibold : .regular),
                    .foregroundColor: isCur ? pal.accent : pal.text,
                    .paragraphStyle: para,
                ])
            if isCur {
                ("✓" as NSString).draw(
                    in: NSRect(x: Self.padX, y: r.minY + 5,
                               width: 16, height: r.height - 6),
                    withAttributes: [.font: uiFont(12, .bold),
                                     .foregroundColor: pal.accent])
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
        let i = rowIndex(at: convert(e.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }

    public override func mouseExited(with e: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    public override func mouseUp(with e: NSEvent) {
        if let i = rowIndex(at: convert(e.locationInWindow, from: nil)) {
            let pick = onPick
            PopupMenu.shared.close()
            pick?(i)
        }
    }
}

@MainActor
public final class PopupMenu {
    public static let shared = PopupMenu()
    private var panel: NSPanel?
    private weak var menuView: PopupMenuView?
    private var monitors: [Any] = []
    public var isOpen: Bool { panel != nil }

    private init() {}

    public func show(at screenPt: NSPoint,
                     header: String,
                     items: [String],
                     checkedIndex: Int?,
                     onPick: @escaping (Int) -> Void) {
        close()
        let v = PopupMenuView()
        v.header = header
        v.items = items
        v.checkedIndex = checkedIndex
        v.onPick = onPick
        v.sel = checkedIndex ?? (items.isEmpty ? nil : 0)  // kb start point
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
                let c = ev.charactersIgnoringModifiers?.lowercased()
                let ctrl = ev.modifierFlags.contains(.control)
                switch ev.keyCode {
                case 53:      self.close()                      // Esc
                case 36, 76:  self.menuView?.pickSelected()     // Return
                case 125:     self.menuView?.move(1)            // ↓
                case 126:     self.menuView?.move(-1)           // ↑
                default:
                    if c == "j" || (ctrl && c == "n") {
                        self.menuView?.move(1)
                    } else if c == "k" || (ctrl && c == "p") {
                        self.menuView?.move(-1)
                    }
                }
                return nil
            }
            if ev.window !== self.panel { self.close() }  // click outside
            return ev
        } as Any)
    }

    public func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }
}
