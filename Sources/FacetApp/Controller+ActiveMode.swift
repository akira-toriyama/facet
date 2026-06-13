// Active mode (`--active` keyboard navigation) — key-focus entry /
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

    // MARK: - Active mode (--active keyboard navigation)
    //
    // `--show` stays passive (non-activating, never steals focus).
    // `--active` additionally makes the app/panel key so a plain
    // local NSEvent monitor receives ↑↓/Enter/Esc — no Input
    // Monitoring, no CGEventTap (those paths fail silently when
    // permissions are not granted, which is too easy a footgun).

    func enterActive() {
        Log.debug("enterActive")
        setHidden(false)                           // ensure visible
        // kbMonitor was already installed by setHidden(false) so
        // `s` works even in passive (--view=tree without --active)
        // when the panel has focus; enterActive only flips kbNav on
        // to unlock the full nav set (↑↓/Enter/Esc/etc).
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

    func _exitActiveImpl(restore: Bool) {
        Log.debug("exitActive restore=\(restore) wasKbNav=\(sidebarView.kbNav)")
        // Don't remove kbMonitor here — passive `s` opens search after
        // the panel is clicked, which we want to keep. The monitor's
        // own `panel.isKeyWindow` guard means it's idempotent /
        // harmless while the panel isn't focused.
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

        // -- Type-to-filter sub-mode (#187 modal focus) --
        // Two states while `searching`, told apart by whether the
        // box owns key input (`searchBar.isFocused`):
        //   A (box focused / insert) — typing filters, ↑↓ recall the
        //     query history INTO the box, Enter COMMITS the query
        //     into nav (vim `/query<CR>` style), Esc also drops to B.
        //   B (box not focused / nav) — the normal tree-nav keymap
        //     drives the (still filtered) result list; `s` returns
        //     to A keeping the text, Esc ends the search.
        // Esc is therefore two-stage (A→B, B→exit); `s` always means
        // "into the box". Activation — and the history push tied to
        // it — only happens on B's Return.
        if sidebarView.searching {
            // While the IME has uncommitted text, intercept nothing:
            // Enter commits the conversion, arrows move candidates,
            // Esc cancels — all must reach the input.
            if panelHost.searchBar.isComposing { return false }

            if panelHost.searchBar.isFocused {
                // -- State A: box focused / insert --
                switch e.keyCode {
                case 53:                                        // Esc → B
                    leaveSearchField()
                    return true
                case 36, 76:                                    // Enter → B
                    // Commits the query and moves to the list —
                    // NOT a direct first-hit activation (that, and
                    // the history push, happen on B's Return).
                    leaveSearchField()
                    return true
                case 126:     recallSearchHistory(1);        return true
                case 125:     recallSearchHistory(-1);       return true
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
                return false       // → NSTextField (typing, IME, ⌫)
            }

            // -- State B: box not focused / nav --
            // Same keymap as normal tree nav below, except Esc ends
            // the SEARCH (not active mode) and `s` re-enters the box
            // with the existing text (caret at end).
            switch e.keyCode {
            case 53:      if sidebarView.kbCancelLift() { return true }
                          exitSearch();                      return true
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
            case "s":            focusSearchField();         return true
            default:             return false
            }
        }

        // panel.isKeyWindow already implies kbNav was enabled by the
        // didBecomeKey hook below — fall through to the full nav.

        // -- Normal keyboard nav --
        // Theme A keyboard DnD: Space lifts the selected row (window
        // = move, header = WS-swap); while lifted the arrow keys aim
        // the drop target (kbMove/kbJumpWS redirect internally),
        // Return/Space commits, Esc cancels the lift before exiting.
        switch e.keyCode {
        case 53:      if sidebarView.kbCancelLift() { return true }
                      _exitActiveImpl(restore: true);    return true
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

    /// State A→B (#187): drop the box's key focus so the nav keymap
    /// takes over. The panel stays key (kbNav continues) and the
    /// filter stays applied — only the caret / border accent leave
    /// the box.
    private func leaveSearchField() {
        panelHost.panel.makeFirstResponder(nil)
    }

    /// State B→A (#187, `s`): refocus the box KEEPING its text, caret
    /// at the end so editing continues (the field editor would
    /// otherwise select-all on focus).
    private func focusSearchField() {
        panelHost.panel.makeFirstResponder(panelHost.searchBar.field)
        if let ed = panelHost.searchBar.field.currentEditor() {
            // NSRange is UTF-16 based — `.count` would misplace the
            // caret after non-BMP characters.
            let n = panelHost.searchBar.stringValue.utf16.count
            ed.selectedRange = NSRange(location: n, length: 0)
        }
    }

    /// ↑↓ in state A (#187): recall the session query ring into the
    /// box. +1 = older, -1 = newer; walking ↓ past the newest restores
    /// the pre-recall draft. The recall applies the filter live but
    /// keeps the browse cursor (so the next ↑↓ continues the walk).
    private func recallSearchHistory(_ delta: Int) {
        guard let t = sidebarView.recallHistory(
            delta, current: panelHost.searchBar.stringValue) else { return }
        panelHost.searchBar.stringValue = t
        sidebarView.applyRecalledQuery(t)
        if let ed = panelHost.searchBar.field.currentEditor() {
            ed.selectedRange = NSRange(location: t.utf16.count, length: 0)
        }
    }

    /// End the search from state B (#187): the filter clears and the
    /// panel returns to normal tree nav. Deliberately does NOT resign
    /// the panel's key status — Esc here ends the SEARCH, not active
    /// mode (the next Esc, in normal nav, does that).
    private func exitSearch() {
        sidebarView.endSearch()
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
    }
}
