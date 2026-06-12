// Custom search bar used by the tree view's `--active` mode.
// `NSSearchField`'s system cell can't be vertically centred or themed
// to match `pal`, so we draw the rounded bg + border + magnifier
// glyph ourselves around a borderless `NSTextField`. The field stays
// `NSTextField` (not a hand-rolled text view) so the IME keeps
// working — caller must check `isComposing` before treating Return
// as a selection (otherwise IME confirm-Return gets swallowed).

import AppKit
import FacetView

/// Forwards live text changes (including IME-composed input) to a
/// caller-supplied closure. Owned by whoever wires up `SearchBar`;
/// the bar itself doesn't hold a delegate so external code can
/// observe the text without subclassing.
@MainActor
public final class SearchFieldDelegate: NSObject, NSTextFieldDelegate {
    public var onChange: ((String) -> Void)?

    public override init() { super.init() }

    public func controlTextDidChange(_ note: Notification) {
        (note.object as? NSControl).map { onChange?($0.stringValue) }
    }
}

@MainActor
public final class SearchBar: NSView {
    public let field = NSTextField()
    public override var isFlipped: Bool { true }

    /// True while the field owns key input (= search state A /
    /// insert; #187 modal focus). False = state B (nav): the panel
    /// keymap drives the result list and the box just displays the
    /// filter. Drives the border accent below.
    public var isFocused: Bool { field.currentEditor() != nil }

    /// Repaint the border when the field gains / loses the editor.
    /// KVO on the window's `firstResponder` — the only reliable
    /// signal that also catches a mouse click into the field (which
    /// bypasses the Controller's enter/leave paths).
    private var focusObs: NSKeyValueObservation?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObs = window?.observe(\.firstResponder, options: [.initial]) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyFocusStyle() }
        }
    }

    /// Border accent = the A/B visual cue (#187): accent color +
    /// thicker stroke while the box has focus (caret visible), the
    /// muted theme border while browsing results in state B.
    private func applyFocusStyle() {
        layer?.borderColor = isFocused
            ? pal.primary.cgColor : pal.border.cgColor
        layer?.borderWidth = isFocused ? 1.5 : 1
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        addSubview(field)
    }

    public required init?(coder: NSCoder) { nil }

    public var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue; needsLayout = true }
    }

    /// True while the IME has uncommitted (marked) text. Callers
    /// that bind Return / Escape / arrows must pass them through
    /// while this is true so the IME can commit / cancel composition.
    public var isComposing: Bool {
        (field.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    public func applyTheme() {
        let base = pal.background ?? NSColor.textBackgroundColor
        layer?.backgroundColor =
            (base.blended(withFraction: 0.06, of: .white) ?? base).cgColor
        applyFocusStyle()
        let f = uiFont(13, .regular)
        field.font = f
        field.textColor = pal.foreground
        field.placeholderAttributedString = NSAttributedString(
            string: "type to filter (↑↓ history)",
            attributes: [.foregroundColor: pal.muted, .font: f])
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        let lh = ceil(field.font?.boundingRectForFont.height ?? 16)
        let fx: CGFloat = 30                       // room for the glyph
        field.frame = NSRect(x: fx, y: (bounds.height - lh) / 2,
                             width: max(bounds.width - fx - 8, 0),
                             height: lh)
    }

    public override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: pal.muted,
        ]
        let g = "⌕" as NSString
        let s = g.size(withAttributes: a)
        g.draw(at: NSPoint(x: 9, y: (bounds.height - s.height) / 2),
               withAttributes: a)
    }
}
