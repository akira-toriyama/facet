import CoreGraphics
import Testing
@testable import FacetCore

// Evaluation table for the `facet filter` evaluator (pivot Phase 0, #283
// PR#2): parse → match over hand-built Window + WindowQueryEntry fixtures
// (managed + unmanaged). Freezes the field-name map, the unmanaged-window
// rule, and each CSS operator's semantics. CI-ONLY (CLT cannot run
// `swift test`); the logic was also verified standalone via swiftc.
struct FacetFilterEvalTests {

    typealias FWS = WindowQueryEntry.FacetWindowState

    // MARK: fixtures

    private func win(app: String = "Safari", title: String = "Home",
                     bundle: String? = "com.apple.Safari",
                     floating: Bool = false, sticky: Bool = false,
                     master: Bool = false, focused: Bool = false,
                     onscreen: Bool = true, mark: String? = nil,
                     scratchpad: String? = nil, tags: [String] = []) -> Window {
        Window(id: .init(serverID: 1), pid: 100, appName: app, title: title,
               isFocused: focused, isFloating: floating, frame: nil,
               isOnscreen: onscreen, isMaster: master, bundleId: bundle,
               mark: mark, isSticky: sticky, scratchpad: scratchpad, tags: tags)
    }
    private func managed(workspace: String = "Dev", index: Int = 1,
                         tags: [String] = [], floating: Bool = false,
                         sticky: Bool = false, master: Bool = false,
                         parked: Bool = false,
                         mark: String? = nil, scratchpad: String? = nil) -> FWS {
        FWS(workspace: workspace, workspaceIndex: index, tags: tags,
            floating: floating, sticky: sticky, master: master, parked: parked,
            mark: mark, scratchpad: scratchpad)
    }
    private func entry(app: String = "Safari", title: String = "Home",
                       bundle: String? = "com.apple.Safari", desktop: Int? = 1,
                       onscreen: Bool = true, focused: Bool = false,
                       facet: FWS?) -> WindowQueryEntry {
        WindowQueryEntry(id: 1, pid: 100, app: app, title: title,
                         bundleId: bundle, desktop: desktop, frame: nil,
                         onscreen: onscreen, focused: focused, facet: facet)
    }

    private func m(_ expr: String, _ w: some WindowFields,
                   _ file: StaticString = #filePath, _ line: UInt = #line) -> Bool {
        switch FacetFilter.parse(expr) {
        case .success(let f): return f.matches(w)
        case .failure(let e):
            Issue.record("parse failed for \"\(expr)\": \(e.message)")
            return false
        }
    }

    // MARK: ~= token-contains on tags

    @Test func tokenContainsOnTags() {
        let w = win(tags: ["web", "docs"])
        #expect(m("tag~=web", w))
        #expect(m("tag~=docs", w))
        #expect(!m("tag~=urgent", w))
        #expect(!m("tag~=we", w))   // whole-token, not substring
    }

    // An EMPTY `~=` value is ALWAYS a no-match: the whitespace split uses
    // omittingEmptySubsequences (default), so it never yields an empty token
    // for `.contains { $0 == "" }` to find — regardless of the field's
    // contents. This corner is separate from the ^=/$=/*= empty→nothing rule
    // the doc pins; a regression keeping empty subsequences (or special-casing
    // empty) would make `tag~=""` match every / no window silently.
    @Test func tokenContainsEmptyValueMatchesNothing() {
        #expect(!m("tag~=\"\"", win(tags: ["web", "docs"])))
        #expect(!m("tag~=\"\"", win(tags: [])))
    }

    @Test func tagExactMeansOnlyThatTag() {
        #expect(m("tag=web", win(tags: ["web"])))
        #expect(!m("tag=web", win(tags: ["web", "docs"])))
    }

    @Test func tagPresence() {
        #expect(m("tag", win(tags: ["web"])))
        #expect(!m("not tag", win(tags: ["web"])))
        #expect(!m("tag", win(tags: [])))
        #expect(m("not tag", win(tags: [])))
    }

    // MARK: unmanaged-window rule (FROZEN)

    @Test func unmanagedEntry() {
        let e = entry(facet: nil)
        #expect(m("not tag", e), "unmanaged matches `not tag`")
        #expect(!m("tag", e), "tag-presence must NOT match unmanaged")
        #expect(!m("tag~=web", e))
        #expect(m("floating", e), "unmanaged reads as floating")
        #expect(!m("not floating", e))
        #expect(!m("sticky", e))
        #expect(!m("master", e))
        // top-level fields still resolve for an unmanaged window
        #expect(m("app=Safari", e))
        #expect(m("desktop=1", e))
    }

