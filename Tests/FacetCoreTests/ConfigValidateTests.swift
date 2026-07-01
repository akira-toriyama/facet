import XCTest
@testable import FacetCore

/// `FacetConfig.validate(_:)` is the STRICT counterpart to the lenient
/// `load()` — it surfaces the type / enum / range / unknown-key mismatches
/// the loader silently clamps or drops (sill 1.29.0 `Spec.validate` bridge,
/// driven by the SAME `configSpec` that decodes + emits the schema, t-0029).
/// `config --validate` shows these; `load()` still forgives them at runtime.
final class ConfigValidateTests: XCTestCase {

    /// The committed `config.toml` template MUST validate with zero errors —
    /// the safety net proving facet's bespoke `[[exclude]]` / `[[rule]]` /
    /// `[[desktop.N.section]]` blocks don't trip the strict validator.
    func testCommittedTemplateValidatesClean() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FacetCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent("config.toml")
        let source = try String(contentsOf: url, encoding: .utf8)
        let errors = try FacetConfig.validate(source)
        XCTAssertEqual(errors, [],
                       "shipped config.toml should validate clean; got: "
                           + errors.map(\.message).joined(separator: "; "))
    }

    /// An empty document (the missing-file case → all defaults) is valid.
    func testEmptyDocumentIsValid() throws {
        XCTAssertEqual(try FacetConfig.validate(""), [])
    }

    /// `load()` silently ignores unknown keys; `validate` surfaces them.
    func testUnknownKeyIsReported() throws {
        let errors = try FacetConfig.validate("""
        [grid]
        cols = 4
        bogus-key = 1
        """)
        XCTAssertTrue(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "bogus-key" }
            return false
        }, "unknown key should be reported; got \(errors.map(\.rule))")
    }

    /// `[grid].cols` is an integer; a string is a type mismatch.
    func testWrongTypeIsReported() throws {
        let errors = try FacetConfig.validate("""
        [grid]
        cols = "four"
        """)
        XCTAssertTrue(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "cols" }
            return false
        }, "type mismatch should be reported; got \(errors.map(\.rule))")
    }

    /// A genuine TOML syntax error throws (distinct from a schema violation).
    func testUnparseableSourceThrows() {
        XCTAssertThrowsError(try FacetConfig.validate("[grid\nbad"))
    }

    // MARK: - Coverage boundary on facet's bespoke arrays (t-0057 item #5)

    /// `[[exclude]]` is an `.arrayOfTables` section — STRICTLY validated, so
    /// a typo'd key IS reported (the spec's `descOnly` fields are the keyset).
    func testExcludeArrayOfTablesUnknownKeyIsReported() throws {
        let errors = try FacetConfig.validate("""
        [[exclude]]
        app = "Safari"
        bogus-key = 1
        """)
        XCTAssertTrue(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "bogus-key" }
            return false
        }, "exclude is arrayOfTables (strict); got \(errors.map(\.rule))")
    }

    /// `[[desktop.N.section]]` folds to a `.dynamicTable` → a PERMISSIVE object
    /// (arbitrary keys accepted): facet decodes those blocks from raw text, so
    /// validate deliberately does NOT own their keys and must not false-flag a
    /// key it doesn't know. Pins the permissive boundary — a future switch to
    /// a strict section kind would flip this and break the raw-text decode.
    func testDesktopSectionDynamicTableIsPermissive() throws {
        let errors = try FacetConfig.validate("""
        [[desktop.1.section]]
        type = "workspace"
        not-a-real-key = 1
        """)
        XCTAssertEqual(errors, [],
                       "desktop section is dynamicTable (permissive); got: "
                           + errors.map(\.message).joined(separator: "; "))
    }
}
