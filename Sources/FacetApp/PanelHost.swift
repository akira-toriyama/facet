// Panel scaffolding for the tree view. Owns the `NSPanel`, the
// `NSVisualEffectView` backdrop, the `NSHostingView` rendering the
// SwiftUI `TreeContentView` (on sill's `ThemedListView`), and the
// search bar above the list. Provides show / hide / move / resize /
// persist + the single-source-of-truth `layout(searching:)` — every
// geometry change inside the panel funnels through it. Auto height is
// summed from the tree's `ListMetrics` (see `autoContentHeight`), since
// the greedy SwiftUI ScrollView never self-reports a fitting size.
//
// #18/F1 render-swap (t-tsxg Task 8): the SwiftUI tree replaced the old
// `NSScrollView`(FlippedClipView + `SidebarView` documentView +
// `ThemedScroller`). `SidebarView` stays constructed by the Controller
// (its `searching` state still gates the search band) but is no longer
// the render surface; its DnD + live-search re-wire onto the SwiftUI
// path in facet-2/3.
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
import SwiftUI
import FacetCore
import FacetView
import FacetViewTree

@MainActor
final class PanelHost: NSObject {

    // MARK: - Chrome

    let panel: KeyablePanel
    private let effect: NSVisualEffectView
    /// Hosts the SwiftUI `TreeContentView` (render-swap, Task 8). Replaces the
    /// old `NSScrollView` — sill's `ThemedListView` owns its own scrolling.
    private let treeHost: NSHostingView<TreeContentView>
    private let bgView = NSView()
    let searchBar: SearchBar
    /// The `@Observable` box the SwiftUI tree binds to. Controller feeds it via
    /// `apply(sections:)`; `applyTheme()` repoints its `palette` every tick.
    let treeVM: TreeViewModel
    /// Retained for its `searching` flag (search-band gate) + facet-2/3 re-wire;
    /// no longer the render surface. Controller is its other owner.
    private let view: SidebarView
    /// Mac-desktop ordinal fed by the Controller (was `view.shownMacDesktopOrdinal`,
    /// which only updated inside the retired `SidebarView.update` render path).
    /// Drives the HandleBar "Desktop N" label in `applySubviewLayout`.
    private var handleOrdinal: Int?
    /// Row-activation / header-collapse / hover hooks the Controller wires (like
    /// `onKeyChanged`). `TreeContentView`'s callbacks forward here. Real #66
    /// activation lands in Task 12; keyboard nav in Task 10.
    var onActivateRow: ((TreeItemID) -> Void)?
    var onToggleSectionRow: ((TreeItemID) -> Void)?
    var onHoverRow: ((TreeItemID?) -> Void)?
    /// Per-surface palette (PR-B) — the tree box, shared with every piece
    /// of tree chrome (sidebar, search bar, handle bar, border, scrollers)
    /// so a re-theme / cycle updates all of it at once.
    let paletteBox: PaletteBox
    private var pal: ResolvedPalette { paletteBox.pal }
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
    /// kbNav on/off here so a plain click on the tree panel still
    /// enables keyboard navigation while the panel is
    /// focused.
    var onKeyChanged: ((Bool) -> Void)?

    // MARK: - Persisted geometry

    private(set) var anchorTL: NSPoint      // top-left in screen coords
    private(set) var userWidth: CGFloat = sidebarWidth
    private(set) var userHeight: CGFloat?   // nil = auto (content height)

    // MARK: - Tunables

    private let screenMargin: CGFloat = 8
    private let searchRowH: CGFloat = 38           // band when searching
    private let minWidth: CGFloat = 160
    private let minHeight: CGFloat = 140
    private let cornerRadius: CGFloat = 12

    // MARK: - Init

