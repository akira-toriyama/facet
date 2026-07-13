import Testing
@testable import FacetCore

// `facet query --windows --filter EXPR` post-filter (pivot Phase 1, #284
// PR#3). Freezes the loud-but-NON-FATAL contract of `QueryFilter.apply`:
//   • clean parse → the matching subset, no diagnostics;
//   • malformed EXPR → ALL windows (show-all degrade) + a caret to log;
//   • unknown field → the (no-match) subset + an `unknownFields` warning.
// The matching itself is covered by FacetFilterEvalTests; this pins the
// glue (degrade, diagnostics, order-preservation). CI-ONLY (CLT cannot run
// `swift test`); also verified standalone via swiftc.
struct QueryFilterTests {

    typealias FWS = WindowQueryEntry.FacetWindowState

    private func managed(workspace: String = "Dev", index: Int = 1,
                         tags: [String] = [], floating: Bool = false,
                         sticky: Bool = false, master: Bool = false,
                         parked: Bool = false) -> FWS {
        FWS(workspace: workspace, workspaceIndex: index, tags: tags,
            floating: floating, sticky: sticky, master: master, parked: parked,
            mark: nil, scratchpad: nil)
    }
    private func entry(id: Int, app: String = "Safari", title: String = "Home",
                       desktop: Int? = 1, onscreen: Bool = true,
                       focused: Bool = false, facet: FWS?) -> WindowQueryEntry {
        WindowQueryEntry(id: id, pid: 100, app: app, title: title,
                         bundleId: "com.example.\(app)", desktop: desktop,
                         frame: nil, onscreen: onscreen, focused: focused,
                         facet: facet)
    }

    /// A small mixed fixture: a tagged Safari, an untagged Chrome (managed),
    /// and an unmanaged window.
    private func fixture() -> [WindowQueryEntry] {
        [
            entry(id: 1, app: "Safari", facet: managed(tags: ["web"])),
            entry(id: 2, app: "Chrome", facet: managed(tags: [], floating: true)),
            entry(id: 3, app: "Terminal", facet: nil),     // unmanaged
        ]
    }

    // MARK: clean parse → matching subset, no diagnostics

    @Test func cleanFilterKeepsMatchesOnly() {
        let out = QueryFilter.apply("app=Safari", to: fixture())
        #expect(out.entries.map(\.id) == [1])
        #expect(out.parseErrorCaret == nil)
        #expect(out.unknownFields == [])
    }

    @Test func combinatorAcrossList() {
        let out = QueryFilter.apply("tag~=web or app=Chrome", to: fixture())
        #expect(out.entries.map(\.id) == [1, 2])
        #expect(out.parseErrorCaret == nil)
    }

    @Test func emptyExprKeepsEverything() {
        let out = QueryFilter.apply("   ", to: fixture())   // → .all
        #expect(out.entries.map(\.id) == [1, 2, 3])
        #expect(out.parseErrorCaret == nil)
        #expect(out.unknownFields == [])
    }

    @Test func orderIsPreserved() {
        // `not floating` keeps the tiled (non-floating) managed windows in
        // input order; Chrome (floating) and the unmanaged (floating) drop.
        let out = QueryFilter.apply("not floating", to: fixture())
        #expect(out.entries.map(\.id) == [1])
    }

    // MARK: malformed EXPR → show-all degrade + caret (NON-FATAL)

    @Test func parseErrorDegradesToShowAll() {
        let input = fixture()
        let out = QueryFilter.apply("tag~web", to: input)   // missing '=' after '~'
        #expect(out.entries.map(\.id) == input.map(\.id),
                "a parse error must show ALL windows, not none")
        #expect(out.parseErrorCaret != nil)
        #expect(out.parseErrorCaret?.contains("^") ?? false,
                "caret rendering present")
        #expect(out.unknownFields == [],
                "no fields resolve on a parse error")
    }

    @Test func unterminatedQuoteDegrades() {
        let out = QueryFilter.apply("title=\"oops", to: fixture())
        #expect(out.entries.count == 3)
        #expect(out.parseErrorCaret != nil)
    }

    // MARK: unknown field → subset + warning (NON-FATAL)

    @Test func unknownFieldWarnsButFilters() {
        // `frob` is unknown → its atom no-matches; the `or app=Chrome`
        // still selects Chrome. The typo surfaces in `unknownFields`.
        let out = QueryFilter.apply("frob=x or app=Chrome", to: fixture())
        #expect(out.entries.map(\.id) == [2])
        #expect(out.parseErrorCaret == nil)
        #expect(out.unknownFields == ["frob"])
    }

    @Test func unknownFieldsAreSortedAndDeduped() {
        let out = QueryFilter.apply("zeta=1 and alpha=2 and zeta=3",
                                    to: fixture())
        #expect(out.unknownFields == ["alpha", "zeta"])
        // This is also a clean-parse 0-match (both atoms no-match → and →
        // none): it must stay DISTINCT from the show-all error degrade.
        #expect(out.entries == [])
        #expect(out.parseErrorCaret == nil)
    }

    // MARK: the contract boundary — a clean 0-match is NOT the show-all degrade

    @Test func cleanZeroMatchKeepsNoneNotAll() {
        // A valid expression that matches nothing returns an EMPTY array
        // with no caret — the opposite of a malformed expression (which
        // shows ALL windows with a caret). Confusing the two would break
        // the whole loud-but-non-fatal design.
        let out = QueryFilter.apply("app=Nonexistent", to: fixture())
        #expect(out.entries == [])
        #expect(out.parseErrorCaret == nil)
        #expect(out.unknownFields == [])
    }

    // MARK: unmanaged-window rule survives the round-trip

    @Test func untaggedSelectsUnmanaged() {
        let out = QueryFilter.apply("not tag", to: fixture())
        // Chrome (managed, no tags) AND the unmanaged window are untagged.
        #expect(out.entries.map(\.id) == [2, 3])
        #expect(out.parseErrorCaret == nil)
    }
}
