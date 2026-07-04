import Testing
@testable import FacetCore

/// `resolveBoardFocus(_:boardLabels:)` — the pure resolver behind
/// `facet board --focus N|"label"` (t-wrd2 / W2.3). Given the encoded CLI
/// payload (`index:N` 1-based, or `label:LABEL` verbatim) and the ordered
/// board (`[[desktop.N.tab]]`) display labels for one mac desktop, it returns
/// either the 0-based board index to select or a LOUD-but-non-fatal reason
/// (out-of-range / unknown-label / malformed). Unlike the display selector
/// `activeBoardSections`, which CLAMPS a stale session index to self-heal, the
/// CLI resolver REJECTS an explicit out-of-range request (typo-fails-loudly,
/// matching `section --focus`). An EMPTY `boardLabels` is the flat-config
/// degrade case = ONE implicit board (index 1 only, no label). Pure FacetCore;
/// CI-only (CLT can't run `swift test`).
struct BoardFocusResolveTests {

    /// index addressing (out-of-range REJECTED loudly, not clamped — the CLI
    /// carries user intent; a non-positive index is defensively out-of-range),
    /// label addressing (empty-labeled boards are index-addressed only, so a
    /// label lookup never matches them), the flat-config degrade (empty
    /// `boardLabels` = one implicit board, index 1 only), and malformed payloads.
    @Test("resolveBoardFocus: index / label / flat-degrade / malformed", arguments: [
        // index addressing
        (payload: "index:2", boardLabels: ["A", "B", "C"], expected: .resolved(boardIndex: 1)),
        (payload: "index:1", boardLabels: ["A", "B"], expected: .resolved(boardIndex: 0)),
        (payload: "index:4", boardLabels: ["A", "B", "C"], expected: .outOfRange(requested: 4, count: 3)),  // reject, don't clamp
        (payload: "index:0", boardLabels: ["A", "B"], expected: .outOfRange(requested: 0, count: 2)),  // non-positive is out of range
        // label addressing
        (payload: "label:Views", boardLabels: ["Spaces", "Views"], expected: .resolved(boardIndex: 1)),
        (payload: "label:Nope", boardLabels: ["Spaces", "Views"], expected: .unknownLabel("Nope")),
        (payload: "label:Views", boardLabels: ["", "Views"], expected: .resolved(boardIndex: 1)),  // empty-labeled board is skipped
        (payload: "label:", boardLabels: ["", "Views"], expected: .unknownLabel("")),  // a label lookup never matches an empty label
        // flat-config degrade (no boards = one implicit board)
        (payload: "index:1", boardLabels: [], expected: .resolved(boardIndex: 0)),  // flat --focus 1 is idempotent
        (payload: "index:2", boardLabels: [], expected: .outOfRange(requested: 2, count: 1)),
        (payload: "label:Spaces", boardLabels: [], expected: .unknownLabel("Spaces")),
        // malformed
        (payload: "Spaces", boardLabels: ["A"], expected: .malformed),  // missing prefix
        (payload: "index:two", boardLabels: ["A", "B"], expected: .malformed),  // non-integer index
    ] as [(payload: String, boardLabels: [String], expected: BoardFocusResolution)])
    func resolve(payload: String, boardLabels: [String], expected: BoardFocusResolution) {
        #expect(resolveBoardFocus(payload, boardLabels: boardLabels) == expected)
    }
}