    init(view: SidebarView, paletteBox: PaletteBox) {
        self.view = view
        self.paletteBox = paletteBox
        view.paletteBox = paletteBox
        handleBar.paletteBox = paletteBox
        borderFX.paletteBox = paletteBox

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

        // Render-swap (Task 8): the SwiftUI `TreeContentView` on sill's
        // `ThemedListView` renders the tree. `ThemedListView` owns its own
        // vertical + horizontal (title-overflow) scrolling, so the old
        // NSScrollView / FlippedClipView / ThemedScroller stack is retired
        // here (those types stay in the module for other consumers). Real
        // callbacks are wired after `super.init` (they capture `self`).
        treeVM = TreeViewModel(palette: paletteBox.pal)
        treeHost = NSHostingView(rootView: TreeContentView(model: treeVM))
        treeHost.autoresizingMask = [.width, .height]

        effect = NSVisualEffectView()
        // Shown only when pal.background == nil (the `system` theme; every
        // concrete theme paints an opaque bgView over it). Honor the
        // resolved material — `system` asks for `.menu` (native context-menu
        // look); `.sidebar` is the fallback for any other vibrancy theme.
        effect.material = paletteBox.pal.vibrancyMaterial ?? .sidebar
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
        bgView.layer?.backgroundColor = (paletteBox.pal.background ?? .clear).cgColor
        bgView.autoresizingMask = [.width, .height]

        searchBar = SearchBar(frame: .zero)
        searchBar.paletteBox = paletteBox
        searchBar.isHidden = true
        searchBar.applyTheme()
        searchBar.autoresizingMask = [.width, .minYMargin]

        effect.addSubview(bgView)
        effect.addSubview(treeHost)
        effect.addSubview(searchBar)
        effect.addSubview(handleBar)

        // Outer accent border, on top of the chrome. A layer (not a
        // view) can't intercept clicks; `zPosition` keeps it above the
        // subviews' layers and `cornerCurve = .continuous` matches the
        // panel's squircle. Frame is set in `applySubviewLayout`, color
        // in `applyTheme`. The border draws inside the layer bounds, so
        // it stays within `effect`'s masksToBounds clip.
        borderLayer.borderWidth = 1.5
        borderLayer.borderColor = paletteBox.pal.primary.cgColor
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
        // Now that `self` exists, give the SwiftUI tree its real callbacks —
        // they forward to the Controller-wired hooks (empty until Task 10/12).
        treeHost.rootView = TreeContentView(
            model: treeVM,
            onActivate: { [weak self] in self?.onActivateRow?($0) },
            onToggleSection: { [weak self] in self?.onToggleSectionRow?($0) },
            onHover: { [weak self] in self?.onHoverRow?($0) })
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
        layout(searching: view.searching)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Make the panel key (used by the tree's keyboard-nav mode).
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
        layout(searching: view.searching)
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
        layout(searching: view.searching)
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
        let h = (userHeight ?? autoContentHeight(searching: view.searching))
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
        layout(searching: view.searching)
    }

    /// Intended auto-height for the panel = the tree's summed sill row heights
    /// (`TreeViewModel.rowContentHeight`, the memoized `listItems` × `ListMetrics`)
    /// + the pinned chrome bands (search + handle). sill's `ThemedListView` root
    /// is a greedy SwiftUI `ScrollView` that fills its axis and never self-reports
    /// a fitting height, so `NSHostingView.fittingSize` would collapse this
    /// shrink-to-content panel (spec §4.1 / Task 8.2) — we derive geometry from
    /// the row metrics instead. `layout()` clamps the result to the screen; past
    /// the clamp the list scrolls internally. Adding the chrome bands (which the
    /// retired `SidebarView.contentHeight` did NOT) means the tree body fits
    /// without the old auto-height's ~handle-band clip.
    private func autoContentHeight(searching: Bool) -> CGFloat {
        let sh: CGFloat = searching ? searchRowH : 0
        return treeVM.rowContentHeight + sh + HandleBar.height
    }

    /// Single source of truth for panel + subview frames. Called
    /// from `show`, `enterSearch` / `leaveSearchKeepingNav`, and the
    /// refresh tick. (Live OS resize is handled by autoresizingMask + the
    /// `windowDidResize` callback, not by re-running layout per
    /// drag event.)
    func layout(searching: Bool) {
        guard let scr = (NSScreen.main ?? NSScreen.screens.first)?.frame
        else { return }
        let maxH = scr.height - 2 * screenMargin
        let h = min(userHeight ?? autoContentHeight(searching: searching), maxH)
        let w = userWidth
        var x = anchorTL.x, topY = anchorTL.y
        x = min(max(x, scr.minX), scr.maxX - w)
        topY = min(max(topY, scr.minY + h), scr.maxY)
        let frame = NSRect(x: x, y: topY - h, width: w, height: h)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        applySubviewLayout(searching: searching)
        panel.invalidateShadow()
    }

    /// Position the subviews to the panel's *current* size. Called
    /// from layout() and from windowDidResize (OS-driven resize).
    private func applySubviewLayout(searching: Bool) {
        let f = effect.bounds
        bgView.frame = f
        // The search-bar band shows only while filtering.
        let sh: CGFloat = searching ? searchRowH : 0
        searchBar.isHidden = !searching
        // 8pt top inset (matching the side insets) keeps the box clear
        // of the panel's radius-12 accent-border curve — at 4pt the two
        // borders crowded into one blob at the top corners (#186).
        // Bottom gap stays 5; box height = sh - 13 = 25 as before.
        searchBar.frame = NSRect(x: 8, y: f.height - sh + 5,
                                 width: f.width - 16,
                                 height: max(sh - 13, 0))
        searchBar.needsLayout = true
        // Pinned grab band sits just below the search bar (or at the very
        // top when not searching); the scroll view fills the rest below
        // it. The band never scrolls, so a long list can't carry the
        // panel-move handle off-screen.
        let hb = HandleBar.height
        handleBar.frame = NSRect(x: 0, y: f.height - sh - hb,
                                 width: f.width, height: hb)
        handleBar.ordinal = handleOrdinal
        handleBar.needsDisplay = true
        // The SwiftUI tree fills the body region below the pinned bands.
        // `ThemedListView` owns its own vertical scroll (content taller than
        // this) + horizontal title-overflow scroll — no NSScrollView / manual
        // documentView width.
        let bodyH = max(f.height - sh - hb, 0)
        treeHost.frame = NSRect(x: 0, y: 0, width: f.width, height: bodyH)
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
    /// `paletteFor(...)` changes `pal`. This is also the SINGLE per-frame write
    /// into the SwiftUI tree's palette: the Controller calls it on both theme
    /// paths — hot-reload (`reapplyThemes`) and the 30 Hz animator tick — so
    /// repointing `treeVM.palette` here re-colours the tree WITHOUT rebuilding
    /// its memoized `listItems` (spec §4.6/§7.7).
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
        treeVM.palette = pal      // re-colour the SwiftUI tree (no re-flatten)
    }

    /// Feed the mac-desktop ordinal that labels the HandleBar. Set by the
    /// Controller from its live `macDesktopOrdinal` (the retired render path's
    /// `SidebarView.update` used to carry this).
    func setHandleOrdinal(_ ordinal: Int?) {
        handleOrdinal = ordinal
        handleBar.ordinal = ordinal
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
            // The SwiftUI tree reflows itself inside the resized `treeHost`
            // (autoresizingMask + `ThemedListView`'s own scroll) — no manual
            // documentView relayout.
            applySubviewLayout(searching: view.searching)
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
