import XCTest
import Foundation
@testable import FacetCore

/// B1 (t-hdxb): the `[config]` (export-path / auto-promote) + `[tags] defined`
/// schema — raw decode, `effective*` clamping, and the `resolvePath` helper.
final class ConfigPersistenceSchemaTests: XCTestCase {

    // MARK: - [config]

    func testExportPathDecodesAndTrims() {
        let c = FacetConfig.from(toml: parseTOMLSubset("""
            [config]
            export-path = "~/.config/facet/config.snapshot.toml"
            """))
        XCTAssertEqual(c.effectiveExportPath,
                       "~/.config/facet/config.snapshot.toml")
    }

    func testExportPathBlankOrUnsetIsNil() {
        XCTAssertNil(FacetConfig().effectiveExportPath, "unset → auto-export off")
        let blank = FacetConfig.from(toml: parseTOMLSubset("""
            [config]
            export-path = "   "
            """))
        XCTAssertNil(blank.effectiveExportPath, "blank → auto-export off")
    }

    func testAutoPromoteDefaultsOff() {
        XCTAssertFalse(FacetConfig().effectiveAutoPromote, "default off")
        let on = FacetConfig.from(toml: parseTOMLSubset("""
            [config]
            auto-promote = true
            """))
        XCTAssertTrue(on.effectiveAutoPromote)
    }

    // MARK: - [tags] defined

    func testDefinedTagsDecodesArrayOnly() {
        let c = FacetConfig.from(toml: parseTOMLSubset("""
            [tags]
            defined = ["web", "code", "chat"]
            """))
        XCTAssertEqual(c.effectiveDefinedTags, ["web", "code", "chat"])
    }

    func testDefinedTagsTrimsDropsBlanksDedupsKeepsOrder() {
        var c = FacetConfig()
        c.definedTags = ["  web ", "", "code", "web", "  ", "chat"]
        XCTAssertEqual(c.effectiveDefinedTags, ["web", "code", "chat"],
                       "trimmed, blanks dropped, first-wins dedup, order kept")
    }

    func testDefinedTagsUnsetIsEmpty() {
        XCTAssertEqual(FacetConfig().effectiveDefinedTags, [])
    }

    // MARK: - resolvePath

    func testResolvePathAbsolutePassesThrough() {
        XCTAssertEqual(
            FacetConfig.resolvePath("/tmp/snap.toml", relativeTo: "/anywhere"),
            "/tmp/snap.toml")
    }

    func testResolvePathExpandsTilde() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        XCTAssertEqual(
            FacetConfig.resolvePath("~/snap.toml", relativeTo: "/ignored"),
            "\(home)/snap.toml")
    }

    func testResolvePathRelativeJoinsBaseDir() {
        XCTAssertEqual(
            FacetConfig.resolvePath("config.snapshot.toml",
                                    relativeTo: "/Users/x/.config/facet"),
            "/Users/x/.config/facet/config.snapshot.toml")
    }
}
