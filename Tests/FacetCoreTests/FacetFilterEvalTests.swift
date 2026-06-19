import CoreGraphics
import XCTest
@testable import FacetCore

// Evaluation table for the `facet filter` evaluator (pivot Phase 0, #283
// PR#2): parse → match over hand-built Window + WindowQueryEntry fixtures
// (managed + unmanaged). Freezes the field-name map, the unmanaged-window
// rule, and each CSS operator's semantics. CI-ONLY (CLT cannot run
// `swift test`); the logic was also verified standalone via swiftc.
final class FacetFilterEvalTests: XCTestCase {

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
                         mark: String? = nil, scratchpad: String? = nil) -> FWS {
        FWS(workspace: workspace, workspaceIndex: index, tags: tags,
            floating: floating, sticky: sticky, master: master,
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
            XCTFail("parse failed for \"\(expr)\": \(e.message)", file: file, line: line)
            return false
        }
    }

    // MARK: ~= token-contains on tags

    func testTokenContainsOnTags() {
        let w = win(tags: ["web", "docs"])
        XCTAssertTrue(m("tag~=web", w))
        XCTAssertTrue(m("tag~=docs", w))
        XCTAssertFalse(m("tag~=urgent", w))
        XCTAssertFalse(m("tag~=we", w))   // whole-token, not substring
    }

    func testTagExactMeansOnlyThatTag() {
        XCTAssertTrue(m("tag=web", win(tags: ["web"])))
        XCTAssertFalse(m("tag=web", win(tags: ["web", "docs"])))
    }

    func testTagPresence() {
        XCTAssertTrue(m("tag", win(tags: ["web"])))
        XCTAssertFalse(m("not tag", win(tags: ["web"])))
        XCTAssertFalse(m("tag", win(tags: [])))
        XCTAssertTrue(m("not tag", win(tags: [])))
    }

    // MARK: unmanaged-window rule (FROZEN)

    func testUnmanagedEntry() {
        let e = entry(facet: nil)
        XCTAssertTrue(m("not tag", e), "unmanaged matches `not tag`")
        XCTAssertFalse(m("tag", e), "tag-presence must NOT match unmanaged")
        XCTAssertFalse(m("tag~=web", e))
        XCTAssertTrue(m("floating", e), "unmanaged reads as floating")
        XCTAssertFalse(m("not floating", e))
        XCTAssertFalse(m("sticky", e))
        XCTAssertFalse(m("master", e))
        // top-level fields still resolve for an unmanaged window
        XCTAssertTrue(m("app=Safari", e))
        XCTAssertTrue(m("desktop=1", e))
    }

    // MARK: bare boolean flags (managed)

    func testManagedFlagsPresence() {
        let on = entry(focused: true,
                       facet: managed(floating: true, sticky: true, master: true))
        XCTAssertTrue(m("floating", on))
        XCTAssertTrue(m("sticky", on))
        XCTAssertTrue(m("master", on))
        XCTAssertTrue(m("focused", on))
        XCTAssertTrue(m("onscreen", on))

        let off = entry(focused: false, facet: managed())
        XCTAssertFalse(m("floating", off))
        XCTAssertTrue(m("not floating", off))
        XCTAssertFalse(m("focused", off))
    }

    func testWindowFlagsAndOptionalPresence() {
        let w = win(floating: true, sticky: true, master: true, focused: true,
                    mark: "a", scratchpad: "term", tags: ["web"])
        XCTAssertTrue(m("floating", w))
        XCTAssertTrue(m("sticky", w))
        XCTAssertTrue(m("master", w))
        XCTAssertTrue(m("focused", w))
        XCTAssertTrue(m("onscreen", w))
        XCTAssertTrue(m("mark", w))
        XCTAssertTrue(m("scratchpad", w))

        let plain = win()
        XCTAssertFalse(m("mark", plain))
        XCTAssertFalse(m("scratchpad", plain))
        XCTAssertTrue(m("not floating", plain))
    }

    // MARK: case-sensitivity flag

    func testCaseInsensitiveByDefault() {
        let w = win(app: "Safari")
        XCTAssertTrue(m("app=safari", w))      // insensitive default
        XCTAssertTrue(m("app=SAFARI", w))
    }

    func testCaseSensitiveFlag() {
        let w = win(app: "Safari")
        XCTAssertFalse(m("app=safari s", w))   // ` s` → sensitive
        XCTAssertTrue(m("app=Safari s", w))
    }

    // MARK: each CSS operator

    func testOperators() {
        let e = entry(title: "Pull Request 42", facet: managed())
        XCTAssertTrue(m("title^=Pull", e))
        XCTAssertTrue(m("title^=pull", e))     // insensitive
        XCTAssertFalse(m("title^=Request", e))
        XCTAssertTrue(m("title$=42", e))
        XCTAssertFalse(m("title$=Pull", e))
        XCTAssertTrue(m("title*=Request", e))
        XCTAssertFalse(m("title*=xyz", e))
        XCTAssertTrue(m("title=\"Pull Request 42\"", e))
        XCTAssertFalse(m("title=Pull", e))
    }

    func testHierarchicalOperator() {
        XCTAssertTrue(m("workspace|=dog", entry(facet: managed(workspace: "dog"))))
        XCTAssertTrue(m("workspace|=dog", entry(facet: managed(workspace: "dog-2"))))
        XCTAssertFalse(m("workspace|=dog", entry(facet: managed(workspace: "doghouse"))))
    }

    func testEmptyValueMatchesNothing() {
        let e = entry(title: "Home", facet: managed())
        XCTAssertFalse(m("title^=\"\"", e))
        XCTAssertFalse(m("title$=\"\"", e))
        XCTAssertFalse(m("title*=\"\"", e))
        // exact-empty still works (matches an empty field)
        XCTAssertFalse(m("title=\"\"", e))
        XCTAssertTrue(m("title=\"\"", entry(title: "", facet: managed())))
    }

    // MARK: workspace is a NAME, not the index

    func testWorkspaceMatchesNameNotIndex() {
        let named1 = entry(facet: managed(workspace: "1", index: 5))
        XCTAssertTrue(m("workspace=1", named1))
        let dev = entry(facet: managed(workspace: "Dev", index: 1))
        XCTAssertFalse(m("workspace=1", dev), "index 1 must not match name '1'")
        XCTAssertTrue(m("workspace=Dev", dev))
    }

    func testDesktopField() {
        let d2 = entry(desktop: 2, facet: managed())
        XCTAssertTrue(m("desktop=2", d2))
        XCTAssertFalse(m("desktop=3", d2))
        XCTAssertTrue(m("desktop", d2))
        let none = entry(desktop: nil, facet: managed())
        XCTAssertFalse(m("desktop", none))
        XCTAssertFalse(m("desktop=2", none))
    }

    // MARK: Window does not carry workspace / desktop (documented)

    func testWindowWorkspaceDesktopAreNoMatch() {
        let w = win()
        XCTAssertFalse(m("workspace=Dev", w))
        XCTAssertFalse(m("workspace", w))
        XCTAssertFalse(m("desktop=1", w))
    }

    // MARK: combinators end-to-end

    func testCombinators() {
        let e = entry(app: "Safari", facet: managed(tags: ["web"]))
        XCTAssertTrue(m("tag~=web and not floating", e))
        XCTAssertFalse(m("tag~=web and floating", e))
        XCTAssertTrue(m("(tag~=web or tag~=docs) and not tag~=wip", e))
        XCTAssertTrue(m("app=Chrome or app=Safari", e))
        XCTAssertTrue(m("", e), ".all matches everything")
    }

    // MARK: typo detection (knownFields / fieldsReferenced)

    func testKnownFields() {
        XCTAssertEqual(FacetFilter.knownFields.count, 13)
        for f in ["app", "title", "bundleId", "workspace", "tag", "floating",
                  "sticky", "master", "mark", "scratchpad", "desktop",
                  "onscreen", "focused"] {
            XCTAssertTrue(FacetFilter.knownFields.contains(f), f)
        }
    }

    // `FilterField` is the single source of the field-name catalogue (#23):
    // `knownFields` derives from it, and the wire spelling (`rawValue`) is
    // exactly the case name. This pins the catalogue so a case added or
    // removed without keeping the `WindowFields` conformers' switch
    // statements in step is caught loudly in CI (the whole point of folding
    // the four parallel name lists into one enum).
    func testFilterFieldIsSingleSourceOfKnownFields() {
        XCTAssertEqual(FacetFilter.FilterField.allCases.count, 13)
        // knownFields is exactly the FilterField rawValues — no drift.
        XCTAssertEqual(
            Set(FacetFilter.FilterField.allCases.map(\.rawValue)),
            FacetFilter.knownFields)
        // rawValue == wire spelling == case name (catches a typo'd raw or a
        // renamed case that would silently change the `facet filter` surface).
        XCTAssertEqual(
            Set(FacetFilter.FilterField.allCases.map(\.rawValue)),
            ["app", "title", "bundleId", "workspace", "tag", "floating",
             "sticky", "master", "mark", "scratchpad", "desktop",
             "onscreen", "focused"])
    }

    func testFieldsReferencedAndUnknownIsNoMatch() {
        guard case .success(let f) =
                FacetFilter.parse("tag~=web and frob=x or not floating") else {
            return XCTFail("parse")
        }
        XCTAssertEqual(f.fieldsReferenced(), ["tag", "frob", "floating"])
        XCTAssertEqual(f.fieldsReferenced().subtracting(FacetFilter.knownFields),
                       ["frob"])   // the typo
        // an unknown field is a clean no-match, never a crash
        XCTAssertFalse(m("frob=x", win(tags: ["web"])))
        XCTAssertFalse(m("frob", win(tags: ["web"])))
    }
}
