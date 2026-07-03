import Testing
import Foundation
@testable import FacetCore

/// `FacetConfig.validate(_:)` is the STRICT counterpart to the lenient
/// `load()` — it surfaces the type / enum / range / unknown-key mismatches
/// the loader silently clamps or drops (sill 1.29.0 `Spec.validate` bridge,
/// driven by the SAME `configSpec` that decodes + emits the schema, t-0029).
/// `config --validate` shows these; `load()` still forgives them at runtime.
struct ConfigValidateTests {

    /// The committed `config.toml` template MUST validate with zero errors —
    /// the safety net proving facet's bespoke `[[exclude]]` / `[[rule]]` /
    /// `[[desktop.N.section]]` blocks don't trip the strict validator.
    @Test func committedTemplateValidatesClean() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FacetCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent("config.toml")
        let source = try String(contentsOf: url, encoding: .utf8)
        let errors = try FacetConfig.validate(source)
        #expect(errors == [],
                "shipped config.toml should validate clean; got: \(errors.map(\.message).joined(separator: "; "))")
    }

    /// An empty document (the missing-file case → all defaults) is valid.
    @Test func emptyDocumentIsValid() throws {
        #expect(try FacetConfig.validate("") == [])
    }

    /// `load()` silently ignores unknown keys; `validate` surfaces them.
    @Test func unknownKeyIsReported() throws {
        let errors = try FacetConfig.validate("""
        [grid]
        cols = 4
        bogus-key = 1
        """)
        #expect(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "bogus-key" }
            return false
        }, "unknown key should be reported; got \(errors.map(\.rule))")
    }

    /// `[grid].cols` is an integer; a string is a type mismatch.
    @Test func wrongTypeIsReported() throws {
        let errors = try FacetConfig.validate("""
        [grid]
        cols = "four"
        """)
        #expect(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "cols" }
            return false
        }, "type mismatch should be reported; got \(errors.map(\.rule))")
    }

    /// A genuine TOML syntax error throws (distinct from a schema violation).
    @Test func unparseableSourceThrows() {
        #expect(throws: (any Error).self) { try FacetConfig.validate("[grid\nbad") }
    }

    // MARK: - Coverage boundary on facet's bespoke arrays (t-0057 item #5)

    /// `[[exclude]]` is an `.arrayOfTables` section — STRICTLY validated, so
    /// a typo'd key IS reported (the spec's `descOnly` fields are the keyset).
    @Test func excludeArrayOfTablesUnknownKeyIsReported() throws {
        let errors = try FacetConfig.validate("""
        [[exclude]]
        app = "Safari"
        bogus-key = 1
        """)
        #expect(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "bogus-key" }
            return false
        }, "exclude is arrayOfTables (strict); got \(errors.map(\.rule))")
    }

    /// `[[desktop.N.section]]` folds to a `.dynamicTable` → a PERMISSIVE object
    /// (arbitrary keys accepted): facet decodes those blocks from raw text, so
    /// validate deliberately does NOT own their keys and must not false-flag a
    /// key it doesn't know. Pins the permissive boundary — a future switch to
    /// a strict section kind would flip this and break the raw-text decode.
    @Test func desktopSectionDynamicTableIsPermissive() throws {
        let errors = try FacetConfig.validate("""
        [[desktop.1.section]]
        type = "workspace"
        not-a-real-key = 1
        """)
        #expect(errors == [],
                "desktop section is dynamicTable (permissive); got: \(errors.map(\.message).joined(separator: "; "))")
    }
}
