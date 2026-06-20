import XCTest
@testable import FacetCore

/// `routeLens` (tag-unification Phase 1) — the pure `(action, grouping)` →
/// `LensEffect` / `LensRouteError` table that backs the unified `facet lens`
/// surface. Extracted from `FacetApp.runLensCommand` so the mode routing is
/// unit-testable without the exit() / DNC side effects.
final class LensRouteTests: XCTestCase {

    // MARK: - Positional NAME (adapts to the mode)

    func testNameTagMode_ShowsTags() {
        XCTAssertEqual(routeLens(.name("web"), grouping: .tag),
                       .success(.showTags("web")))
    }

    func testNameTagMode_CSVAllowed() {
        // CSV is tag-mode-only — a comma list passes through verbatim.
        XCTAssertEqual(routeLens(.name("web,code"), grouping: .tag),
                       .success(.showTags("web,code")))
    }

    func testNameSectionMode_ActivatesSection() {
        XCTAssertEqual(routeLens(.name("Web"), grouping: .workspace),
                       .success(.activateSection("Web")))
    }

    func testNameSectionMode_LabelWithSpaces_IsVerbatim() {
        // Section labels are free TOML strings; only a comma is special.
        XCTAssertEqual(routeLens(.name("My Web Lens"), grouping: .workspace),
                       .success(.activateSection("My Web Lens")))
    }

    func testNameSectionMode_CommaRejected() {
        // A comma in a section NAME is a CSV attempt — exit 2 (tag-mode-only).
        XCTAssertEqual(routeLens(.name("Web,Code"), grouping: .workspace),
                       .failure(.csvInSectionName(name: "Web,Code")))
    }

    // MARK: - --clear (the universal reset, both modes)

    func testClearTagMode_ShowsAll() {
        // Tag mode: the floor lens = show every window (same as --all).
        XCTAssertEqual(routeLens(.clear, grouping: .tag), .success(.showAll))
    }

    func testClearSectionMode_ClearsSection() {
        XCTAssertEqual(routeLens(.clear, grouping: .workspace),
                       .success(.clearSection))
    }

    // MARK: - --all (tag-only)

    func testAllTagMode_ShowsAll() {
        XCTAssertEqual(routeLens(.all, grouping: .tag), .success(.showAll))
    }

    func testAllSectionMode_Rejected() {
        XCTAssertEqual(routeLens(.all, grouping: .workspace),
                       .failure(.tagOnlyVerb(verb: "--all")))
    }

    // MARK: - Tag composition verbs (tag-only)

    func testAddRemoveToggleTagMode() {
        XCTAssertEqual(routeLens(.add("a,b"), grouping: .tag),
                       .success(.addTags("a,b")))
        XCTAssertEqual(routeLens(.remove("a"), grouping: .tag),
                       .success(.removeTags("a")))
        XCTAssertEqual(routeLens(.toggle("x,y"), grouping: .tag),
                       .success(.toggleTags("x,y")))
    }

    func testAddRemoveToggleSectionMode_Rejected() {
        let want = Result<LensEffect, LensRouteError>
            .failure(.tagOnlyVerb(verb: "--add/--remove/--toggle"))
        XCTAssertEqual(routeLens(.add("a"), grouping: .workspace), want)
        XCTAssertEqual(routeLens(.remove("a"), grouping: .workspace), want)
        XCTAssertEqual(routeLens(.toggle("a"), grouping: .workspace), want)
    }
}
