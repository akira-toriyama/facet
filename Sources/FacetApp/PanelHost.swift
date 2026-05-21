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
    let gripBR: GripView   // bottom-right (default, primary)
    let gripBL: GripView   // bottom-left
    let gripTR: GripView   // top-right
    let gripTL: GripView   // top-left
    var grips: [GripView] { [gripBR, gripBL, gripTR, gripTL] }
    let searchBar: SearchBar
    private let view: SidebarView

    // MARK: - Persisted geometry

    private(set) var anchorTL: NSPoint      // top-left in screen coords
    private(set) var userWidth: CGFloat = sidebarWidth
    private(set) var userHeight: CGFloat?   // nil = auto (content height)

    // MARK: - Tunables

    private static let defaultsKey = "panelGeom"   // "x,y,w,h" (h<=0 = auto)
    private let gripSize: CGFloat = 80         // hit area; chevron visual stays compact via GripView.draw
    private let scrollerInset: CGFloat = 8     // right grips skirt the overlay scroller (~14 px visible, 8 leaves a sliver)
    private let gripBottomInset: CGFloat = 0   // bottom grips flush with panel bottom; round-corner overlap accepted
    private let topClearance: CGFloat = 16     // empty band at panel top so TL/TR grips don't sit over the WS-header row + master_stack pill
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

        gripBR = GripView(frame: .zero, corner: .bottomRight)
        gripBL = GripView(frame: .zero, corner: .bottomLeft)
        gripTR = GripView(frame: .zero, corner: .topRight)
        gripTL = GripView(frame: .zero, corner: .topLeft)
        view.grips = [gripBR, gripBL, gripTR, gripTL]

        effect.addSubview(bgView)
        effect.addSubview(scroll)
        effect.addSubview(searchBar)
        effect.addSubview(gripBR)
        effect.addSubview(gripBL)
        effect.addSubview(gripTR)
        effect.addSubview(gripTL)

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
        // Required for mouseMoved + cursorUpdate delivery to views on
        // a non-key panel. Without this, GripView's NSTrackingArea
        // (cursor change on hover) silently doesn't fire.
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary]
        panel.contentView = effect
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    func show() {
        layout(contentHeight: view.contentHeight,
               searching: view.searching)
        // Regardless variant primes the panel as a key-candidate
        // even when the app isn't active — required for cursor /
        // mouseDragged delivery on a .nonactivatingPanel agent.
        panel.orderFrontRegardless()
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

    /// Resize from any corner — the opposite corner stays anchored.
    /// dx/dy come from NSEvent.delta*; sign multipliers + anchor
    /// updates derive from `corner`.
    func resizeBy(dx: CGFloat, dy: CGFloat, corner: GripCorner) {
        let scr = NSScreen.main?.frame ?? panel.frame
        let maxW = scr.width - 2 * screenMargin
        let maxH = scr.height - 2 * screenMargin
        let curW = userWidth
        let curH = panel.frame.height

        // sign: which direction of drag grows the panel
        let dwSign: CGFloat = (corner == .bottomRight || corner == .topRight) ? 1 : -1
        let dhSign: CGFloat = (corner == .bottomRight || corner == .bottomLeft) ? 1 : -1

        let newW = min(max(curW + dx * dwSign, minWidth), maxW)
        let newH = min(max(curH + dy * dhSign, minHeight), maxH)

        userWidth = newW
        userHeight = newH

        // Anchor: keep the opposite corner of the drag fixed.
        // anchorTL is the panel's top-left in screen coords.
        switch corner {
        case .bottomRight:
            break // top-left already fixed
        case .bottomLeft:
            // top-right fixed → shift top-left.x so right edge stays
            anchorTL.x = (anchorTL.x + curW) - newW
        case .topRight:
            // bottom-left fixed → shift top-left.y so bottom edge stays
            anchorTL.y = anchorTL.y + (newH - curH)
        case .topLeft:
            // bottom-right fixed → shift both
            anchorTL.x = (anchorTL.x + curW) - newW
            anchorTL.y = anchorTL.y + (newH - curH)
        }

        view.frame.size.width = newW
        view.relayout()
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
        // Top grips hide while searching (would overlap the search
        // field band). When visible, reserve `topClearance` so they
        // don't sit over the WS-header row inside the scroll content.
        let topGripsVisible = !searching
        let topClear: CGFloat = topGripsVisible ? topClearance : 0
        scroll.frame = NSRect(x: 0, y: 0,
                              width: frame.width,
                              height: frame.height - sh - topClear)
        // 4 corner grips. Right-side grips inset by scrollerInset to
        // dodge the overlay scroller. Top grips sit in the cleared
        // band at the panel's top edge.
        let rx = frame.width - gripSize - scrollerInset   // right grips x
        let ty = frame.height - gripSize - sh             // top grips top-flush
        gripBR.frame = NSRect(x: rx, y: gripBottomInset,
                              width: gripSize, height: gripSize)
        gripBL.frame = NSRect(x: 0, y: gripBottomInset,
                              width: gripSize, height: gripSize)
        gripTR.frame = NSRect(x: rx, y: ty,
                              width: gripSize, height: gripSize)
        gripTL.frame = NSRect(x: 0, y: ty,
                              width: gripSize, height: gripSize)
        gripTR.isHidden = !topGripsVisible
        gripTL.isHidden = !topGripsVisible
        view.frame = NSRect(x: 0, y: 0, width: frame.width,
                            height: max(contentH, h - sh - topClear))
        // Lock min == max == current to tell macOS this window
        // isn't user-resizable. Without this, the system surfaces
        // edge / corner auto resize cursors at the panel boundary
        // even on .borderless / non-.resizable panels. Our own
        // resizeBy uses setFrame() which bypasses these limits.
        panel.minSize = frame.size
        panel.maxSize = frame.size
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
