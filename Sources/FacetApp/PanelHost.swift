// Panel scaffolding for the tree view. Owns the `NSPanel`, the
// `NSVisualEffectView` backdrop, the scroll view holding
// `SidebarView`, and the search bar above the list. Provides
// show / hide / move / resize / persist + the single-source-of-
// truth `layout(contentHeight:searching:)` — every geometry change
// inside the panel funnels through it.
//
// Resize is delegated to AppKit via `.resizable` in the styleMask;
// drag from any edge / corner of the panel chrome triggers an OS
// resize, which we mirror into our persisted geometry via
// `windowDidResize`. No custom grip view — sandbox A/B testing
// (sandbox/panel-resize-tester) showed the OS path is reliable on
// .borderless + .nonactivatingPanel once .resizable is set.
//
// Knows nothing about backends, AX, refresh ticks, or the
// distributed-notification IPC. Those live one layer up in
// `Controller`.

import AppKit
import FacetAccessibility
import FacetCore
import FacetView
import FacetViewTree

@MainActor
final class PanelHost: NSObject {

    // MARK: - Chrome

    let panel: KeyablePanel
    private let effect: NSVisualEffectView
    private let scroll: NSScrollView
    private let bgView = NSView()
    let searchBar: SearchBar
    private let view: SidebarView

    /// Outer panel border. Drawn as a layer (never a view) so it can't
    /// intercept clicks; sits above the chrome via `zPosition`, tracks
    /// the panel size in `applySubviewLayout`, and the theme accent in
    /// `applyTheme`. Foundation for the neon border-flash effect.
    private let borderLayer = CALayer()
    /// Active `[border]` effect (nil = off → plain theme-accent
    /// border), whether its neon glow is on, and the resting width.
    /// Set by `applyBorder(...)` from config.
    private var borderFx: BorderEffect?
    private var borderGlowOn = false
    private var borderW: CGFloat = 1.5
    /// WS-switch flash-burst timer, the rainbow hue-cycle timer, and
    /// its 0…1 phase. Both fire in `.common` mode (like the rail's
    /// slide) so they keep ticking during key-mash / interaction.
    private var flashTimer: Timer?
    private var cycleTimer: Timer?
    private var cyclePhase: CGFloat = 0
    /// Continuous-animation period — seconds per cycle (from `[border]
    /// cycle-seconds`); drives the rainbow hue AND the width breath.
    private var borderCycleSeconds: CGFloat = 6
    /// Width-breathing bounds (from `[border] min-width`/`max-width`).
    /// `nil` / max ≤ min → no breathing (fixed `borderW`).
    private var borderMinW: CGFloat?
    private var borderMaxW: CGFloat?

    /// Notified when the panel becomes / resigns key. Controller wires
    /// kbNav on/off here so a plain click on the tree panel (without
    /// --active) still enables keyboard navigation while the panel is
    /// focused.
    var onKeyChanged: ((Bool) -> Void)?

    // MARK: - Persisted geometry

    private(set) var anchorTL: NSPoint      // top-left in screen coords
    private(set) var userWidth: CGFloat = sidebarWidth
    private(set) var userHeight: CGFloat?   // nil = auto (content height)

    // MARK: - Tunables

    private static let defaultsKey = "panelGeom"   // "x,y,w,h" (h<=0 = auto)
    private let screenMargin: CGFloat = 8
    private let searchRowH: CGFloat = 34           // band when searching
    private let minWidth: CGFloat = 160
    private let minHeight: CGFloat = 140
    private let cornerRadius: CGFloat = 12

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
        scroll.autoresizingMask = [.width, .height]
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
        effect.autoresizingMask = [.width, .height]
        // Vibrancy isn't clipped by cornerRadius alone (faint square
        // edge); a rounded mask image actually clips the backdrop.
        effect.maskImage = Self.roundedMaskImage(12)

        // Opaque backdrop for the terminal theme; clear keeps vibrancy.
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 12
        bgView.layer?.cornerCurve = .continuous
        bgView.layer?.masksToBounds = true
        bgView.layer?.backgroundColor = (pal.bg ?? .clear).cgColor
        bgView.autoresizingMask = [.width, .height]

