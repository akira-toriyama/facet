import Testing
import Foundation
@testable import FacetCore

/// B1 (t-hdxb): the `[config]` (export-path / auto-promote) + `[tags] defined`
/// schema — raw decode, `effective*` clamping, and the `resolvePath` helper.
struct ConfigPersistenceSchemaTests {

    // MARK: - [config]

    @Test func exportPathDecodesAndTrims() {
        let c = FacetConfig.from(toml: parseTOMLSubset("""
            [config]
            export-path = "~/.config/facet/config.snapshot.toml"
            """))
        #expect(c.effectiveExportPath ==
                       "~/.config/facet/config.snapshot.toml")
    }

    @Test func exportPathBlankOrUnsetIsNil() {
        #expect(FacetConfig().effectiveExportPath == nil, "unset → auto-export off")
        let blank = FacetConfig.from(toml: parseTOMLSubset("""
            [config]
            export-path = "   "
            """))
        #expect(blank.effectiveExportPath == nil, "blank → auto-export off")
    }

    /// Surrounding whitespace is stripped while the inner path stays verbatim.
    /// Regression guard: `exportPathDecodesAndTrims` uses a value with NO
    /// surrounding whitespace, so its trim is a no-op there — a version that
    /// returned the raw field would leak the padding (breaking downstream
    /// `resolvePath`) yet still pass that test.
    @Test func exportPathTrimsSurroundingWhitespace() {
        let c = FacetConfig.from(toml: parseTOMLSubset("""
            [config]
            export-path = "  ~/foo/snap.toml  "
            """))
        #expect(c.effectiveExportPath == "~/foo/snap.toml")
    }

    @Test func autoPromoteDefaultsOff() {
        #expect(!(FacetConfig().effectiveAutoPromote), "default off")
        let on = FacetConfig.from(toml: parseTOMLSubset("""
            [config]
            auto-promote = true
            """))
        #expect(on.effectiveAutoPromote)
    }

    // MARK: - [tags] defined

    @Test func definedTagsDecodesArrayOnly() {
        let c = FacetConfig.from(toml: parseTOMLSubset("""
            [tags]
            defined = ["web", "code", "chat"]
            """))
        #expect(c.effectiveDefinedTags == ["web", "code", "chat"])
    }

    @Test func definedTagsTrimsDropsBlanksDedupsKeepsOrder() {
        var c = FacetConfig()
        c.definedTags = ["  web ", "", "code", "web", "  ", "chat"]
        #expect(c.effectiveDefinedTags == ["web", "code", "chat"],
                       "trimmed, blanks dropped, first-wins dedup, order kept")
    }

    @Test func definedTagsUnsetIsEmpty() {
        #expect(FacetConfig().effectiveDefinedTags == [])
    }

    // MARK: - resolvePath

    @Test func resolvePathAbsolutePassesThrough() {
        #expect(
            FacetConfig.resolvePath("/tmp/snap.toml", relativeTo: "/anywhere") ==
            "/tmp/snap.toml")
    }

    @Test func resolvePathExpandsTilde() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        #expect(
            FacetConfig.resolvePath("~/snap.toml", relativeTo: "/ignored") ==
            "\(home)/snap.toml")
    }

    @Test func resolvePathRelativeJoinsBaseDir() {
        #expect(
            FacetConfig.resolvePath("config.snapshot.toml",
                                    relativeTo: "/Users/x/.config/facet") ==
            "/Users/x/.config/facet/config.snapshot.toml")
    }

    // MARK: - resolvePath canonicalizes . / .. / // (self-write-guard defence)

    @Test func resolvePathCollapsesDotSegments() {
        let base = "/Users/x/.config/facet"
        #expect(FacetConfig.resolvePath("./config.toml", relativeTo: base) ==
                       "/Users/x/.config/facet/config.toml")
        #expect(FacetConfig.resolvePath("../facet/config.toml", relativeTo: base) ==
                       "/Users/x/.config/facet/config.toml")
        #expect(FacetConfig.resolvePath("sub/../config.toml", relativeTo: base) ==
                       "/Users/x/.config/facet/config.toml")
    }

    @Test func isSameFileMatchesNonCanonicalAliases() {
        let cfg = "/Users/x/.config/facet/config.toml"
        #expect(FacetConfig.isSameFile(
            FacetConfig.resolvePath("./config.toml", relativeTo: "/Users/x/.config/facet"),
            cfg), "./config.toml aliases config.toml")
        #expect(FacetConfig.isSameFile(
            FacetConfig.resolvePath("../facet/config.toml", relativeTo: "/Users/x/.config/facet"),
            cfg))
        #expect(!(FacetConfig.isSameFile(
            FacetConfig.resolvePath("config.snapshot.toml", relativeTo: "/Users/x/.config/facet"),
            cfg)), "a genuinely different file is not the same")
    }
}
