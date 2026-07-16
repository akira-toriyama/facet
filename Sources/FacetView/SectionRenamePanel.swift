// Section-rename panel — the inline editor for the §E header "Rename" row.
//
// The third sibling of `PopupMenu` / `TagEditPanel`: a singleton
// (`SectionRenamePanel.shared`) drawn purely with the passed palette,
// flipped at the screen edge, hosting one `NSTextField` (the new label,
// pre-filled with the current label + select-all). Because it hosts a real
// field it must take key + IME, so it is a `KeyablePanel` (`wantsKey = true`)
// and the Controller flips the app to a regular, active app around
// show()/close() (the same activation-policy dance the tree panel + tag
// editor use).
//
// Deliberately NOT a TagEditPanel reuse: that panel is tag-coupled (a
// scrollable checklist / vocabulary list, "+ Create", `TagName`
// normalisation). A section rename is a single text field with no list, so a
// minimal new panel is simpler than retrofitting branches. It DOES borrow the
// rename sub-behaviour's visual grammar: pencil glyph in the field, header
// band, keycode 36/76 = commit, 53 = cancel.

import AppKit
import FacetCore

/// t-0020 (Option B): the panel's verdict on the edited text, computed ON COMMIT
/// (not live — a live check flickers on every field's first keystrokes, since a
/// partial field name reads as "unknown"; a flicker-free live indicator needs the
/// cursor-context machinery of the autocompletion follow-on). Both non-`.ok` cases
/// BLOCK commit (keep the panel open), differing only in tint:
///   • `.ok` — commit (an empty predicate is `.ok` → the revert gesture).
///   • `.warn(msg)` — a SOFT mistake: an unknown field (valid syntax, but no such
///     filter field → matches nothing). Shown in `tertiary`.
///   • `.error(msg)` — a hard SYNTAX error. Shown in `error` (red).
/// The rename panel passes no validator, so it always commits (`.ok` path). The
/// Controller builds this from `classifyMatchPredicate` (runtime `--match` is
/// strict — a typo is a loud reject; config stays soft / degrade-don't-crash).
public enum SectionEditValidation: Equatable {
    case ok
    case warn(String)
    case error(String)
}

// MARK: - Container (card background + header, hosts the field)

/// The panel's content view: draws the rounded card, the header caption (the
/// §D `index (label)` line), the field outline + pencil glyph. The editable
/// `NSTextField` is a subview.
final class SectionRenameContainerView: NSView {
    var header = ""
    var palette: ResolvedPalette = resolve(.terminal)
    /// t-0020 (Option B): when the panel validates its input (the `--match`
    /// edit), reserve a row below the field for the validation message and draw
    /// it whenever `messageText` is set. `messageIsError` picks the tint: a
    /// BLOCKING syntax error is `palette.error` (red), a NON-blocking warning
    /// (an unknown field — valid but matches nothing) is `palette.tertiary`. The
    /// rename panel leaves these at their defaults, so its layout is byte-identical.
    var reservesErrorRow = false
    var messageText: String?
    var messageIsError = false
    /// t-kywh: height of the filter-alias checklist below the error row
    /// (0 when the picker is absent — the rename panel and an alias-less
    /// config keep their exact layout). The list itself is a scroll-view
    /// subview; the container only draws the divider above it.
    var aliasListHeight: CGFloat = 0

    static let padX: CGFloat = 12
    static let padV: CGFloat = 10
    static let headerH: CGFloat = 18
    static let fieldH: CGFloat = 30
    static let fieldGap: CGFloat = 8
    static let errorGap: CGFloat = 6
    static let errorH: CGFloat = 16

    override var isFlipped: Bool { true }

    /// Top of the field box (below the header band).
    var fieldTop: CGFloat { Self.padV + Self.headerH + Self.fieldGap }

