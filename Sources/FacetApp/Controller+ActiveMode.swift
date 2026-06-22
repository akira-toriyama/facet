// Active mode (tree keyboard navigation) — key-focus entry /
// exit, the local keyDown handler (full nav + type-to-filter
// sub-mode), and search begin / end. Extracted unchanged from
// Controller.swift (#182 phase 3) — same-module extension, no logic
// change. Stored state stays on the primary declaration
// (Controller.swift).

import AppKit
import FacetCore
import FacetView
import FacetViewTree

extension Controller {

    // MARK: - Active mode (tree keyboard navigation)
    //
    // The tree opens directly in this mode (no `--active` flag — it
    // was folded into `--view tree`): enterActive makes the app/panel
    // key so a plain local NSEvent monitor receives ↑↓/Enter/Esc — no
    // Input Monitoring, no CGEventTap (those paths fail silently when
    // permissions are not granted, which is too easy a footgun).
    // Acting on a window (click / Enter) calls exitActive FIRST so
    // facet drops key before focusing — that's what keeps same-app
    // focus working (#66). The panel then settles back to passive.

    func enterActive() {
        Log.debug("enterActive")
        setHidden(false)                           // ensure visible
        // kbMonitor was already installed by setHidden(false); its own
        // `panel.isKeyWindow` guard keeps it inert until we take key
        // just below. enterActive flips kbNav on to unlock the full nav
        // set (↑↓/Enter/Esc/etc) and takes key.
        prevApp = NSWorkspace.shared.frontmostApplication
        // A .accessory + .nonactivatingPanel app can't reliably
        // become key, so the local keyDown monitor wouldn't fire
        // and keys leaked to the window behind. Become a regular
        // app for the duration of keyboard mode so we actually
        // take key focus; revert on exit.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panelHost.makeKey()
        sidebarView.enterKbNav()
    }

    func exitActive(restore: Bool) {
        Log.debug("exitActive restore=\(restore) wasKbNav=\(sidebarView.kbNav)")
        // Don't remove kbMonitor here — it stays installed for the whole
        // session so `s` / nav fire the moment facet is key again (a new
        // `--view tree` show, or the Desktop-header menu's
        // enterSearchFromMenu). Its own `panel.isKeyWindow` guard makes
        // it a no-op while the panel isn't key, so leaving it installed
        // is harmless. (Acting on a row drops key via exitActive — #66 —
        // so a focused window never has to fight facet for the keys.)
        guard sidebarView.kbNav else { return }
        sidebarView.exitKbNav()                    // also clears `searching`
        panelHost.resignKey()
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
        NSApp.setActivationPolicy(.accessory)      // back to LSUIElement
        if restore, let p = prevApp { p.activate() }
        prevApp = nil
    }

