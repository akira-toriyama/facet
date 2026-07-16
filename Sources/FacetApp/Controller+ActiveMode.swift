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
        case "t" where config.desktopRenderMode(
            ordinal: currentMacDesktopOrdinal()).rendersSections:
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
        guard config.desktopRenderMode(
                  ordinal: currentMacDesktopOrdinal()).rendersSections,
              let (win, _) = findRenderedWindow(id) else { return }
        // The implicit tag vocabulary = the union of every rendered window's
        // tags. `Window.tags` is already in the snapshot, so this is a pure
        // main-side read (no `definedTagNames()` round-trip).
        var all = Set<String>()
        for ws in lastWorkspaces { for w in ws.windows { all.formUnion(w.tags) } }
        all.formUnion(config.effectiveDefinedTags)   // t-hdxb B5: config vocabulary
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
                self?.markConfigDirty()   // t-hdxb: persist the tag vocabulary
            },
            onCreate: { [weak self] name in
                // addTag(_:toWindow:) auto-vivifies, so create == add.
                cliQueue.async { _ = bk.addTag(name, toWindow: id) }
                self?.scheduleReconcile(after: 0.05)
                self?.markConfigDirty()   // t-hdxb: persist the tag vocabulary
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
        guard config.desktopRenderMode(
            ordinal: currentMacDesktopOrdinal()).rendersSections
        else { return }
        var all = Set<String>()
        for ws in lastWorkspaces { for w in ws.windows { all.formUnion(w.tags) } }
        all.formUnion(config.effectiveDefinedTags)   // t-hdxb B5: config vocabulary
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
                self?.markConfigDirty()   // t-hdxb: persist the tag vocabulary
            },
            onDelete: { [weak self] name in
                cliQueue.async { _ = bk.removeTag(name) }
                self?.scheduleReconcile(after: 0.05)
                self?.markConfigDirty()   // t-hdxb: persist the tag vocabulary
            },
            onClose: { [weak self] in self?.finishTagEditor() }
        )
    }

    /// Section rename (§E): the user picked the header menu's
    /// `SECTION ▸ Rename` row (workspace, matched, OR holding). Resolve the
    /// render group `g` to the SAME 1-based index + current display label that
    /// `SidebarView.sectionHeaderDisplay(group:)` shows (for the editor caption /
    /// pre-fill), AND capture a STABLE handle for the deferred commit, then open
    /// the inline editor. `.matched` / `.holding` rename via an id-keyed
    /// session-only override (`renameSection(sectionID:…)` →
    /// `applyLabelOverrides`), so the section-model branch handles every kind
    /// uniformly. Shares the activation dance + `finishTagEditor` close
    /// with `enterTagManage` (the panel is keyable).
    ///
    /// The inline editor is long-lived (the user types), so `lastSections` /
    /// the workspace list can reorder — or be swapped wholesale by a mac-desktop
    /// change — between open and commit. Routing the commit by a positional
    /// `index1` would then rename a SHIFTED slot (review E2 LOW/MEDIUM). Instead
    /// capture the stable identity (section `sec.id` / the degrade workspace's
    /// `Workspace.index`) plus the current mac-desktop ordinal, and have the
    /// id-keyed `renameSection` overloads re-resolve to the live position at
    /// commit (mirrors the isolate desktop-layout path; identity = id, campaign rule).
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
            // workspace / matched / holding all rename by the same stable-id
            // deferred-commit path — `renameSection(sectionID:…)` routes by kind
            // (workspace → catalog; the rest → session override).
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

    /// t-0020: the GUI twin of `facet section --match` — the user picked a MATCHED
    /// header's `SECTION ▸ Edit match` row (or pressed `m` on it). Opens the
    /// SAME inline editor as `beginSectionRename`, but pre-filled with the isolate desktop's
    /// CURRENT effective predicate and wired for live filter-tuning:
    ///   • ISOLATE-ONLY — only an isolate desktop header offers the row; guard anyway (a stale
    ///     group after a reorder → no-op).
    ///   • PREFILL = the session override if set, else the config `match` for
    ///     this lens (resolved by the SAME id `project()` mints).
    ///   • COMMIT routes by the STABLE `sec.id` (the editor is long-lived; the
    ///     section can reorder / a mac-desktop swap can intervene) →
    ///     `setSectionMatch(sectionID:…)` re-resolves to the live position.
    ///   • VALIDATE (Option B) keeps the panel open on a malformed predicate so
    ///     a typo never closes the editor or clobbers the working lens (an empty
    ///     predicate is the always-allowed revert gesture).
    func beginSectionMatchEdit(group g: Int, at anchor: CGPoint) {
        guard g >= 0, g < lastSections.count else { return }
        let sec = lastSections[g]
        guard sec.sectionType == .matched else { return }
        let secID = sec.id
        let capturedOrdinal = currentMacDesktopOrdinal()

        // Prefill = the CURRENT effective predicate: the session override if set,
        // else the config `match` for this lens. A transient nil ordinal
        // prefills empty.
        // The CONFIG match doubles as the picker's revert floor (uncheck-all
        // drops the override → this is what takes over, so the panel re-syncs
        // its display to it).
        let configMatch: String = {
            guard let ordinal = capturedOrdinal else { return "" }
            return config.desktopIsolate(ordinal: ordinal)?.match ?? ""
        }()
        let prefill: String = {
            guard let ordinal = capturedOrdinal else { return "" }
            // A matched section only ever comes from an ISOLATE DESKTOP now (t-ec9s),
            // which carries its `match` on the `[desktop.N]` table. The effective
            // predicate is the single ordinal-keyed session override (D6) over
            // the config `match` off `desktopIsolate`.
            guard !configMatch.isEmpty else { return "" }
            return capturedOrdinal.flatMap { isolateMatchOverride[$0] } ?? configMatch
        }()

        let caption = sectionDisplayLabel(index: g + 1, label: sec.label)
        let commit: (String) -> Void = { [weak self] newPredicate in
            self?.setSectionMatch(sectionID: secID,
                                  capturedOrdinal: capturedOrdinal, to: newPredicate)
        }
        // Option B: classify live + on commit (shares the pure
        // `classifyMatchPredicate` the projection acts on). Malformed syntax →
        // `.error` (red, blocks commit); an unknown FIELD / an unresolvable
        // filter ALIAS (t-5312) → `.warn` (tertiary, non-blocking in the LIVE
        // feedback — the commit path `setSectionMatch` still loud-rejects the
        // alias verdicts, same as the CLI); empty / all-known → `.ok`.
        let aliases = config.effectiveFilterAliases
        let validate: (String) -> SectionEditValidation = { text in
            switch classifyMatchPredicate(text, aliases: aliases) {
            case .ok:
                return .ok
            case .unknownField(let fields):
                return .warn("unknown field: \(fields.joined(separator: ", ")) "
                    + "— matches nothing")
            case .undefinedAlias(let names):
                return .warn("undefined filter alias: "
                    + names.map { "@\($0)" }.joined(separator: ", ")
                    + " — matches nothing")
            case .aliasCycle(let chains):
                return .warn("filter alias cycle: " + chains.joined(separator: "; "))
            case .malformed(let error):
                return .error(error.message)
            }
        }

        // Activation dance — identical to `beginSectionRename` / `enterTagManage`.
        let f = panelHost.panel.frame
        tagEditorSelfActivated = !sidebarView.kbNav
        if tagEditorSelfActivated {
            prevApp = NSWorkspace.shared.frontmostApplication
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        SectionRenamePanel.shared.show(
            at: NSPoint(x: f.maxX + 8, y: anchor.y),
            header: caption,
            initialText: prefill,
            palette: treePaletteBox.pal,
            onCommit: commit,
            onClose: { [weak self] in self?.finishTagEditor() },
            validate: validate,
            // t-kywh: the filter-alias picker — every defined `[alias]` name
            // as a checkbox row toggling a top-level OR term, applied live
            // (CLI-first: the notation is the canon, the picker just types
            // it). Match-edit only; the rename panel above passes nothing.
            aliases: aliases.keys.sorted(),
            configMatch: configMatch)
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