    override func draw(_ dirty: NSRect) {
        // Card. Accent border (1.5pt) like the tag panel — always `primary`
        // (the frame is panel chrome).
        let bg = palette.background ?? NSColor.windowBackgroundColor
        let card = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 9, yRadius: 9)
        bg.setFill(); card.fill()
        palette.primary.setStroke(); card.lineWidth = 1.5; card.stroke()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail

        // Header caption — the §D `index (label)` line. `secondary` to match
        // the SECTION menu tint (section actions read secondary).
        (header as NSString).draw(
            in: NSRect(x: Self.padX, y: Self.padV,
                       width: bounds.width - Self.padX * 2, height: Self.headerH),
            withAttributes: [.font: uiFont(13, .bold),
                             .foregroundColor: palette.secondary,
                             .paragraphStyle: para])

        // Field box.
        let fieldBox = NSRect(x: Self.padX, y: fieldTop,
                              width: bounds.width - Self.padX * 2,
                              height: Self.fieldH)
        let fb = NSBezierPath(roundedRect: fieldBox, xRadius: 7, yRadius: 7)
        (bg.blended(withFraction: 0.06, of: .white) ?? bg).setFill(); fb.fill()
        palette.border.setStroke(); fb.lineWidth = 1; fb.stroke()
        // Pencil glyph — the inline-rename affordance (matches TagEditPanel's
        // rename sub-state).
        if let icon = IconResolver.resolve(
            "SF:pencil", pointSize: 13, color: palette.muted) {
            let isz = icon.size
            icon.draw(in: NSRect(x: Self.padX + 8,
                                 y: fieldTop + (Self.fieldH - isz.height) / 2,
                                 width: isz.width, height: isz.height))
        }

        // t-0020 (Option B): the validation message in the reserved row below the
        // field — a BLOCKING syntax error (red, shown on commit) or a NON-blocking
        // unknown-field warning (tertiary, shown live as you type). Single line
        // truncated; the full caret goes to the CLI, the inline editor is concise.
        if reservesErrorRow, let messageText, !messageText.isEmpty {
            (messageText as NSString).draw(
                in: NSRect(x: Self.padX,
                           y: fieldTop + Self.fieldH + Self.errorGap,
                           width: bounds.width - Self.padX * 2, height: Self.errorH),
                withAttributes: [.font: uiFont(11, .regular),
                                 .foregroundColor: messageIsError
                                     ? palette.error : palette.tertiary,
                                 .paragraphStyle: para])
        }

        // t-kywh: divider above the alias checklist (mirrors TagEditPanel's
        // field/list divider).
        if aliasListHeight > 0 {
            let sy = bounds.height - Self.padV - aliasListHeight
                - SectionRenamePanel.aliasListGap / 2
            palette.border.setStroke()
            let sp = NSBezierPath()
            sp.move(to: NSPoint(x: Self.padX, y: sy))
            sp.line(to: NSPoint(x: bounds.width - Self.padX, y: sy))
            sp.stroke()
        }
    }
}

// MARK: - Alias checklist (t-kywh)

/// The filter-alias PICKER rows — the tag-checklist interaction grammar
/// (`TagEditListView`) applied to `[alias]` names: checkbox + `@name`,
/// hover/keyboard share one selection highlight, a pick TOGGLES. Checked =
/// "this alias is a top-level OR term of the current match" (derived by
/// `matchCheckedAliases`); toggling applies LIVE (案A — the tag-panel model:
/// the isolate desktop re-tiles on every toggle, Esc merely dismisses).
/// `enabled = false` (a malformed hand-edit in the field) dims the rows and
/// ignores picks — the field's validation message owns that state.
final class AliasPickListView: NSView {
    var names: [String] = []
    var checked: Set<String> = []
    var enabled = true
    var sel = 0
    var palette: ResolvedPalette = resolve(.terminal)
    var onPick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    static let rowH: CGFloat = 28

    override var isFlipped: Bool { true }

    func contentHeight() -> CGFloat {
        CGFloat(max(names.count, 1)) * Self.rowH
    }

