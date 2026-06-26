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
        case "t" where config.isSectionModelActive(ordinal: currentMacDesktopOrdinal()):
                             enterTagManage();           return true
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
    /// Tree click → `autoFocus: false` (the tree keeps key).
    func toggleActiveLens(_ sectionID: String) {
        // §A: the tree passes the stable section id straight from the rendered
        // section — no label→id lookup, so the toggle is unambiguous even with
        // non-unique / empty labels.
        if currentActiveSection == .lens(sectionID) {
            setActiveLens(nil)                                // toggle off → active workspace
        } else {
            activateLensID(sectionID, ordinal: currentMacDesktopOrdinal(),
                           autoFocus: false)                 // tree keeps key focus
        }
    }

    /// TreeController (R10): open the per-window tag checklist for `windowID`
    /// (the ops-menu "Tag…" item). Everything the panel needs is derived from
    /// the live snapshot on main — `allTags` is the union of every window's
    /// tags (the implicit vocabulary; no backend call), `checkedTags` is this
    /// window's own tags, and the header reads the window's app name. Toggling
    /// maps to `backend.addTag` / `removeTag`; "+ Create" auto-vivifies via
    /// addTag. The panel is a `KeyablePanel` so it takes key + IME: the tree is
    /// already in keyboard nav when shown (so we don't flip the activation
    /// policy — `tagEditorSelfActivated` stays false), and `finishTagEditor`
    /// re-keys the tree on close. The `handlePanelKeyChange` guard keeps the
    /// tree's kbNav alive while the panel holds key.
    func openTagEditor(pid: Int, windowID id: WindowID, title: String, at anchor: CGPoint) {
        guard config.isSectionModelActive(ordinal: currentMacDesktopOrdinal()),
              let (win, _) = findRenderedWindow(id) else { return }
        // The implicit tag vocabulary = the union of every rendered window's
        // tags. `Window.tags` is already in the snapshot, so this is a pure
        // main-side read (no `definedTagNames()` round-trip).
        var all = Set<String>()
        for ws in lastWorkspaces { for w in ws.windows { all.formUnion(w.tags) } }
        let bk = backend
        tagEditorSelfActivated = !sidebarView.kbNav
        if tagEditorSelfActivated {
            prevApp = NSWorkspace.shared.frontmostApplication
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        TagEditPanel.shared.show(
            at: anchor,
            appName: win.appName,
            title: title,
            pid: pid,
            allTags: all.sorted(),
            checkedTags: Set(win.tags),
            palette: treePaletteBox.pal,
            onToggle: { [weak self] name, on in
                cliQueue.async {
                    if on { _ = bk.addTag(name, toWindow: id) }
                    else  { _ = bk.removeTag(name, fromWindow: id) }
                }
                self?.scheduleReconcile(after: 0.05)
            },
            onCreate: { [weak self] name in
                // addTag(_:toWindow:) auto-vivifies, so create == add.
                cliQueue.async { _ = bk.addTag(name, toWindow: id) }
                self?.scheduleReconcile(after: 0.05)
            },
            onClose: { [weak self] in self?.finishTagEditor() }
        )
    }

    /// Tag-manage mode (`t`, R11/C1): open the tag-VOCABULARY editor — rename /
    /// delete a tag across ALL windows, not tied to one. The tag list is the
    /// union of every snapshot window's tags (same main-side derivation as
    /// `openTagEditor`); rename / delete map to `backend.renameTag` /
    /// `removeTag` (the global verbs). Anchored beside the tree panel (it's a
    /// tree-panel-level mode, the `s` twin — vocabulary-wide, not row-specific).
    /// Shares the activation dance + `finishTagEditor` close with `openTagEditor`.
    func enterTagManage() {
        guard config.isSectionModelActive(ordinal: currentMacDesktopOrdinal())
        else { return }
        var all = Set<String>()
        for ws in lastWorkspaces { for w in ws.windows { all.formUnion(w.tags) } }
        let bk = backend
        let f = panelHost.panel.frame
        tagEditorSelfActivated = !sidebarView.kbNav
        if tagEditorSelfActivated {
            prevApp = NSWorkspace.shared.frontmostApplication
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        TagEditPanel.shared.showManage(
            at: NSPoint(x: f.maxX + 8, y: f.maxY),
            allTags: all.sorted(),
            palette: treePaletteBox.pal,
            onRename: { [weak self] old, new in
                cliQueue.async { _ = bk.renameTag(old, to: new) }
                self?.scheduleReconcile(after: 0.05)
            },
            onDelete: { [weak self] name in
                cliQueue.async { _ = bk.removeTag(name) }
                self?.scheduleReconcile(after: 0.05)
            },
            onClose: { [weak self] in self?.finishTagEditor() }
        )
    }

    /// Section rename (§E): the user picked the header menu's `SECTION ▸ Rename`
    /// row (workspace or lens). Resolve the render group `g` to the SAME
    /// 1-based index + current display label that `SidebarView.sectionHeader
    /// Display(group:)` shows (for the editor caption / pre-fill), AND capture a
    /// STABLE handle for the deferred commit, then open the inline editor.
    /// `unassigned` is guarded out (the projection drops it — no header, so it
    /// can't reach here, but it's defensive). Shares the activation dance +
    /// `finishTagEditor` close with `enterTagManage` (the panel is keyable).
    ///
    /// The inline editor is long-lived (the user types), so `lastSections` /
    /// the workspace list can reorder — or be swapped wholesale by a mac-desktop
    /// change — between open and commit. Routing the commit by a positional
    /// `index1` would then rename a SHIFTED slot (review E2 LOW/MEDIUM). Instead
    /// capture the stable identity (section `sec.id` / the degrade workspace's
    /// `Workspace.index`) plus the current mac-desktop ordinal, and have the
    /// id-keyed `renameSection` overloads re-resolve to the live position at
    /// commit (mirrors the lens-layout path; identity = id, campaign rule).
    func beginSectionRename(group g: Int, at anchor: CGPoint) {
        // Resolve g → (1-based index, current label), mirroring
        // `sectionHeaderDisplay`. Section mode: g IS the display group ordinal
        // (index = g + 1, label = lastSections[g].label). Degrade: g == the
        // workspace's `ws.index`; the display index is its position in the
        // reorder-applied list (the same list `renameSection`'s degrade branch
        // and `--focus index:N` address by — NOT `g + 1`).
        let index1: Int
        let label: String
        // The stable commit handle resolved alongside the display index.
        let capturedOrdinal = currentMacDesktopOrdinal()
        let commit: (String) -> Void
        if !lastSections.isEmpty {
            guard g >= 0, g < lastSections.count else { return }
            let sec = lastSections[g]
            // unassigned has no header / index → not renameable (Problem U).
            guard sec.sectionType != .unassigned else { return }
            index1 = g + 1
            label = sec.label
            let secID = sec.id
            commit = { [weak self] newLabel in
                self?.renameSection(sectionID: secID,
                                    capturedOrdinal: capturedOrdinal, to: newLabel)
            }
        } else {
            let key = capturedOrdinal ?? -1
            let wss = SectionOrder.applyWorkspaces(
                macDesktopSectionOrder[key], to: lastWorkspaces)
            guard let pos = wss.firstIndex(where: { $0.index == g }) else { return }
            index1 = pos + 1
            label = wss[pos].name
            let wsIndex = wss[pos].index    // stable 0-based Workspace.index
            commit = { [weak self] newLabel in
                self?.renameSection(workspaceIndex: wsIndex,
                                    capturedOrdinal: capturedOrdinal, to: newLabel)
            }
        }
        let caption = sectionDisplayLabel(index: index1, label: label)

        // Activation dance — identical to `enterTagManage`: a keyable panel
        // needs the app to be regular + active to take key; if the tree is
        // already in kbNav it's already regular (flag stays false, close
        // re-keys the tree instead of reverting policy).
        let f = panelHost.panel.frame
        tagEditorSelfActivated = !sidebarView.kbNav
        if tagEditorSelfActivated {
            prevApp = NSWorkspace.shared.frontmostApplication
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        // Anchor the editor at the clicked header's height (`anchor.y`), to the
        // RIGHT of the tree (`f.maxX + 8`) — not pinned to the tree top — so it
        // lines up with the section being renamed.
        SectionRenamePanel.shared.show(
            at: NSPoint(x: f.maxX + 8, y: anchor.y),
            header: caption,
            initialText: label,
            palette: treePaletteBox.pal,
            onCommit: commit,
            // The close lifecycle is not tag-specific — `finishTagEditor`
            // reverts the activation policy / re-keys the tree on EVERY close
            // path, exactly what this panel needs too.
            onClose: { [weak self] in self?.finishTagEditor() })
    }

    /// Called once on EVERY tag-panel close path (Esc / outside-click / click
    /// elsewhere). Undoes exactly what `openTagEditor` / `enterTagManage` did:
    /// if it flipped to `.regular`, revert to `.accessory` and hand focus back
    /// to the previous app; otherwise re-key the tree panel so keyboard nav
    /// resumes (the tree resigned key when the panel took it, but the
    /// `handlePanelKeyChange` guard kept kbNav alive).
    func finishTagEditor() {
        if tagEditorSelfActivated {
            NSApp.setActivationPolicy(.accessory)
            if let p = prevApp { p.activate() }
            prevApp = nil
        } else {
            panelHost.makeKey()
        }
        tagEditorSelfActivated = false
    }
}
