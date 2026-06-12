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
    /// Pinned "Desktop N" grab band at the panel top — a sibling of the
    /// scroll view (never scrolls). Controller wires its `onResetGeometry`;
    /// PanelHost feeds its ordinal + sizes it in `applySubviewLayout`.
    let handleBar = HandleBar()

    /// Outer panel border. Drawn as a layer (never a view) so it can't
    /// intercept clicks; sits above the chrome via `zPosition`, tracks
    /// the panel size in `applySubviewLayout`. The look (effect color /
    /// glow / width / flash / breath) is driven by `borderFX`, shared
    /// with the grid + rail borders; `borderFX.apply(to:)` paints it.
    /// When the effect is off, `borderFX.color` falls back to
    /// `pal.primary`, so the panel keeps its plain accent border.
    private let borderLayer = CALayer()
    private let borderFX = BorderFX()

    /// Line-pets overlay — a transparent, click-through child window `pad`
    /// LARGER than the panel, drawing arcade sprites centred ON the panel's
    /// outer border (halo's pattern). A separate window because the panel's
    /// own `effect` view rounds + `masksToBounds`-clips at the edge, which
    /// would cut a border-centred sprite in half. Kept glued to the panel
    /// frame by `syncPetWindow()`.
    private let petPad: CGFloat = 24
    private let petView: PetWindowView
    private let petWindow: NSPanel

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

    private let screenMargin: CGFloat = 8
    private let searchRowH: CGFloat = 34           // band when searching
    private let minWidth: CGFloat = 160
    private let minHeight: CGFloat = 140
    private let cornerRadius: CGFloat = 12

    // MARK: - Init

    init(view: SidebarView) {
        self.view = view

        // Built-in default: top-left of the main screen, auto height.
        // The Controller seeds `[tree]` config geometry over this (via
        // setExplicitFrame) right after init; drags / resizes / CLI geom
        // are session-only — config.toml is the single place a panel
        // position / size persists (no UserDefaults store).
        //
        // `NSScreen.main` is the screen with the *key window*, which is
        // nil for this accessory app before the run loop starts (and
        // until a panel takes key). So every screen-dependent geometry
        // call here falls back to `NSScreen.screens.first` (the primary
        // display), not `.main`. Without that fallback the init-time
        // `[tree]` config seed no-ops and the panel ignores its
        // pos/size on launch (only a header double-click — which runs
        // post-run-loop when `.main` is valid — would honour it).
        let scr = (NSScreen.main ?? NSScreen.screens.first)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        anchorTL = NSPoint(x: scr.minX + screenMargin,
                           y: scr.maxY - screenMargin)

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
        // Shown only when pal.background == nil (the `system` theme; every
        // concrete theme paints an opaque bgView over it). Honor the
        // resolved material — `system` asks for `.menu` (native context-menu
        // look); `.sidebar` is the fallback for any other vibrancy theme.
        effect.material = pal.vibrancyMaterial ?? .sidebar
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
        bgView.layer?.backgroundColor = (pal.background ?? .clear).cgColor
        bgView.autoresizingMask = [.width, .height]

        searchBar = SearchBar(frame: .zero)
        searchBar.isHidden = true
        searchBar.applyTheme()
        searchBar.autoresizingMask = [.width, .minYMargin]

        effect.addSubview(bgView)
        effect.addSubview(scroll)
        effect.addSubview(searchBar)
        effect.addSubview(handleBar)

        // Outer accent border, on top of the chrome. A layer (not a
        // view) can't intercept clicks; `zPosition` keeps it above the
        // subviews' layers and `cornerCurve = .continuous` matches the
        // panel's squircle. Frame is set in `applySubviewLayout`, color
        // in `applyTheme`. The border draws inside the layer bounds, so
        // it stays within `effect`'s masksToBounds clip.
        borderLayer.borderWidth = 1.5
        borderLayer.borderColor = pal.primary.cgColor
        borderLayer.cornerRadius = cornerRadius
        borderLayer.cornerCurve = .continuous
        borderLayer.zPosition = 100
        effect.layer?.addSublayer(borderLayer)

        // Line-pets: a manual sublayer one above borderLayer (zPosition
        // 101 > 100) so the pets ride IN FRONT of the outer border. The
        // provider hands back the active band already converted into
        // `effect`'s (non-flipped) space; nil ⇒ nothing to draw.
        // Line-pets overlay objects (configured + attached below, after
        // super.init). The window is glued to the panel by syncPetWindow().
        petView = PetWindowView(pad: petPad)
        petWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)

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
        // Every border tick / config / flash repaints the panel border.
        borderFX.onRepaint = { [weak self] in
            guard let self else { return }
            self.borderFX.apply(to: self.borderLayer)
        }

        // Line-pets overlay: transparent, click-through, riding above the
        // panel as a child window so it follows moves / Space-switches and
        // never steals focus. `addChildWindow(ordered: .above)` keeps it in
        // front of the panel border; `syncPetWindow()` matches its frame.
        petWindow.isOpaque = false
        petWindow.backgroundColor = .clear
        petWindow.hasShadow = false
        petWindow.ignoresMouseEvents = true
        petWindow.becomesKeyOnlyIfNeeded = true
        petWindow.level = panel.level
        petWindow.collectionBehavior = panel.collectionBehavior
        petWindow.contentView = petView
        syncPetWindow()
        panel.addChildWindow(petWindow, ordered: .above)
    }

    /// Keep the pet overlay glued `petPad` larger than the panel on every
    /// side, so the border-centred sprites have room to straddle the line
    /// without clipping. Called wherever the panel frame changes.
    private func syncPetWindow() {
        petWindow.setFrame(panel.frame.insetBy(dx: -petPad, dy: -petPad),
                           display: false)
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

    /// Re-sync panel-derived state after a window-server-driven drag
    /// (the live move runs via `NSWindow.performDrag(with:)` in
    /// `SidebarView`, so nothing here fires mid-drag). Re-derives the
    /// persisted top-left anchor from the panel's settled frame and
    /// re-asserts the pet overlay inset — the addChildWindow child
    /// auto-followed during the drag, so the syncPetWindow() is
    /// belt-and-suspenders.
    func syncPanelAfterDrag() {
        anchorTL = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        syncPetWindow()
    }

    /// Pin the panel to an exact rect in **TOP-LEFT origin** — `x`
    /// right from the main screen's left edge, `y` DOWN from its top
    /// (0,0 = top-left corner), `w`/`h` in screen points. Session-only —
    /// used by both the `[tree]` config geometry seed (Controller, at
    /// startup + reload) and the CLI `--pos-x/--pos-y/--width/--height`
    /// flags. Not persisted; config.toml is the only place geometry
    /// sticks.
    func setExplicitFrame(_ frame: NSRect) {
        guard let scr = (NSScreen.main ?? NSScreen.screens.first)?.frame
        else { return }
        userWidth = frame.width
        userHeight = frame.height
        // Convert top-left input → the AppKit (bottom-left-screen)
        // top-left anchor the panel stores: x offset from the screen
        // left, y measured down from the screen top.
        anchorTL = NSPoint(x: scr.minX + frame.minX,
                           y: scr.maxY - frame.minY)
        layout(contentHeight: view.contentHeight,
               searching: view.searching)
    }

    /// Reset to the built-in default geometry: top-left of the main
    /// screen (with margin), default width, auto height. Used by the
    /// header double-click when no `[tree]` config geometry is set.
    func resetGeometryToDefault() {
        guard let scr = (NSScreen.main ?? NSScreen.screens.first)?.frame
        else { return }
        userWidth = sidebarWidth
        userHeight = nil                     // auto = content height
        anchorTL = NSPoint(x: scr.minX + screenMargin,
                           y: scr.maxY - screenMargin)
        layout(contentHeight: view.contentHeight,
               searching: view.searching)
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
            // Snap anchor to dest centre, preserving size (session-only;
            // a restart re-seeds from `[tree]` config).
            let newX = dest.midX - userWidth / 2
            let newTopY = dest.midY + h / 2
            anchorTL = NSPoint(x: newX, y: newTopY)
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
        guard let scr = (NSScreen.main ?? NSScreen.screens.first)?.frame
        else { return }
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
        // Pinned grab band sits just below the search bar (or at the very
        // top when not searching); the scroll view fills the rest below
        // it. The band never scrolls, so a long list can't carry the
        // panel-move handle off-screen.
        let hb = HandleBar.height
        handleBar.frame = NSRect(x: 0, y: f.height - sh - hb,
                                 width: f.width, height: hb)
        handleBar.ordinal = view.shownMacDesktopOrdinal
        handleBar.needsDisplay = true
        let bodyH = max(f.height - sh - hb, 0)
        scroll.frame = NSRect(x: 0, y: 0, width: f.width, height: bodyH)
        view.frame = NSRect(x: 0, y: 0, width: f.width,
                            height: max(contentH, bodyH))
        // Border tracks the panel size. Disable the implicit layer
        // animation so it doesn't lag a frame behind a live resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = f
        CATransaction.commit()
        // Keep the pet overlay glued to the (possibly resized) panel.
        syncPetWindow()
    }

    // MARK: - Theme

    /// Re-apply the current `pal` to the panel chrome. Call after
    /// `paletteFor(...)` changes `pal`.
    func applyTheme() {
        bgView.layer?.backgroundColor = (pal.background ?? .clear).cgColor
        // Re-honor the material on every theme switch, so toggling TO
        // `system` at runtime swaps the backdrop to `.menu` (and back to
        // `.sidebar` for another vibrancy theme). Harmless for concrete
        // themes — their opaque bgView hides the effect entirely.
        effect.material = pal.vibrancyMaterial ?? .sidebar
        borderFX.apply(to: borderLayer)   // re-reads pal.primary when off
        searchBar.applyTheme()
        handleBar.needsDisplay = true
    }

    /// Apply the `[border]` config (shared `BorderFX`). The panel border
    /// shows the effect color when on, or `pal.primary` when off. Called
    /// by the Controller at startup + on hot-reload.
    func applyBorder(effectName: String, glow: Bool, width: CGFloat,
                     cycleSeconds: CGFloat, cycleColors: Bool,
                     minWidth: CGFloat?, maxWidth: CGFloat?) {
        borderFX.configure(effectName: effectName, glow: glow, width: width,
                           cycleSeconds: cycleSeconds, cycleColors: cycleColors,
                           minWidth: minWidth, maxWidth: maxWidth)
    }

    /// WS-switch flash burst (no-op when the effect is off).
    func flashBorder() { borderFX.flash() }

    // MARK: - Line-pets

    /// Install the `[tree] line-pets` config onto the overlay. Called by
    /// the Controller at startup + on hot-reload.
    func setPets(names: [String], scale: CGFloat, lapSeconds: CGFloat) {
        petView.setPets(names: names, scale: scale, lapSeconds: lapSeconds)
    }

    /// Whether any (validated) pet is configured — the Controller gates
    /// its redraw timer on this.
    var hasPets: Bool { petView.hasPets }

    /// Repaint the pets one frame (driven by the Controller's 30 Hz tick).
    func redrawPets() { petView.needsDisplay = true }

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

    // A live resize updates the in-memory geometry (windowDidResize)
    // but is NOT persisted — geometry sticks only via `[tree]` config.

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Keep the persisted top-left anchor synced to the panel's
            // LIVE position. Critical during a performDrag panel move
            // (SidebarView): that runs its own modal tracking loop in which
            // facet's refresh timers still fire, so layout() can run
            // mid-drag — and layout() reconstructs the frame from anchorTL,
            // so a STALE anchor would yank the panel back toward its
            // pre-drag spot ("tree returns to its original position" mid-
            // drag). Updating here every move keeps layout()'s
            // `panel.frame != frame` guard a no-op during the drag. Fires
            // for programmatic layout() setFrame too — harmless, anchorTL
            // just re-asserts the value layout() derived it from.
            anchorTL = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
    }

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated { onKeyChanged?(true) }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { onKeyChanged?(false) }
    }
}