    private func rowIndex(at p: NSPoint) -> Int? {
        let i = Int(p.y / Self.rowH)
        return (i >= 0 && i < names.count) ? i : nil
    }

    override func draw(_ dirty: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let boxSide: CGFloat = 14
        // The picker tint is `secondary` throughout — the tag-checklist
        // grammar this view borrows (the SECTION menu reads secondary too).
        let tint = enabled ? palette.secondary : palette.muted
        for (i, name) in names.enumerated() {
            let r = NSRect(x: 0, y: CGFloat(i) * Self.rowH,
                           width: bounds.width, height: Self.rowH)
            if i == sel, enabled {
                let pill = r.insetBy(dx: 4, dy: 2)
                palette.secondary.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
                palette.secondary.setStroke()
                let o = NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1),
                                     xRadius: 6, yRadius: 6)
                o.lineWidth = 1.5; o.stroke()
            }
            let boxRect = NSRect(x: SectionRenameContainerView.padX,
                                 y: r.minY + (Self.rowH - boxSide) / 2,
                                 width: boxSide, height: boxSide)
            let box = NSBezierPath(roundedRect: boxRect, xRadius: 3, yRadius: 3)
            let isChecked = checked.contains(name.lowercased())
            if isChecked {
                tint.setFill(); box.fill()
                ("✓" as NSString).draw(
                    in: boxRect.offsetBy(dx: 2.5, dy: 0.5),
                    withAttributes: [.font: uiFont(11, .bold),
                                     .foregroundColor: palette.background ?? .white])
            } else {
                palette.muted.setStroke(); box.lineWidth = 1; box.stroke()
            }
            let textX = SectionRenameContainerView.padX + boxSide + 8
            ("@\(name)" as NSString).draw(
                in: NSRect(x: textX, y: r.minY + 5,
                           width: r.width - textX - SectionRenameContainerView.padX,
                           height: Self.rowH - 6),
                withAttributes: [
                    .font: uiFont(13, isChecked ? .semibold : .regular),
                    .foregroundColor: tint,
                    .paragraphStyle: para,
                ])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseMoved],
            owner: self))
    }

    override func mouseMoved(with e: NSEvent) {
        if let i = rowIndex(at: convert(e.locationInWindow, from: nil)),
           i != sel { onHover?(i) }
    }

    override func mouseUp(with e: NSEvent) {
        guard enabled else { return }
        if let i = rowIndex(at: convert(e.locationInWindow, from: nil)) {
            onPick?(i)
        }
    }
}

// MARK: - Panel controller

@MainActor
public final class SectionRenamePanel: NSObject, NSTextFieldDelegate {
    public static let shared = SectionRenamePanel()

    private var panel: KeyablePanel?
    private var field: NSTextField?
    private weak var aliasList: AliasPickListView?
    private var monitors: [Any] = []

    /// t-kywh 案A: the text last APPLIED through `onCommitCB` (seeded with
    /// `initialText` — the already-effective match). Enter is dual-role: a
    /// DIRTY field (text ≠ lastApplied) commits it; a clean one toggles the
    /// selected alias row. Esc always just dismisses (toggles are already
    /// live — there is nothing to commit or revert).
    private var lastApplied = ""

    /// The CONFIG match this desktop falls back to when the override is
    /// cleared (empty for the rename panel). The picker's uncheck-all floor:
    /// applying `""` reverts to the config match, so the panel RE-SYNCS its
    /// field + checks to this — the checklist mirrors the EFFECTIVE match at
    /// all times and never shows "nothing selected" while the config match
    /// keeps tiling (トミー, 2026-07-16: "@web を外しても Chrome が残る" —
    /// it must LOOK that way too, with a message saying why).
    private var configMatch = ""

    private var onCommitCB: ((String) -> Void)?
    private var onCloseCB: (() -> Void)?
    /// t-0020 (Option B): when set, the edited text is VALIDATED — live (each
    /// keystroke, to surface a non-blocking `.warn`) and on commit (a `.error`
    /// keeps the panel open, a `.warn`/`.ok` commits). nil (the rename panel)
    /// commits unconditionally.
    private var onValidateCB: ((String) -> SectionEditValidation)?
    private var closing = false

