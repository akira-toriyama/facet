import Testing
import Foundation
@testable import FacetCore

/// The committed `config.schema.json` (shipped next to `config.toml`,
/// pointed at by its `#:schema` directive) MUST equal what the live spec
/// emits — otherwise editor completion drifts from the actual parser.
/// Regenerate with: `facet config --emit-schema > config.schema.json`.
struct ConfigSchemaDriftTests {

    @Test func committedSchemaMatchesSpec() throws {
        // Locate the repo-root schema relative to THIS source file, so the
        // check is independent of the test runner's working directory.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FacetCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent("config.schema.json")
        let committed = try String(contentsOf: url, encoding: .utf8)
        #expect(
            committed == FacetConfig.jsonSchema,
            "config.schema.json is stale — run `facet config --emit-schema > config.schema.json` and commit.")
    }

    /// Enum-domain vocabularies are now DERIVED from `.allCases` (t-5qxd
    /// config-DRY: `exclude.action` ← `ExclusionAction`, `desktop.*.type` ←
    /// `SectionType`), so a hand-mirrored literal can no longer silently drift
    /// from the enum. These asserts freeze the WIRE spellings + case order so
    /// adding / renaming / reordering a case fails loudly here — and, for
    /// `action`, keeps the positional `enumDocs` aligned to the cases.
    @Test func enumVocabulariesAreFrozen() throws {
        // Config.toml surface spellings + order; changing these is a
        // user-visible config break and must be a conscious edit.
        #expect(ExclusionAction.allCases.map(\.rawValue) == ["float", "ignore", "manage"])
        #expect(SectionType.allCases.map(\.rawValue) == ["workspace", "lens"])

        // `[[exclude]].action` derives its domain from ExclusionAction, and its
        // enumDocs are index-aligned to the cases — guard both from the spec so
        // a new case can't leave a doc-less (misaligned) enum value.
        let action = FacetConfig.configSpec
            .sections.first { $0.header == "exclude" }?
            .fields.first { $0.key == "action" }
        #expect(action?.domain == ExclusionAction.allCases.map(\.rawValue))
        #expect(action?.enumDocs?.count == ExclusionAction.allCases.count)
    }
}