        searchBar = SearchBar(frame: .zero)
        searchBar.isHidden = true
        searchBar.applyTheme()
        searchBar.autoresizingMask = [.width, .minYMargin]

        effect.addSubview(bgView)
        effect.addSubview(scroll)
        effect.addSubview(searchBar)

        // Outer accent border, on top of the chrome. A layer (not a
        // view) can't intercept clicks; `zPosition` keeps it above the
        // subviews' layers and `cornerCurve = .continuous` matches the
        // panel's squircle. Frame is set in `applySubviewLayout`, color
        // in `applyTheme`. The border draws inside the layer bounds, so
        // it stays within `effect`'s masksToBounds clip.
        borderLayer.borderWidth = borderW
        borderLayer.borderColor = pal.accent.cgColor
        borderLayer.cornerRadius = cornerRadius
        borderLayer.cornerCurve = .continuous
        borderLayer.zPosition = 100
        effect.layer?.addSublayer(borderLayer)

        // .resizable in the styleMask gives us OS-standard edge /
        // corner resize on a borderless + .nonactivatingPanel. The
        // sandbox (sandbox/panel-resize-tester branch) confirmed
        // this works without a custom grip.
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: sidebarWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
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
        panel.setContentSize(NSSize(width: userWidth,
                                    height: userHeight ?? 400))
        panel.minSize = NSSize(width: minWidth, height: minHeight)
        panel.contentView = effect
        super.init()
        panel.delegate = self
    }

    // MARK: - Show / hide

    var isVisible: Bool { panel.isVisible }

    func show() {
        layout(contentHeight: view.contentHeight,
               searching: view.searching)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Make the panel key (used by `--active` keyboard-nav mode).
    /// Controller handles NSApp activation policy around this call.
    /// `wantsKey` gates `canBecomeKey`, so this is the ONLY path that
    /// lets the panel take key — a plain click never does.
    func makeKey() {
        panel.wantsKey = true
        panel.makeKeyAndOrderFront(nil)
    }

    func resignKey() {
        panel.wantsKey = false
        panel.makeFirstResponder(nil)
    }

    // MARK: - Geometry

    func movePanel(by d: CGSize) {
        var o = panel.frame.origin
        o.x += d.width; o.y += d.height
        panel.setFrameOrigin(o)
        anchorTL = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    /// Place the panel at an exact AppKit-screen rect (= bottom-left
    /// origin, x/y/w/h all in screen points). Used by CLI geometry
    /// flags so screenshot / automation scripts can pin the panel
    /// deterministically.
    func setExplicitFrame(_ frame: NSRect) {
        userWidth = frame.width
        userHeight = frame.height
        anchorTL = NSPoint(x: frame.minX, y: frame.maxY)
        layout(contentHeight: view.contentHeight,
               searching: view.searching)
        persistPosition()
    }

    func persistPosition() {
        UserDefaults.standard.set(
            "\(anchorTL.x),\(anchorTL.y),\(userWidth),\(userHeight ?? -1)",
            forKey: Self.defaultsKey)
    }

    /// Phase δ: respond to a display reconfiguration. When the
    /// persisted anchor / size no longer overlaps any visible
    /// display (external monitor unplugged, resolution change
    /// shrank a screen, etc.), snap the anchor to the nearest
    /// surviving display's centre (size preserved). Otherwise
    /// just re-run layout against the fresh NSScreen state —
    /// `layout()` already clamps to the main display, which
    /// re-validates against any updated bounds.
    @MainActor
    func handleDisplayReconfigure() {
        let h = (userHeight ?? view.contentHeight)
        // Convert anchorTL (top-left) → NSScreen-coord rect
        // (bottom-left origin: y = topY - height).
        let panelRect = NSRect(x: anchorTL.x,
                               y: anchorTL.y - h,
                               width: userWidth,
                               height: h)
        let displays = NSScreen.screens.map(\.frame)
        if !DisplayGeometry.isVisible(panelRect, in: displays),
           let dest = DisplayGeometry.nearestDisplay(
            to: panelRect, in: displays)
        {
            // Snap anchor to dest centre, preserving size.
            let newX = dest.midX - userWidth / 2
            let newTopY = dest.midY + h / 2
            anchorTL = NSPoint(x: newX, y: newTopY)
            persistPosition()
        }
        layout(contentHeight: view.contentHeight,
               searching: view.searching)
    }

    /// Single source of truth for panel + subview frames. Called
    /// from `show`, `enterSearch` / `exitSearch`, and the refresh
    /// tick. (Live OS resize is handled by autoresizingMask + the
    /// `windowDidResize` callback, not by re-running layout per
    /// drag event.)
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
        applySubviewLayout(searching: searching, contentH: contentH)
        panel.invalidateShadow()
    }

    /// Position the subviews to the panel's *current* size. Called
    /// from layout() and from windowDidResize (OS-driven resize).
    private func applySubviewLayout(searching: Bool, contentH: CGFloat) {
        let f = effect.bounds
        bgView.frame = f
        let sh: CGFloat = searching ? searchRowH : 0
        searchBar.isHidden = !searching
        searchBar.frame = NSRect(x: 8, y: f.height - sh + 5,
                                 width: f.width - 16,
                                 height: max(sh - 9, 0))
        searchBar.needsLayout = true
        scroll.frame = NSRect(x: 0, y: 0,
                              width: f.width, height: f.height - sh)
        view.frame = NSRect(x: 0, y: 0, width: f.width,
                            height: max(contentH, f.height - sh))
        // Border tracks the panel size. Disable the implicit layer
        // animation so it doesn't lag a frame behind a live resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = f
        CATransaction.commit()
    }

    // MARK: - Theme

    /// Re-apply the current `pal` to the panel chrome. Call after
    /// `paletteFor(...)` changes `pal`.
    func applyTheme() {
        bgView.layer?.backgroundColor = (pal.bg ?? .clear).cgColor
        applyBorderStyle()
        searchBar.applyTheme()
    }

    /// Apply the `[border]` config: pick the effect (nil = off → plain
    /// theme-accent border), its glow, and the resting line width.
    /// Called by the Controller at startup + on hot-reload.
    func applyBorder(effectName: String, glow: Bool, width: CGFloat,
                     cycleSeconds: CGFloat,
                     minWidth: CGFloat?, maxWidth: CGFloat?) {
        borderFx = borderEffectFor(effectName)
        borderGlowOn = glow && borderFx != nil
        borderW = width
        borderCycleSeconds = max(1, cycleSeconds)
        borderMinW = minWidth
        borderMaxW = maxWidth
        // Run the continuous loop when the effect cycles its hue
        // (rainbow) OR the width breathes — both ride `cycle-seconds`.
        let animate = borderFx != nil
            && ((borderFx?.cycles ?? false) || breathing)
        if animate { startCycle() } else { stopCycle() }
        applyBorderStyle()
    }

    /// Width oscillates min↔max? Needs an active effect + both bounds
    /// set with max > min.
    private var breathing: Bool {
        guard borderFx != nil, let lo = borderMinW, let hi = borderMaxW
        else { return false }
        return hi > lo
    }

    /// The current border width: breathing min↔max over `cycle-seconds`
    /// (smooth, via a raised cosine) when enabled, else the fixed width.
    private func currentWidth() -> CGFloat {
        guard breathing, let lo = borderMinW, let hi = borderMaxW
        else { return borderW }
        let pulse = (1 - CGFloat(cos(2 * Double.pi * Double(cyclePhase)))) / 2
        return lo + (hi - lo) * pulse
    }

    /// Flash the border: a 5-blink burst through the effect's flash
    /// palette (random, no consecutive repeat), then settle back to the
    /// steady look. No-op when the effect is off. Driven by a workspace
    /// switch (Controller.apply).
    func flashBorder() {
        guard let fx = borderFx, !fx.flash.isEmpty else { return }
        flashTimer?.invalidate()
        var idxs: [Int] = []
        var last = -1
        for _ in 0..<5 {
            var i = Int.random(in: 0..<fx.flash.count)
            if fx.flash.count > 1 { while i == last { i = Int.random(in: 0..<fx.flash.count) } }
            idxs.append(i); last = i
        }
        let seq = idxs.map { fx.flash[$0] }
        var step = 0
        // Ignore the timer arg (capturing it in a @MainActor closure
        // trips Swift 6 sendability); stop via the stored `flashTimer`,
        // mirroring the rail's slide loop.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if step < seq.count {
                    self.setFlashColor(seq[step]); step += 1
                } else {
                    self.flashTimer?.invalidate()
                    self.flashTimer = nil
                    self.applyBorderStyle()        // settle to steady
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    /// The resting border color: the cycling hue for rainbow, the
    /// effect's fixed steady color otherwise, or the theme accent when
    /// the effect is off.
    private func currentSteadyColor() -> NSColor {
        guard let fx = borderFx else { return pal.accent }
        if fx.cycles {
            return NSColor(hue: cyclePhase, saturation: 0.9,
                           brightness: 1, alpha: 1)
        }
        return fx.steady
    }

    /// Paint the border layer's resting look. The glow is a layer
    /// shadow in the steady color; it bleeds inward only (the panel's
    /// `masksToBounds` clips the outward bloom), reading as a neon
    /// inner-glow.
    private func applyBorderStyle() {
        let color = currentSteadyColor()
        let w = currentWidth()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.borderWidth = w
        borderLayer.borderColor = color.cgColor
        if borderGlowOn {
            borderLayer.shadowColor = color.cgColor
            borderLayer.shadowRadius = max(3, w * 3)
            borderLayer.shadowOpacity = 0.85
            borderLayer.shadowOffset = .zero
        } else {
            borderLayer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    /// One flash blink: the palette color at a slightly fatter width +
    /// stronger bloom for a neon pop. Restored by `applyBorderStyle` on
    /// settle. Honors `glow`.
    private func setFlashColor(_ c: NSColor) {
        let w = currentWidth()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.borderWidth = w + 1.5
        borderLayer.borderColor = c.cgColor
        if borderGlowOn {
            borderLayer.shadowColor = c.cgColor
            borderLayer.shadowRadius = max(5, w * 5)
            borderLayer.shadowOpacity = 0.95
            borderLayer.shadowOffset = .zero
        }
        CATransaction.commit()
    }

    /// Rainbow: rotate the resting hue ~once per 12 s. Paused during a
    /// flash burst so the two don't fight; the flash settles back onto
    /// the live cycle color.
    private func startCycle() {
        guard cycleTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCycle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cycleTimer = timer
    }

    private func stopCycle() {
        cycleTimer?.invalidate(); cycleTimer = nil
        cyclePhase = 0
    }

    private func tickCycle() {
        // Advance one 1/30 s tick's worth of a full rotation, so the
        // hue completes 0→1 in `borderCycleSeconds` seconds.
        cyclePhase += (1.0 / 30.0) / borderCycleSeconds
        if cyclePhase >= 1 { cyclePhase -= 1 }
        if flashTimer == nil { applyBorderStyle() }   // don't fight a flash
    }

    // MARK: - Helpers

    /// Resizable rounded-rect mask (cap insets keep corners crisp
    /// at any panel size).
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

// MARK: - NSWindowDelegate (mirror OS resize → our persisted state)

extension PanelHost: NSWindowDelegate {
    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated {
            let f = panel.frame
            userWidth = f.width
            userHeight = f.height
            anchorTL = NSPoint(x: f.minX, y: f.maxY)
            applySubviewLayout(searching: view.searching,
                               contentH: view.contentHeight)
            view.relayout()
        }
    }

    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        MainActor.assumeIsolated { persistPosition() }
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated { onKeyChanged?(true) }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { onKeyChanged?(false) }
    }
}