    public var isOpen: Bool { panel != nil }

    private override init() { super.init() }

    /// Present the editor anchored at `screenPt` (its TOP edge). `header` is
    /// the §D `index (label)` caption; `initialText` pre-fills the field and is
    /// selected (so typing replaces it). `onCommit` fires with the field text
    /// on Enter; `onClose` fires exactly once on any close path (so the
    /// Controller can revert its activation policy / re-key the tree).
    ///
    /// t-0020: `validate` (Option B) opts the panel into validation — run live on
    /// each keystroke (to surface a non-blocking `.warn`, e.g. an unknown field)
    /// AND on commit (a `.error` shows red + keeps the panel open with key, so an
    /// invalid `--match` predicate never closes the editor or clobbers the working
    /// lens; a `.warn`/`.ok` commits). nil keeps the rename panel's
    /// commit-unconditionally behaviour (and its layout) byte-identical.
    ///
    /// t-kywh: `aliases` (the config `[alias]` names, sorted by the caller) adds
    /// the filter-alias PICKER — a tag-style CHECKLIST below the field (案A,
    /// 2026-07-16: the TagEditPanel interaction model, not chips). Checked =
    /// the alias is a top-level OR term of the current match; toggling a row
    /// rewrites the match to the OR of the checked set (hand-written non-alias
    /// terms survive) and applies it LIVE through `onCommit` WITHOUT closing —
    /// the isolate desktop re-tiles on every toggle, exactly like a tag toggle
    /// hits the window instantly. The inserted text is plain `@name` (CLI-first:
    /// the notation is the canon). Empty (the default, and the rename panel)
    /// adds nothing and the layout is byte-identical.
    public func show(at screenPt: NSPoint,
                     header: String,
                     initialText: String,
                     palette: ResolvedPalette,
                     onCommit: @escaping (String) -> Void,
                     onClose: @escaping () -> Void,
                     validate: ((String) -> SectionEditValidation)? = nil,
                     aliases: [String] = [],
                     configMatch: String = "") {
        close()
        closing = false
        self.onCommitCB = onCommit
        self.onCloseCB = onClose
        self.onValidateCB = validate

        // Auto-fit the width to the content — the prefilled text (a label or, for
        // `--match`, a `facet filter` predicate that can run long) and the header
        // caption — clamped to [min, max]. Short content keeps the 280 default
        // (so a typical rename is unchanged); a long predicate grows the panel so
        // it is visible without scrolling, capped so it never spans the screen.
        let minWidth: CGFloat = 280
        let maxWidth: CGFloat = 600
        let textW = (initialText as NSString)
            .size(withAttributes: [.font: uiFont(13, .regular)]).width
        let headerW = (header as NSString)
            .size(withAttributes: [.font: uiFont(13, .bold)]).width
        let fit = max(textW + SectionRenameContainerView.padX * 2 + 32 + 12,
                      headerW + SectionRenameContainerView.padX * 2)
        let width = min(maxWidth, max(minWidth, ceil(fit)))
        // Reserve the error row only when validating (the `--match` edit), so the
        // plain rename panel keeps its exact height. The alias checklist rides
        // below it (match edit + a non-empty `[alias]` table only), capped at
        // `maxVisibleAliasRows` with an overlay scroller beyond.
        let showList = validate != nil && !aliases.isEmpty
        let listH = showList ? Self.aliasListVisibleHeight(count: aliases.count) : 0
        let height = Self.panelHeight(validating: validate != nil,
                                      aliasRowsHeight: listH)

        let origin = placePopupOrigin(anchor: screenPt,
                                      size: NSSize(width: width, height: height))

        let pnl = KeyablePanel(
            contentRect: NSRect(origin: origin,
                                size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        pnl.wantsKey = true
        pnl.isFloatingPanel = true
        pnl.level = .popUpMenu
        pnl.backgroundColor = .clear
        pnl.isOpaque = false
        pnl.hasShadow = true
        pnl.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                  .fullScreenAuxiliary]

        let cont = SectionRenameContainerView(
            frame: NSRect(x: 0, y: 0, width: width, height: height))
        cont.header = header
        cont.palette = palette
        cont.reservesErrorRow = validate != nil
        cont.aliasListHeight = listH

        let f = NSTextField(frame: NSRect(
            x: SectionRenameContainerView.padX + 24,
            y: cont.fieldTop + 6,
            width: width - SectionRenameContainerView.padX * 2 - 32,
            height: SectionRenameContainerView.fieldH - 12))
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        f.font = uiFont(13, .regular)
        f.textColor = palette.foreground
        f.stringValue = initialText
        f.delegate = self
        cont.addSubview(f)

        // t-kywh: the alias checklist (match edit only), below the error row.
        if showList {
            let listW = width - SectionRenameContainerView.padX * 2
            let list = AliasPickListView(frame: NSRect(
                x: 0, y: 0, width: listW,
                height: CGFloat(aliases.count) * AliasPickListView.rowH))
            list.names = aliases
            list.palette = palette
            list.onPick = { [weak self] i in self?.toggleAliasRow(i) }
            list.onHover = { [weak self] i in
                self?.aliasList?.sel = i
                self?.aliasList?.needsDisplay = true
            }
            let scroll = NSScrollView(frame: NSRect(
                x: SectionRenameContainerView.padX,
                y: height - SectionRenameContainerView.padV - listH,
                width: listW, height: listH))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            let scroller = ThemedScroller()
            scroller.paletteBox = PaletteBox(palette)
            scroll.verticalScroller = scroller
            let clip = FlippedClipView()
            clip.drawsBackground = false
            scroll.contentView = clip
            scroll.documentView = list
            cont.addSubview(scroll)
            self.aliasList = list
        }

        pnl.contentView = cont
        self.panel = pnl
        self.field = f
        self.lastApplied = initialText
        self.configMatch = configMatch
        refreshAliasChecks()

        pnl.makeKeyAndOrderFront(nil)
        pnl.makeFirstResponder(f)
        // Pre-select the current label so typing replaces it (the rename
        // gesture mirrors TagEditPanel.beginRename).
        f.currentEditor()?.selectAll(nil)
        installMonitors()
    }

    /// Commit the current field text and close. Fires `onCommit` (verbatim —
    /// the Controller / E1 owns the empty-revert + trim semantics).
    ///
    /// t-0020 (Option B): when a `validate` closure is set, run it FIRST. Both a
    /// `.error` (syntax) and a `.warn` (unknown field) are rejections — show the
    /// message (red / tertiary), keep the panel open + key (do NOT fire
    /// `onCommit` / close), so an invalid `--match` predicate is a no-op the user
    /// fixes in place. Only `.ok` commits (an empty predicate is `.ok` → the
    /// revert gesture).
    private func commit() {
        let text = field?.stringValue ?? ""
        if let validate = onValidateCB {
            let cont = panel?.contentView as? SectionRenameContainerView
            switch validate(text) {
            case .error(let message):
                cont?.messageText = message; cont?.messageIsError = true
                cont?.needsDisplay = true
                return
            case .warn(let message):
                cont?.messageText = message; cont?.messageIsError = false
                cont?.needsDisplay = true
                return
            case .ok:
                break
            }
        }
        let cb = onCommitCB
        close()
        cb?(text)
    }

    // MARK: - Alias checklist (t-kywh, 案A live apply)

    static let aliasListGap: CGFloat = 8
    static let maxVisibleAliasRows = 8

    /// Visible height of the checklist for `count` aliases — capped at
    /// `maxVisibleAliasRows` (the overlay scroller takes over beyond).
    static func aliasListVisibleHeight(count: Int) -> CGFloat {
        CGFloat(min(max(count, 1), maxVisibleAliasRows)) * AliasPickListView.rowH
    }

    /// The panel's total height — the ONE place the layout bands are summed,
    /// shared by `show` and the tests. `aliasRowsHeight` is 0 for the rename
    /// panel and an alias-less match edit (their heights stay byte-identical
    /// to pre-picker).
    static func panelHeight(validating: Bool,
                            aliasRowsHeight: CGFloat) -> CGFloat {
        let errorRowH: CGFloat = validating
            ? SectionRenameContainerView.errorGap + SectionRenameContainerView.errorH
            : 0
        let listBand = aliasRowsHeight > 0 ? aliasListGap + aliasRowsHeight : 0
        return SectionRenameContainerView.padV
            + SectionRenameContainerView.headerH
            + SectionRenameContainerView.fieldGap
            + SectionRenameContainerView.fieldH
            + errorRowH
            + listBand
            + SectionRenameContainerView.padV
    }

    /// Toggle the alias at row `i`: rewrite the field to the current match
    /// with that alias added/removed as a top-level OR term
    /// (`matchTogglingAlias` — hand-written non-alias terms survive), then
    /// apply LIVE. A malformed hand-edit refuses the toggle (the checklist
    /// is derived from the text; there is nothing sound to rewrite) — the
    /// commit-path validation message explains, in red.
    private func toggleAliasRow(_ i: Int) {
        guard let field, let list = aliasList,
              i >= 0, i < list.names.count else { return }
        list.sel = i
        guard let newText = matchTogglingAlias(field.stringValue,
                                               name: list.names[i]) else {
            showValidation(.error("fix the predicate first — it does not parse"))
            return
        }
        field.stringValue = newText
        applyLive(newText)
        refreshAliasChecks()
    }

    /// 案A: push `text` through the SAME commit route the Enter key uses —
    /// validated first, `onCommit` on `.ok` — but WITHOUT closing, so a
    /// toggle re-tiles the isolate desktop while the panel stays up (the
    /// tag-panel model). A composed OR of defined aliases is always `.ok`;
    /// the non-`.ok` verdicts can only come from residual hand-written
    /// terms, and then the message shows and nothing is applied.
    ///
    /// Applying `""` (uncheck-all) is the REVERT gesture: the override is
    /// dropped and the CONFIG match takes over — so the panel re-syncs its
    /// field + checks to `configMatch` and says so. Without this the
    /// checklist showed "nothing selected" while the config match kept
    /// tiling — a lie by omission (the config default has no uncheck; the
    /// floor below the checkboxes is config.toml).
    private func applyLive(_ text: String) {
        if let validate = onValidateCB {
            let verdict = validate(text)
            guard case .ok = verdict else {
                showValidation(verdict)
                return
            }
        }
        lastApplied = text
        onCommitCB?(text)
        if text.isEmpty, !configMatch.isEmpty {
            field?.stringValue = configMatch
            lastApplied = configMatch
            showValidation(.warn("reverted to the config match"))
            refreshAliasChecks()
        } else {
            showValidation(.ok)
        }
    }

    /// Re-derive the checklist's checked set from the CURRENT field text
    /// (`matchCheckedAliases`), so hand-typing `@dev or @web` checks the
    /// rows and deleting a ref unchecks it. Malformed text goes inert-dim
    /// instead of guessing.
    private func refreshAliasChecks() {
        guard let list = aliasList, let field else { return }
        if let checked = matchCheckedAliases(field.stringValue) {
            list.checked = checked
            list.enabled = true
        } else {
            list.enabled = false
        }
        list.needsDisplay = true
    }

    /// Render a validation verdict into the message row (or clear it, `.ok`).
    private func showValidation(_ v: SectionEditValidation) {
        guard let cont = panel?.contentView as? SectionRenameContainerView
        else { return }
        switch v {
        case .ok:
            cont.messageText = nil
        case .warn(let message):
            cont.messageText = message; cont.messageIsError = false
        case .error(let message):
            cont.messageText = message; cont.messageIsError = true
        }
        cont.needsDisplay = true
    }

    /// ↑↓ / Ctrl-n/p over the checklist (a single-line field has no use for
    /// vertical arrows, so the list borrows them — the TagEditPanel keys).
    private func moveAliasSel(_ d: Int) {
        guard let list = aliasList, !list.names.isEmpty else { return }
        list.sel = min(max(list.sel + d, 0), list.names.count - 1)
        list.needsDisplay = true
        list.scrollToVisible(NSRect(
            x: 0, y: CGFloat(list.sel) * AliasPickListView.rowH,
            width: list.frame.width, height: AliasPickListView.rowH))
    }

    /// t-0020 (Option B): validation is COMMIT-time (not live — see
    /// `SectionEditValidation`), so as the user edits we only CLEAR a stale
    /// message from the previous rejected commit, so it doesn't linger while they
    /// fix the predicate. The verdict is recomputed + shown on the next commit.
    public func controlTextDidChange(_ obj: Notification) {
        // t-kywh: the checklist mirrors the text — hand-typing `@dev` checks
        // its row, deleting a ref unchecks it, malformed dims the list.
        refreshAliasChecks()
        guard let cont = panel?.contentView as? SectionRenameContainerView,
              cont.messageText != nil else { return }
        cont.messageText = nil
        cont.needsDisplay = true
    }

    /// Close on any path. Idempotent; fires `onClose` exactly once so the
    /// Controller can revert the activation policy on EVERY close path.
    public func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        field = nil
        aliasList = nil
        lastApplied = ""
        onCommitCB = nil
        onValidateCB = nil
        let cb = onCloseCB
        onCloseCB = nil
        if !closing { closing = true; cb?() }
    }