    // For a MANAGED-but-unnamed window (facet != nil, workspace == ""),
    // WindowQueryEntry.filterHas("workspace") = !("".isEmpty) = false, so the
    // empty name collapses to ABSENT: `not workspace` MATCHES it and a
    // `workspace` presence filter DROPS it. This is the OPPOSITE of the
    // ProjectedWindowFields conformer's empty-name-present distinction — an
    // intentional but unpinned coalescing on the `facet query --windows
    // --filter` surface. A refactor keying presence on `facet != nil` (to
    // mirror the projection conformers) would silently flip which windows
    // `not workspace` lists.
    @Test func queryEntryUnnamedWorkspaceReadsAbsent() {
        #expect(!m("workspace", entry(facet: managed(workspace: ""))))
        #expect(m("not workspace", entry(facet: managed(workspace: ""))))
        // contrast: a named workspace is present.
        #expect(m("workspace", entry(facet: managed(workspace: "Dev"))))
    }

    // mark / scratchpad through a WindowQueryEntry: for a managed entry they
    // read out of the nested facet block; for an unmanaged entry (facet==nil)
    // both resolve to absent/nil. Completes the FROZEN unmanaged-window
    // contract (mark/scratchpad were omitted from the source header's freeze,
    // which only enumerates tag/floating/sticky/master). A change to the
    // optional-chaining default (e.g. defaulting to a value like floating does)
    // would go uncaught on the query surface.
    @Test func queryEntryMarkAndScratchpad() {
        #expect(m("mark=a", entry(facet: managed(mark: "a"))))
        #expect(m("scratchpad", entry(facet: managed(scratchpad: "term"))))
        #expect(!m("mark", entry(facet: nil)))
        #expect(!m("scratchpad", entry(facet: nil)))
    }

    // MARK: bare boolean flags (managed)

    @Test func managedFlagsPresence() {
        let on = entry(focused: true,
                       facet: managed(floating: true, sticky: true, master: true))
        #expect(m("floating", on))
        #expect(m("sticky", on))
        #expect(m("master", on))
        #expect(m("focused", on))
        #expect(m("onscreen", on))

        let off = entry(focused: false, facet: managed())
        #expect(!m("floating", off))
        #expect(m("not floating", off))
        #expect(!m("focused", off))
    }

    @Test func windowFlagsAndOptionalPresence() {
        let w = win(floating: true, sticky: true, master: true, focused: true,
                    mark: "a", scratchpad: "term", tags: ["web"])
        #expect(m("floating", w))
        #expect(m("sticky", w))
        #expect(m("master", w))
        #expect(m("focused", w))
        #expect(m("onscreen", w))
        #expect(m("mark", w))
        #expect(m("scratchpad", w))

        let plain = win()
        #expect(!m("mark", plain))
        #expect(!m("scratchpad", plain))
        #expect(m("not floating", plain))
    }

    // MARK: case-sensitivity flag

    @Test func caseInsensitiveByDefault() {
        let w = win(app: "Safari")
        #expect(m("app=safari", w))      // insensitive default
        #expect(m("app=SAFARI", w))
    }

    @Test func caseSensitiveFlag() {
        let w = win(app: "Safari")
        #expect(!m("app=safari s", w))   // ` s` → sensitive
        #expect(m("app=Safari s", w))
    }

    // MARK: each CSS operator

    @Test func operators() {
        let e = entry(title: "Pull Request 42", facet: managed())
        #expect(m("title^=Pull", e))
        #expect(m("title^=pull", e))     // insensitive
        #expect(!m("title^=Request", e))
        #expect(m("title$=42", e))
        #expect(!m("title$=Pull", e))
        #expect(m("title*=Request", e))
        #expect(!m("title*=xyz", e))
        #expect(m("title=\"Pull Request 42\"", e))
        #expect(!m("title=Pull", e))
    }

    @Test func hierarchicalOperator() {
        #expect(m("workspace|=dog", entry(facet: managed(workspace: "dog"))))
        #expect(m("workspace|=dog", entry(facet: managed(workspace: "dog-2"))))
        #expect(!m("workspace|=dog", entry(facet: managed(workspace: "doghouse"))))
    }