    /// Returns true if the key was consumed (swallowed so it doesn't
    /// beep or fall through to whatever is behind the panel).
    func handleKbKey(_ e: NSEvent) -> Bool {
        // Only intercept keys when our panel actually has focus.
        // Without this, the local monitor would catch keys while
        // a different window is key and silently swallow them.
        guard panelHost.panel.isKeyWindow else { return false }

        let ctrl = e.modifierFlags.contains(.control)
        let shift = e.modifierFlags.contains(.shift)

        // A Space-opened context menu is up: let its own monitor
        // handle keys (Esc closes, mouse picks). Don't run nav /
        // exit-active here.
        if PopupMenu.shared.isOpen { return false }

        // -- Type-to-filter sub-mode --
        // Nav/commit keys consumed here; everything else returns
        // false so the event reaches the NSTextField (text + IME
        // work natively).
        if sidebarView.searching {
            // While the IME has uncommitted text, intercept nothing:
            // Enter commits the conversion, arrows move candidates,
            // Esc cancels — all must reach the input.
            if panelHost.searchBar.isComposing { return false }
            switch e.keyCode {
            case 53:                                            // Esc
                if panelHost.searchBar.stringValue.isEmpty {
                    leaveSearchKeepingNav()   // back to nav, stay in tree
                } else {
                    panelHost.searchBar.stringValue = ""
                    sidebarView.setQuery("")
                }
                return true
            case 36, 76:  sidebarView.kbActivate();      return true
            case 125:     sidebarView.kbMove(1);         return true
            case 126:     sidebarView.kbMove(-1);        return true
            case 48:      sidebarView.kbMove(shift ? -1 : 1)
                          return true
            default:      break
            }
            if ctrl, e.charactersIgnoringModifiers?.lowercased() == "n" {
                sidebarView.kbMove(1);  return true
            }
            if ctrl, e.charactersIgnoringModifiers?.lowercased() == "p" {
                sidebarView.kbMove(-1); return true
            }
            return false           // → NSTextField (typing, IME, ⌫)
        }

        // panel.isKeyWindow already implies kbNav was enabled by the
        // didBecomeKey hook below — fall through to the full nav.

        // -- Normal keyboard nav --
        // Theme A keyboard DnD: Space lifts the selected row (window
        // = move, header = WS-swap); while lifted the arrow keys aim
        // the drop target (kbMove/kbJumpWS redirect internally),
        // Return/Space commits, Esc cancels the lift before exiting.
        switch e.keyCode {
        case 53:      // ESC backs out of a sub-mode but never leaves the
                      // tree: cancel an in-progress lift, otherwise stay in
                      // nav. (You leave nav by clicking another app or
                      // pressing Enter on a window — both resign key, and
                      // handlePanelKeyChange reverts the activation policy.)
                      _ = sidebarView.kbCancelLift()
                      return true
        case 36, 76:  if sidebarView.kbCommitLift() { return true }
                      sidebarView.kbActivate();          return true
        case 125:     sidebarView.kbMove(1);             return true
        case 126:     sidebarView.kbMove(-1);            return true
        case 124:     sidebarView.kbJumpWS(1);           return true
        case 123:     sidebarView.kbJumpWS(-1);          return true
        case 48:      sidebarView.kbJumpWS(shift ? -1 : 1)
                      return true
        case 49:      sidebarView.kbToggleLift();         return true
        default:      break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "n" where ctrl: sidebarView.kbMove(1);      return true
        case "p" where ctrl: sidebarView.kbMove(-1);     return true
        case "j":            sidebarView.kbMove(1);      return true
        case "k":            sidebarView.kbMove(-1);     return true
        case "l":            sidebarView.kbJumpWS(1);    return true
        case "h":            sidebarView.kbJumpWS(-1);   return true
        case "m":            sidebarView.kbContextMenu(); return true
        case "s":            enterSearch();              return true
        default:             return false
        }
    }

    private func enterSearch() {
        sidebarView.beginSearch()
        panelHost.searchBar.stringValue = ""
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
        // IME input goes to the field.
        panelHost.panel.makeFirstResponder(panelHost.searchBar.field)
    }

    /// ESC out of search back to normal nav WITHOUT leaving the tree:
    /// end the filter and drop the field's first responder, but keep the
    /// panel key so kbNav continues. ESC never exits the tree — you leave
    /// by clicking another app or pressing Enter on a window, which resign
    /// key and let `handlePanelKeyChange` revert the activation policy.
    private func leaveSearchKeepingNav() {
        sidebarView.endSearch()
        panelHost.panel.makeFirstResponder(nil)
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
    }

    /// Open search from the "Desktop N" right-click menu when facet is
    /// passive. The `s`-key path (`handleKbKey` → `enterSearch`) assumes
    /// facet is already key — the local keyDown monitor only fires when
    /// facet is active — so a menu pick must self-activate first, then open
    /// search. No window is focused here, so this neither trips #66 nor
    /// steals focus unprompted. ESC backs search out to normal nav (it no
    /// longer leaves the tree); you leave by clicking another app or
    /// activating a window, which reverts the activation policy via
    /// `handlePanelKeyChange`.
    func enterSearchFromMenu() {
        if !sidebarView.kbNav { enterActive() }
        enterSearch()
    }

    /// Build + show the panel-level ("Desktop N") right-click menu — the
    /// third context-menu surface (panel ▸ workspace ▸ window). Search is
    /// always offered. Each entry self-activates facet via its callback.
    func showDesktopMenu(at scr: NSPoint) {
        ViewContextMenu.showDesktop(
            at: scr,
            palette: treePaletteBox.pal,
            ordinal: sidebarView.shownMacDesktopOrdinal,
            onSearch: { [weak self] in self?.enterSearchFromMenu() })
    }

    /// Section/lens model: TreeController hook — the user clicked a
    /// `type="lens"` section header in the tree. Toggle it as the active section
    /// (clicking the already-active lens clears it back to the active workspace).
    /// `setActiveLens` validates the label + re-renders; this maps the click to
    /// activate / clear. Tree click → `autoFocus: false` (the tree keeps key).
    func toggleActiveLens(_ label: String) {
        if currentActiveSection == .lens(label) {
            setActiveLens(nil)                                // toggle off → active workspace
        } else {
            activateSection(.lens(label), autoFocus: false)   // tree keeps key focus
        }
    }
}
