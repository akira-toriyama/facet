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

    // MARK: - index addressing

    @Test func indexResolvesToZeroBasedBoard() {
        #expect(resolveBoardFocus("index:2", boardLabels: ["A", "B", "C"]) ==
                       .resolved(boardIndex: 1))
    }

    @Test func indexOneResolvesToFirstBoard() {
        #expect(resolveBoardFocus("index:1", boardLabels: ["A", "B"]) ==
                       .resolved(boardIndex: 0))
    }

    /// An explicit out-of-range index is REJECTED loudly (not clamped) — the
    /// CLI carries user intent; a typo should surface, not silently land on the
    /// last board the way the display selector self-heals a stale state.
    @Test func indexAboveCountIsOutOfRange() {
        #expect(resolveBoardFocus("index:4", boardLabels: ["A", "B", "C"]) ==
                       .outOfRange(requested: 4, count: 3))
    }

    /// A non-positive index (defensive — the client only emits `index:N` for
    /// N > 0) is out of range, mirroring `dispatchSectionFocus`'s `n >= 1` guard.
    @Test func indexZeroIsOutOfRange() {
        #expect(resolveBoardFocus("index:0", boardLabels: ["A", "B"]) ==
                       .outOfRange(requested: 0, count: 2))
    }

    // MARK: - label addressing

    @Test func labelResolvesToItsBoard() {
        #expect(resolveBoardFocus("label:Views",
                                         boardLabels: ["Spaces", "Views"]) ==
                       .resolved(boardIndex: 1))
    }

    @Test func unknownLabelIsRejected() {
        #expect(resolveBoardFocus("label:Nope",
                                         boardLabels: ["Spaces", "Views"]) ==
                       .unknownLabel("Nope"))
    }

    /// Empty-labeled boards are index-addressed only — a label lookup never
    /// matches them (mirrors the config rule: name resolution targets only
    /// labeled boards; unnamed ones are index-addressed).
    @Test func labelSkipsEmptyLabeledBoards() {
        #expect(resolveBoardFocus("label:Views",
                                         boardLabels: ["", "Views"]) ==
                       .resolved(boardIndex: 1))
        #expect(resolveBoardFocus("label:",
                                         boardLabels: ["", "Views"]) ==
                       .unknownLabel(""))
    }

    // MARK: - flat-config degrade (no boards = one implicit board)

    @Test func flatConfigFocusOneIsIdempotent() {
        #expect(resolveBoardFocus("index:1", boardLabels: []) ==
                       .resolved(boardIndex: 0))
    }

    @Test func flatConfigFocusTwoIsOutOfRange() {
        #expect(resolveBoardFocus("index:2", boardLabels: []) ==
                       .outOfRange(requested: 2, count: 1))
    }

    @Test func flatConfigLabelIsUnknown() {
        #expect(resolveBoardFocus("label:Spaces", boardLabels: []) ==
                       .unknownLabel("Spaces"))
    }

    // MARK: - malformed

    @Test func missingPrefixIsMalformed() {
        #expect(resolveBoardFocus("Spaces", boardLabels: ["A"]) ==
                       .malformed)
    }

    @Test func nonIntegerIndexIsMalformed() {
        #expect(resolveBoardFocus("index:two", boardLabels: ["A", "B"]) ==
                       .malformed)
    }
}