    private var isComposing: Bool {
        (field?.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    private func installMonitors() {
        // Click in another app closes the panel (commit-less cancel).
        monitors.append(NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { _ in
                MainActor.assumeIsolated { SectionRenamePanel.shared.close() }
            }) as Any)
        // Keys + clicks inside facet.
        monitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] ev in
            guard let self, let panel = self.panel else { return ev }
            if ev.type == .keyDown {
                // IME composing: let the field handle everything (Enter
                // commits the conversion, arrows move candidates, Esc cancels).
                if self.isComposing { return ev }
                let hasList = self.aliasList?.names.isEmpty == false
                switch ev.keyCode {
                case 36, 76:                             // Return / keypad Enter
                    // Dual-role (t-kywh 案A): a DIRTY field commits the typed
                    // text (apply + close, the historic gesture); a CLEAN one
                    // toggles the selected alias row live (the panel's primary
                    // flow once toggles apply instantly — dismissing is Esc).
                    if let list = self.aliasList, list.enabled, hasList,
                       self.field?.stringValue == self.lastApplied {
                        self.toggleAliasRow(list.sel)
                    } else {
                        self.commit()
                    }
                    return nil
                case 53:     self.close();  return nil   // Esc → dismiss
                case 125 where hasList:                  // ↓ → list selection
                    self.moveAliasSel(1);  return nil
                case 126 where hasList:                  // ↑
                    self.moveAliasSel(-1); return nil
                default:
                    let c = ev.charactersIgnoringModifiers?.lowercased()
                    let ctrl = ev.modifierFlags.contains(.control)
                    if ctrl, c == "n", hasList { self.moveAliasSel(1);  return nil }
                    if ctrl, c == "p", hasList { self.moveAliasSel(-1); return nil }
                    return ev                            // typing → field
                    // (live re-validation runs in `controlTextDidChange`, which
                    //  clears a stale error + re-derives the checklist)
                }
            }
            // A click anywhere but our own panel cancels (close, no commit).
            if ev.window !== panel { self.close() }
            return ev
        } as Any)
    }
}
