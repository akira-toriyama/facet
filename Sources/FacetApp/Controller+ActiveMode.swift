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
import ListCore            // DragContext/DropTarget (treeDrop — facet-2)

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
        panelHost.treeVM.seedCursor()      // SwiftUI cursor (Task 10)
        previewTargetChanged()             // popover follows the seeded cursor
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
        panelHost.treeVM.clearCursor()             // SwiftUI cursor (Task 10)
        panelHost.treeVM.cancelDrag()              // drop a lift with the mode
        panelHost.treeVM.setQuery("")              // un-filter (search died with nav)
        previewTargetChanged()                     // cursor gone → popovers down
        panelHost.resignKey()
        panelHost.layout(searching: sidebarView.searching)
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
                    panelHost.searchBar.clearText()   // fires onChange("") → live filter resets
                }
                return true
            // Arrows ride `treeMove` (not bare `moveCursor`) so the hover /
            // thumbnail preview follows the cursor here too — typing already
            // re-aims via the filter rebuild, but the arrow path used to
            // leave the preview frozen on the pre-arrow row (ledger L3).
            // Tab stays `treeMove` — `treeJump` would ADD a section-jump
            // this sub-mode never had.
            case 36, 76:  activateTreeCursor();               return true
            case 125:     treeMove(1);                        return true
            case 126:     treeMove(-1);                       return true
            case 48:      treeMove(shift ? -1 : 1);           return true
            default:      break
            }
            if ctrl, e.charactersIgnoringModifiers?.lowercased() == "n" {
                treeMove(1);  return true
            }
            if ctrl, e.charactersIgnoringModifiers?.lowercased() == "p" {
                treeMove(-1); return true
            }
            return false           // → NSTextField (typing, IME, ⌫)
        }

        // panel.isKeyWindow already implies kbNav was enabled by the
        // didBecomeKey hook below — fall through to the full nav.

        // -- Normal keyboard nav --
        // t-tsxg Task 10: the cursor now lives in the SwiftUI view-model
        // (`treeVM.highlight` — sill's outline; `selection` stays the focus
        // fill, cursor ≠ selection). The five keys sill's `ThemedListView`
        // also binds (`.onKeyPress` ↑/↓/Return/Esc/Space) MUST keep returning
        // true here — the local monitor swallowing them is the load-bearing
        // invariant that stops a double-act + keeps sill's list focus ring
        // from ever engaging (spec §4.8, caveat ④).
        //
        // facet-2 keyboard DnD (Theme A): Space lifts the cursor row (window
        // = move, header = whole-section chunk); while lifted every movement
        // key AIMS the drop target (sill draws the lift through the preview
        // seam), Return / second Space commits via the same `treeDrop` the
        // mouse gesture uses, Esc cancels the lift and stays in nav.
        switch e.keyCode {
        case 53:      // ESC backs out of a sub-mode but never leaves the
                      // tree: cancel an in-progress lift, otherwise stay in
                      // nav. (You leave nav by clicking another app or
                      // pressing Enter on a window — both resign key, and
                      // handlePanelKeyChange reverts the activation policy.)
                      panelHost.treeVM.cancelDrag()
                      return true
        case 36, 76:  if commitTreeLift() { return true }
                      activateTreeCursor();               return true
        case 125:     treeMove(1);                        return true
        case 126:     treeMove(-1);                       return true
        case 124:     treeJump(1);                        return true
        case 123:     treeJump(-1);                       return true
        case 48:      treeJump(shift ? -1 : 1);           return true
        case 49:      if commitTreeLift() { return true }   // second Space commits
                      panelHost.treeVM.liftCursor();      return true
        default:      break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "n" where ctrl: treeMove(1);                 return true
        case "p" where ctrl: treeMove(-1);                return true
        case "j":            treeMove(1);                 return true
        case "k":            treeMove(-1);                return true
        case "l":            treeJump(1);                 return true
        case "h":            treeJump(-1);                return true
        case "m":            showTreeCursorMenu();             return true
        case "s":            enterSearch();              return true
        case "t" where config.desktopRenderMode(
            ordinal: currentMacDesktopOrdinal()).rendersSections:
                             enterTagManage();           return true
        default:             return false
        }
    }

    /// Cursor move / drag aim + the preview reconcile the old `setSel` used
    /// to fire (the thumbnail popover follows the keyboard cursor).
    private func treeMove(_ d: Int) {
        let vm = panelHost.treeVM
        vm.isKbDragging ? vm.aimDrag(d) : vm.moveCursor(d)
        previewTargetChanged()
    }

    private func treeJump(_ d: Int) {
        let vm = panelHost.treeVM
        vm.isKbDragging ? vm.aimDrag(d) : vm.jumpSection(d)
        previewTargetChanged()
    }

    /// facet-3: the ONE live-filter entry — the field's `onChange` (typing,
    /// IME composition, the clear-×) funnels here. Re-projects the SwiftUI
    /// tree, keeps the legacy `SidebarView` state in step (its `searching`
    /// flag still gates the band until it is retired), re-lands the cursor on
    /// the first match (the AppKit tree's per-keystroke behaviour), syncs the
    /// clear-×, and resizes the panel (dropped sections shrink it).
    func setTreeQuery(_ q: String) {
        sidebarView.setQuery(q)
        panelHost.treeVM.setQuery(q)
        panelHost.treeVM.clearCursor()
        panelHost.treeVM.seedCursor()              // land on the first match
        panelHost.searchBar.trailingSymbol = q.isEmpty ? nil : "x-circle"
        panelHost.layout(searching: sidebarView.searching)
        previewTargetChanged()             // follow the re-landed cursor
    }

    /// Return/Space with a keyboard lift up: commit it through the shared
    /// drop route. False when nothing was lifted (the caller then activates).
    private func commitTreeLift() -> Bool {
        guard panelHost.treeVM.isKbDragging else { return false }
        if let (ctx, target) = panelHost.treeVM.commitDrag() {
            treeDrop(ctx, target)
        }
        return true
    }

    // MARK: - SwiftUI tree activation (t-tsxg Tasks 10/12)
    //
    // The ONE routing helper for acting on a tree row — a list click
    // (`PanelHost.onActivateRow`) and Enter (`activateTreeCursor`) both land
    // here. Mirrors `SidebarView+Drag.handleClick` (which stays alive until
    // facet-2/3 retire the AppKit tree). #66: drop key FIRST
    // (`exitActive(restore: false)`), then act, so a same-app focus isn't
    // fought by facet being the active app.

    /// t-63h2: an isolate desktop's holding row is inert — checked BEFORE
    /// `exitActive` so acting on it doesn't silently drop keyboard nav for a
    /// no-op.
    private func treeRowIsInert(_ id: TreeItemID) -> Bool {
        let secs = panelHost.treeVM.renderedSections
        guard case .window(let g, _) = id,
              g >= 0, g < secs.count else { return false }
        return secs[g].sectionType == .holding
    }

    /// Enter on the cursor row — the keyboard twin of a row click.
    private func activateTreeCursor() {
        guard let id = panelHost.treeVM.activateCursor() else { return }
        activateTreeRow(id)
    }

    func activateTreeRow(_ id: TreeItemID) {
        let secs = panelHost.treeVM.renderedSections
        guard !treeRowIsInert(id) else { return }
        // R12: the first click on a PASSIVE tree (kbNav off — after a
        // mac-desktop switch, or after acting dropped key via exitActive)
        // WAKES keyboard nav and parks the cursor on the clicked row instead
        // of acting; the second click (or Enter) acts. The deliberate
        // two-step recovery the old tree had (`SidebarView+Drag` R12) — a
        // stray click on the visible-but-passive panel must not yank the
        // user to another workspace.
        if !sidebarView.kbNav {
            enterActive()                          // seeds the cursor…
            panelHost.treeVM.parkCursor(on: id)    // …then park on the CLICKED row
            previewTargetChanged()
            return
        }
        exitActive(restore: false)
        switch id {
        case .header(let sectionID):
            guard let g = secs.firstIndex(where: { $0.id == sectionID })
            else { return }
            let sec = secs[g]
            if let i = sec.sourceWorkspaceIndex {
                // Workspace header: claim the workspace's predicted focus
                // optimistically (no row when it's empty), then activate.
                // `i` is 0-based; `ActiveSection.workspace` is 1-based → +1.
                if let pred = lastWorkspaces.first(where: { $0.index == i })?
                    .windows.predictedFocus()?.id {
                    panelHost.treeVM.setOptimistic(.window(group: g, pred))
                }
                activateSection(.workspace(i + 1), autoFocus: true)
            } else {
                // An isolate desktop's matched / holding header: nothing to
                // activate (`ActiveSection` is single-case since t-ec9s) —
                // focus the section's FIRST window, the unified §G helper.
                focusFirstWindow(inSectionID: sec.id)
            }
        case .window(let g, let wid):
            guard g >= 0, g < secs.count else { return }
            let sec = secs[g]
            // The row's REAL workspace (a matched-section row lives in its
            // real ws — the `realWS` resolution), else the section's source,
            // else the active ws.
            let activeIdx = lastWorkspaces.first(where: { $0.isActive })?.index
            let i = lastWorkspaces
                .first { $0.windows.contains { $0.id == wid } }?.index
                ?? sec.sourceWorkspaceIndex ?? activeIdx ?? 0
            guard let winModel = lastWorkspaces
                .first(where: { $0.index == i })?
                .windows.first(where: { $0.id == wid })
                ?? sec.windows.first(where: { $0.id == wid })
            else { return }
            let needSwitch = (i != activeIdx)
            panelHost.treeVM.setOptimistic(id)
            // A HIDDEN row (Cmd+H'd / minimized — hide-reclaim pulled its
            // tile slot) is restored on activation; a normal row just
            // focuses. Off main so the click never hitches (handleClick
            // parity).
            let hidden = winModel.isOnscreen == false
            cliQueue.async { [bk = backend] in
                if needSwitch {
                    bk.switchWorkspace(toIndex: i, autoFocus: false)
                }
                if hidden {
                    bk.revealWindow(wid)
                } else {
                    Task { @MainActor [weak self] in
                        self?.focusWindow(winModel, postSwitch: needSwitch)
                    }
                }
            }
        }
    }

    /// `m` in keyboard nav: the cursor row's context menu, anchored just past
    /// the panel's right edge, level with the row — `kbContextMenu` parity
    /// for the SwiftUI tree. Anchor: the live viewport rect (sill 7.0.0
    /// publishes rects for laid-out rows), falling back to the scroll-blind
    /// summed-`ListMetrics` offset when the row is culled out of the viewport.
    private func showTreeCursorMenu() {
        let vm = panelHost.treeVM
        guard let row = vm.cursorRow() else { return }
        // Anchor beside the panel, level with the row's TOP: the LIVE viewport
        // rect when the row is laid out, else the metric-summed fallback.
        let anchorY: CGFloat? = panelHost.rowScreenRect(row.id).map(\.maxY)
            ?? vm.rowTop(of: row.id).flatMap {
                panelHost.menuAnchorBesideTreeRow(contentOffset: $0)?.y
            }
        guard let y = anchorY else { return }
        showTreeRowMenu(row, at: NSPoint(x: panelHost.panel.frame.maxX + 8, y: y))
    }

    /// The row's context menu at a screen point — shared by the `m` key (which
    /// anchors beside the panel) and the host's right-click (which anchors at
    /// the event, `PanelHost.onRowRightClick`). Same dispatch the retired
    /// `SidebarView.rightMouseDown` had: window row → ops menu, workspace
    /// header → layout + rename, matched header → isolate menu, holding
    /// header → none (t-63h2).
    func showTreeRowMenu(_ row: TreeRowSpec, at scr: NSPoint) {
        let secs = panelHost.treeVM.renderedSections
        switch row.id {
        case .header(let sectionID):
            guard let g = secs.firstIndex(where: { $0.id == sectionID })
            else { return }
            let sec = secs[g]
            if let ws = sec.sourceWorkspaceIndex {
                // `headerMenu`'s `group` is a two-coordinate contract
                // (`sectionHeaderDisplay` / `beginSectionRename`): section mode
                // = the display ordinal, degrade = `ws.index`. `g` is the
                // display position in `renderedSections`, which in degrade
                // diverges from `ws.index` after a reorder — passing it renamed
                // (and persisted to config.toml) the wrong workspace.
                sidebarView.headerMenu(at: scr,
                                       group: treeRenderIsSectionMode ? g : ws,
                                       workspaceIndex: ws,
                                       filterable: true)
            } else if sec.sectionType == .matched {
                sidebarView.isolateHeaderMenu(at: scr, group: g, filterable: true)
            }                       // holding header: no menu (t-63h2)
        case .window(let g, let wid):
            guard case .window(let pid) = row.kind else { return }
            let i = lastWorkspaces
                .first { $0.windows.contains { $0.id == wid } }?.index
                ?? (g >= 0 && g < secs.count
                        ? secs[g].sourceWorkspaceIndex : nil)
                ?? lastWorkspaces.first(where: { $0.isActive })?.index ?? 0
            sidebarView.showWindowMenu(at: scr, workspaceIndex: i, pid: pid,
                                       windowID: wid,
                                       title: row.secondary ?? row.primary,
                                       filterable: true)
        }
    }

    // MARK: - SwiftUI tree DnD commits (facet-2)

    /// The ONE drop route: the sill mouse drag gesture (`PanelHost.onDropRow`)
    /// and the host-driven keyboard lift (`handleKbKey` → `treeVM.commitDrag`)
    /// both land here. Maps sill's placement onto facet's commits — applyMove
    /// for a window row, reorderSection for a section chunk, the background
    /// `moveWindow` in the by-workspace degrade (the mode-3 header swap was
    /// dropped from the pilot, §2.4a). Validity is POST-hoc — no
    /// `dropTargetValidator` yet (T3 / t-6r5m is the pilot's first
    /// fast-follow): an inert drop reaches a no-op server plan and the next
    /// reconcile snaps the row back.
    func treeDrop(_ ctx: ListCore.DragContext<TreeItemID>,
                  _ target: ListCore.DropTarget<TreeItemID>) {
        let secs = panelHost.treeVM.renderedSections
        // ONE rule set for the commit and the pre-validation seam — see
        // `resolveTreeDrop`. A placement this rejects never drew an affordance
        // and never joined the keyboard aim, so reaching here with nil means
        // a stale target (a refresh landed mid-drag): drop it silently.
        guard let resolution = resolveTreeDrop(
            ctx, target, sections: secs,
            sectionMode: treeRenderIsSectionMode,
            isolateDesktop: treeRenderIsIsolateDesktop) else { return }
        switch resolution {
        case .chunk(let boundary):
            guard case .header(let sid) = ctx.sourceID else { return }
            reorderSection(move: sid, toBoundary: boundary)
        case .window(let wid, let g, let t):
            if treeRenderIsSectionMode {
                applyMove(windowID: wid, fromSectionID: secs[g].id,
                          toSectionID: secs[t].id,
                          destSourceWorkspaceIndex: secs[t].sourceWorkspaceIndex)
            } else {
                // Degrade: a background "file it there" move — no switch, no
                // focus-follow (M9-1 parity with the retired AppKit drop).
                guard let ws = secs[t].sourceWorkspaceIndex else { return }
                cliQueue.async { [bk = backend] in
                    bk.moveWindow(wid, toWorkspaceIndex: ws)
                }
                scheduleReconcile(after: 0.05)
            }
        }
    }

    /// sill's `dropTargetValidator` seam: the SAME resolver, so a placement the
    /// commit would refuse draws no affordance and joins no keyboard aim.
    func treeDropIsValid(_ ctx: ListCore.DragContext<TreeItemID>,
                         _ target: ListCore.DropTarget<TreeItemID>) -> Bool {
        resolveTreeDrop(ctx, target,
                        sections: panelHost.treeVM.renderedSections,
                        sectionMode: treeRenderIsSectionMode,
                        isolateDesktop: treeRenderIsIsolateDesktop) != nil
    }


    private func enterSearch() {
        sidebarView.beginSearch()
        panelHost.searchBar.stringValue = ""          // silent — no onChange echo
        panelHost.searchBar.trailingSymbol = nil      // clear-× waits for text
        panelHost.treeVM.setQuery("")
        panelHost.layout(searching: sidebarView.searching)
        _ = panelHost.searchBar.focus()               // IME input goes to the field
    }

    /// ESC out of search back to normal nav WITHOUT leaving the tree:
    /// end the filter and drop the field's first responder, but keep the
    /// panel key so kbNav continues. ESC never exits the tree — you leave
    /// by clicking another app or pressing Enter on a window, which resign
    /// key and let `handlePanelKeyChange` revert the activation policy.
    private func leaveSearchKeepingNav() {
        sidebarView.endSearch()
        panelHost.treeVM.setQuery("")                 // un-filter the tree
        panelHost.panel.makeFirstResponder(nil)
        panelHost.layout(searching: sidebarView.searching)
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
            // Resolve the EMITTED ordinal against `renderedSections` — the
            // callers (header menu / right-click) mint `g` from the rendered
            // list, and under a search filter a zero-match section drops, so
            // `lastSections[g]` would point one section OFF (S2: Rename hit
            // the wrong workspace and persisted it). The caption index stays
            // the UNFILTERED position (`--focus index:N`'s address space).
            let secs = panelHost.treeVM.renderedSections
            guard g >= 0, g < secs.count else { return }
            let sec = secs[g]
            // workspace / matched / holding all rename by the same stable-id
            // deferred-commit path — `renameSection(sectionID:…)` routes by kind
            // (workspace → catalog; the rest → session override).
            index1 = (lastSections.firstIndex { $0.id == sec.id } ?? g) + 1
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
        // Same emitted-ordinal resolution as `beginSectionRename` (S2).
        let secs = panelHost.treeVM.renderedSections
        guard g >= 0, g < secs.count else { return }
        let sec = secs[g]
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
