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

        // -- GUI tag-input sub-mode (#191 PR-7) --
        // The tag-name box (search-bar widget) is open. Like search,
        // pass everything to the NSTextField except Return (commit the
        // tag) / Esc (cancel); while the IME is composing, pass those too.
        if tagInputTarget != nil {
            if panelHost.searchBar.isComposing { return false }
            switch e.keyCode {
            case 53:      cancelTagInput();  return true   // Esc
            case 36, 76:  commitTagInput();  return true   // Return / Enter
            default:      return false                     // → field (type / IME / ⌫)
            }
        }

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
                    exitSearch()
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

    private func exitSearch() {
        sidebarView.endSearch()
        panelHost.resignKey()
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
    }

    // MARK: - GUI tag input (#191 PR-7)

    /// Open the tag-name input box for `id` (the "Tag…" context-menu
    /// item). Reuses the search-bar widget in a tag-input sub-mode (no
    /// list filtering): becomes key so the field takes keystrokes + IME,
    /// shows the bar with a "tag name…" prompt, and focuses the field.
    func beginTagInput(forWindow id: WindowID) {
        // Re-open while the box is already up (e.g. right-click another
        // row, pick "Tag…" again): just retarget. Do NOT re-evaluate
        // `tagInputEnteredActive` — kbNav is already true from the first
        // open, so it would flip to false and teardown would forget we
        // flipped to `.regular`, leaving the app stuck there.
        if tagInputTarget != nil {
            tagInputTarget = id
            panelHost.panel.makeFirstResponder(panelHost.searchBar.field)
            return
        }
        // The field needs key focus + an active app to receive typing /
        // IME (a passive `.nonactivatingPanel` can't be key). When the
        // panel is passive (right-click path) enterActive becomes key + a
        // .regular app and stores prevApp; when already in `--active` (the
        // `m` path) we leave that session as-is. Record which so teardown
        // can undo exactly what we did.
        tagInputEnteredActive = !sidebarView.kbNav
        if tagInputEnteredActive { enterActive() }
        tagInputTarget = id
        panelHost.searchBar.stringValue = ""
        panelHost.searchBar.setPlaceholder("tag name…")
        panelHost.inputBarVisible = true
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
        panelHost.panel.makeFirstResponder(panelHost.searchBar.field)
    }

    /// Return in the tag-input box: add the typed name (auto-vivify) to
    /// the target window, then tear the box down. An empty / invalid name
    /// (`TagName.sanitized` → nil) just closes the box without tagging.
    func commitTagInput() {
        let id = tagInputTarget
        let raw = panelHost.searchBar.stringValue
        endTagInput()
        guard let id, let name = TagName.sanitized(raw) else { return }
        let bk = backend
        cliQueue.async { _ = bk.addTag(name, toWindow: id) }
        scheduleReconcile(after: 0.05)
    }

    /// Esc in the tag-input box: close it without tagging.
    func cancelTagInput() { endTagInput() }

    /// Tear down the tag-input box when the panel lost key EXTERNALLY
    /// (handlePanelKeyChange's `isKey:false` branch — the user clicked
    /// another app). That branch already cleared kbNav and does NOT run
    /// `_exitActiveImpl`, so if `beginTagInput` flipped us to `.regular`
    /// we must revert the activation policy here (else the LSUIElement app
    /// stays a Dock-icon `.regular` app forever). prevApp is dropped, not
    /// reactivated — the user already chose another app.
    func abandonTagInput() {
        guard tagInputTarget != nil else { return }
        let selfEntered = tagInputEnteredActive
        clearTagInputState()
        if selfEntered {
            panelHost.resignKey()                 // wantsKey = false
            NSApp.setActivationPolicy(.accessory)
            prevApp = nil
        }
        panelHost.layout(contentHeight: sidebarView.contentHeight,
                         searching: sidebarView.searching)
    }

    /// "Untag #NAME" context-menu item: strip `name` from window `id`.
    func removeTagFromWindow(_ name: String, windowID id: WindowID) {
        let bk = backend
        cliQueue.async { _ = bk.removeTag(name, fromWindow: id) }
        scheduleReconcile(after: 0.05)
    }

    /// Tear down the tag-input box on commit / cancel. If `beginTagInput`
    /// entered `--active` just for the box, fully exit it (revert
    /// `.regular`, restore prevApp). If we were ALREADY in `--active` (the
    /// `m` path), stay there — drop the bar and hand key focus back to the
    /// panel so keyboard nav resumes (the `m` menu's "stays --active"
    /// contract).
    private func endTagInput() {
        guard tagInputTarget != nil else { return }
        let selfEntered = tagInputEnteredActive
        clearTagInputState()
        if selfEntered {
            // _exitActiveImpl re-lays out (bar now hidden) + resigns key +
            // restores prevApp + reverts to .accessory.
            _exitActiveImpl(restore: true)
        } else {
            panelHost.panel.makeFirstResponder(nil)   // off the hidden field
            panelHost.layout(contentHeight: sidebarView.contentHeight,
                             searching: sidebarView.searching)
        }
    }

    /// Common box-state reset (target, flag, bar, field text, prompt).
    private func clearTagInputState() {
        tagInputTarget = nil
        tagInputEnteredActive = false
        panelHost.inputBarVisible = false
        panelHost.searchBar.stringValue = ""
        panelHost.searchBar.resetPlaceholder()
    }
}
