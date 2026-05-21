// Panel scaffolding for the tree view. Owns the `NSPanel`, the
// `NSVisualEffectView` backdrop, the scroll view holding
// `SidebarView`, the resize grip, and the search bar above the
// list. Provides show / hide / move / resize / persist + the
// single-source-of-truth `layout(contentHeight:searching:)` —
// every geometry change inside the panel funnels through it.
//
// Knows nothing about backends, AX, refresh ticks, or the
// distributed-notification IPC. Those live one layer up in
// `Controller`.

import AppKit
import FacetCore
import FacetView
import FacetViewTree

@MainActor
final class PanelHost {

    // MARK: - Chrome

    let panel: NSPanel
    private let effect: NSVisualEffectView
    private let scroll: NSScrollView
    private let bgView = NSView()
    let grip: GripView
    let searchBar: SearchBar
    private let view: SidebarView

    // MARK: - Persisted geometry

    private(set) var anchorTL: NSPoint      // top-left in screen coords
    private(set) var userWidth: CGFloat = sidebarWidth
    private(set) var userHeight: CGFloat?   // nil = auto (content height)

    // MARK: - Tunables

    private static let defaultsKey = "panelGeom"   // "x,y,w,h" (h<=0 = auto)
    private let gripSize: CGFloat = 24    // touch target — 16 px too tight
    private let screenMargin: CGFloat = 8
    private let searchRowH: CGFloat = 34           // band when searching
    private let minWidth: CGFloat = 160
    private let minHeight: CGFloat = 140

    // MARK: - Init

    init(view: SidebarView) {
        self.view = view

        let scr = NSScreen.main?.frame ?? NSRect(x: 0, y: 0,
                                                 width: 1440, height: 900)
        anchorTL = NSPoint(x: scr.minX + screenMargin,
                           y: scr.maxY - screenMargin)
        if let s = UserDefaults.standard
            .string(forKey: Self.defaultsKey) {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count >= 2 { anchorTL = NSPoint(x: p[0], y: p[1]) }
            if p.count >= 3, p[2] >= minWidth { userWidth = CGFloat(p[2]) }
            if p.count >= 4, p[3] > 0 { userHeight = CGFloat(p[3]) }
        }

        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        // Flipped clipView so the documentView (SidebarView) is
        // top-anchored — without this, shrinking the panel via the
        // grip leaves rows pinned to the bottom (the "top blank on
        // resize" symptom, memory grid-branch-grip-intermittent).
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = view

        effect = NSVisualEffectView()
        effect.material = .sidebar     // shown only when pal.bg == nil
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        // Vibrancy isn't clipped by cornerRadius alone (faint square
        // edge); a rounded mask image actually clips the backdrop.
        effect.maskImage = Self.roundedMaskImage(12)

        // Opaque backdrop for the terminal theme; clear keeps vibrancy.
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 12
        bgView.layer?.cornerCurve = .continuous
        bgView.layer?.masksToBounds = true
        bgView.layer?.backgroundColor = (pal.bg ?? .clear).cgColor

        searchBar = SearchBar(frame: .zero)
        searchBar.isHidden = true
        searchBar.applyTheme()

        grip = GripView(frame: NSRect(x: 0, y: 0,
                                      width: gripSize, height: gripSize))

        effect.addSubview(bgView)
        effect.addSubview(scroll)
        effect.addSubview(searchBar)
        effect.addSubview(grip)

        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: sidebarWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        // One above the preview overlay (also .statusBar) so the
        // panel always stays operable on top of any preview.
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary]
        panel.contentView = effect
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    func show() {
        layout(contentHeight: view.contentHeight,
               searching: view.searching)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Make the panel key (used by `--active` keyboard-nav mode).
    /// Controller handles NSApp activation policy around this call.
    func makeKey() {
        panel.makeKeyAndOrderFront(nil)
    }

    func resignKey() {
        panel.makeFirstResponder(nil)
    }

    // MARK: - Geometry

    func movePanel(by d: CGSize) {
        var o = panel.frame.origin
        o.x += d.width; o.y += d.height
        panel.setFrameOrigin(o)
        anchorTL = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    /// Resize from the bottom-right grip; top-left stays anchored.
    func resizeBy(dx: CGFloat, dy: CGFloat) {
        let scr = NSScreen.main?.frame ?? panel.frame
        let maxW = scr.width - 2 * screenMargin
        let maxH = scr.height - 2 * screenMargin
        userWidth = min(max(userWidth + dx, minWidth), maxW)
        let curH = panel.frame.height
        userHeight = min(max(curH + dy, minHeight), maxH)
        view.frame.size.width = userWidth
        view.relayout()                          // re-truncate to new width
        layout(contentHeight: view.contentHeight,
               searching: view.searching)
    }

    func persistPosition() {
        UserDefaults.standard.set(
            "\(anchorTL.x),\(anchorTL.y),\(userWidth),\(userHeight ?? -1)",
            forKey: Self.defaultsKey)
    }

    /// Single source of truth for panel + subview frames. Called
    /// from `show`, `resizeBy`, `enterSearch` / `exitSearch`, and
    /// the refresh tick.
    func layout(contentHeight contentH: CGFloat, searching: Bool) {
        guard let scr = NSScreen.main?.frame else { return }
        let maxH = scr.height - 2 * screenMargin
        let h = min(userHeight ?? contentH, maxH)
        let w = userWidth
        var x = anchorTL.x, topY = anchorTL.y
        x = min(max(x, scr.minX), scr.maxX - w)
        topY = min(max(topY, scr.minY + h), scr.maxY)
        let frame = NSRect(x: x, y: topY - h, width: w, height: h)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        effect.frame = NSRect(origin: .zero, size: frame.size)
        bgView.frame = effect.bounds
        // Reserve a top band for the search field when filtering.
        let sh: CGFloat = searching ? searchRowH : 0
        searchBar.isHidden = !searching
        searchBar.frame = NSRect(x: 8, y: frame.height - sh + 5,
                                 width: frame.width - 16,
                                 height: max(sh - 9, 0))
        searchBar.needsLayout = true               // re-centre glyph/field
        scroll.frame = NSRect(x: 0, y: 0,
                              width: frame.width, height: frame.height - sh)
        grip.frame = NSRect(x: frame.width - gripSize, y: 0,
                            width: gripSize, height: gripSize)
        view.frame = NSRect(x: 0, y: 0, width: frame.width,
                            height: max(contentH, h - sh))
        panel.invalidateShadow()
    }

    // MARK: - Theme

    /// Re-apply the current `pal` to the panel chrome. Call after
    /// `paletteFor(...)` changes `pal`.
    func applyTheme() {
        bgView.layer?.backgroundColor = (pal.bg ?? .clear).cgColor
        searchBar.applyTheme()
    }

    // MARK: - Helpers

    /// Resizable rounded-rect mask (cap insets keep corners crisp
    /// at any panel size). Lifted from ws-tabs's `roundedMaskImage`.
    private static func roundedMaskImage(_ r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: d, height: d),
                     xRadius: r, yRadius: r).fill()
        img.unlockFocus()
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}