    // The `|=` (hierarchical) operator with an EMPTY value evaluates
    // `a == "" || a.hasPrefix("-")`, so it matches ONLY a field whose value is
    // itself empty and never reaches the `-`-prefix arm — distinct from the
    // ^=/$=/*= empty→nothing rule. If `|=` were folded into that shared
    // empty→false guard (or the `+ "-"` concat altered), this branch would
    // flip silently; it is the only operator whose empty-value semantics is
    // otherwise unpinned.
    @Test func hierarchicalEmptyValueMatchesOnlyEmptyField() {
        #expect(!m("workspace|=\"\"", entry(facet: managed(workspace: "dog"))))
        // contrast: a window whose workspace name is empty DOES match.
        #expect(m("workspace|=\"\"", entry(facet: managed(workspace: ""))))
    }

    @Test func emptyValueMatchesNothing() {
        let e = entry(title: "Home", facet: managed())
        #expect(!m("title^=\"\"", e))
        #expect(!m("title$=\"\"", e))
        #expect(!m("title*=\"\"", e))
        // exact-empty still works (matches an empty field)
        #expect(!m("title=\"\"", e))
        #expect(m("title=\"\"", entry(title: "", facet: managed())))
    }

    // MARK: workspace is a NAME, not the index

    @Test func workspaceMatchesNameNotIndex() {
        let named1 = entry(facet: managed(workspace: "1", index: 5))
        #expect(m("workspace=1", named1))
        let dev = entry(facet: managed(workspace: "Dev", index: 1))
        #expect(!m("workspace=1", dev), "index 1 must not match name '1'")
        #expect(m("workspace=Dev", dev))
    }

    @Test func desktopField() {
        let d2 = entry(desktop: 2, facet: managed())
        #expect(m("desktop=2", d2))
        #expect(!m("desktop=3", d2))
        #expect(m("desktop", d2))
        let none = entry(desktop: nil, facet: managed())
        #expect(!m("desktop", none))
        #expect(!m("desktop=2", none))
    }

    // MARK: Window does not carry workspace / desktop (documented)

    @Test func windowWorkspaceDesktopAreNoMatch() {
        let w = win()
        #expect(!m("workspace=Dev", w))
        #expect(!m("workspace", w))
        #expect(!m("desktop=1", w))
    }

    // MARK: combinators end-to-end

    @Test func combinators() {
        let e = entry(app: "Safari", facet: managed(tags: ["web"]))
        #expect(m("tag~=web and not floating", e))
        #expect(!m("tag~=web and floating", e))
        #expect(m("(tag~=web or tag~=docs) and not tag~=wip", e))
        #expect(m("app=Chrome or app=Safari", e))
        #expect(m("", e), ".all matches everything")
    }

    // MARK: typo detection (knownFields / fieldsReferenced)

    @Test func knownFields() {
        #expect(FacetFilter.knownFields.count == 13)
        for f in ["app", "title", "bundleId", "workspace", "tag", "floating",
                  "sticky", "master", "mark", "scratchpad", "desktop",
                  "onscreen", "focused"] {
            #expect(FacetFilter.knownFields.contains(f), "\(f)")
        }
    }

    // `FilterField` is the single source of the field-name catalogue (#23):
    // `knownFields` derives from it, and the wire spelling (`rawValue`) is
    // exactly the case name. This pins the catalogue so a case added or
    // removed without keeping the `WindowFields` conformers' switch
    // statements in step is caught loudly in CI (the whole point of folding
    // the four parallel name lists into one enum).
    @Test func filterFieldIsSingleSourceOfKnownFields() {
        #expect(FacetFilter.FilterField.allCases.count == 13)
        // knownFields is exactly the FilterField rawValues — no drift.
        #expect(
            Set(FacetFilter.FilterField.allCases.map(\.rawValue))
                == FacetFilter.knownFields)
        // rawValue == wire spelling == case name (catches a typo'd raw or a
        // renamed case that would silently change the `facet filter` surface).
        #expect(
            Set(FacetFilter.FilterField.allCases.map(\.rawValue))
                == ["app", "title", "bundleId", "workspace", "tag", "floating",
                    "sticky", "master", "mark", "scratchpad", "desktop",
                    "onscreen", "focused"])
    }

    @Test func fieldsReferencedAndUnknownIsNoMatch() {
        guard case .success(let f) =
                FacetFilter.parse("tag~=web and frob=x or not floating") else {
            Issue.record("parse")
            return
        }
        #expect(f.fieldsReferenced() == ["tag", "frob", "floating"])
        #expect(f.fieldsReferenced().subtracting(FacetFilter.knownFields)
                == ["frob"])   // the typo
        // an unknown field is a clean no-match, never a crash
        #expect(!m("frob=x", win(tags: ["web"])))
        #expect(!m("frob", win(tags: ["web"])))
    }
}
