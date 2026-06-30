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
    }
}

// MARK: - Panel controller

@MainActor
public final class SectionRenamePanel: NSObject, NSTextFieldDelegate {
    public static let shared = SectionRenamePanel()

    private var panel: KeyablePanel?
    private var field: NSTextField?
    private var monitors: [Any] = []

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
    public func show(at screenPt: NSPoint,
                     header: String,
                     initialText: String,
                     palette: ResolvedPalette,
                     onCommit: @escaping (String) -> Void,
                     onClose: @escaping () -> Void,
                     validate: ((String) -> SectionEditValidation)? = nil) {
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
        // plain rename panel keeps its exact height.
        let errorRowH = validate == nil ? 0
            : SectionRenameContainerView.errorGap + SectionRenameContainerView.errorH
        let height = SectionRenameContainerView.padV
            + SectionRenameContainerView.headerH
            + SectionRenameContainerView.fieldGap
            + SectionRenameContainerView.fieldH
            + errorRowH
            + SectionRenameContainerView.padV

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

        pnl.contentView = cont
        self.panel = pnl
        self.field = f

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

    /// t-0020 (Option B): validation is COMMIT-time (not live — see
    /// `SectionEditValidation`), so as the user edits we only CLEAR a stale
    /// message from the previous rejected commit, so it doesn't linger while they
    /// fix the predicate. The verdict is recomputed + shown on the next commit.
    public func controlTextDidChange(_ obj: Notification) {
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
                switch ev.keyCode {
                case 36, 76: self.commit(); return nil   // Return / keypad Enter
                case 53:     self.close();  return nil   // Esc → cancel
                default:     return ev                   // typing → field
                    // (live re-validation runs in `controlTextDidChange`, which
                    //  clears a stale error + shows a live unknown-field warning)
                }
            }
            // A click anywhere but our own panel cancels (close, no commit).
            if ev.window !== panel { self.close() }
            return ev
        } as Any)
    }
}
