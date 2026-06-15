import CoreGraphics
import XCTest
@testable import FacetCore
@testable import FacetAdapterNative

/// `NativeAdapter.definedTagNames()` / `currentLens()` (#228) — the
/// query-domain reads that fold the tag world into the status snapshot.
/// Both are thin wrappers over the catalog: `definedTagNames` is the
/// vocabulary, `currentLens` resolves the lens (the pure `showsAll`
/// truth table is exercised in FacetCore's `StatusTests`). These tests
/// pin the mode gate — workspace mode yields `[]` / `nil` so the read is
/// mode-tolerant — and the tag-mode wiring.
final class QueryTagsLensTests: XCTestCase {

    private func adapter() -> NativeAdapter {
        // Same harness as WindowMenuTests: FacetConfig() defaults are
        // fine; the init's AX branch is harmless under XCTest.
        NativeAdapter(config: FacetConfig())
    }

    /// Seed the adapter's catalog into tag mode with work/web/media and
    /// the given lens (default = work) — mirrors TagCatalogTests' setup
    /// but on the live adapter so the public accessors read real state.
    private func seedTagMode(_ a: NativeAdapter, lens: UInt64 = 0b001) {
        a.catalog.seed(configs: [(index: 1, config: WorkspaceConfig(name: ""))])
        a.catalog.seedTags(grouping: .tag,
                           model: TagModel(["work", "web", "media"]),
                           lens: lens)
    }

    // MARK: - Workspace-mode gate (mode-tolerant read)

    func testWorkspaceModeYieldsEmptyTagsAndNilLens() {
        // A fresh adapter is workspace mode: no vocabulary, no lens — the
        // read still works (no gate / no throw), it just reports "none".
        let a = adapter()
        XCTAssertEqual(a.definedTagNames(), [])
        XCTAssertNil(a.currentLens())
    }

    // MARK: - Tag mode

    func testDefinedTagNamesReturnsVocabularyInOrder() {
        let a = adapter()
        seedTagMode(a)
        XCTAssertEqual(a.definedTagNames(), ["work", "web", "media"])
    }

    func testCurrentLensReflectsSingleTagLens() {
        let a = adapter()
        seedTagMode(a, lens: 0b010)   // web only
        let lens = a.currentLens()
        XCTAssertEqual(lens?.tags, ["web"])
        XCTAssertEqual(lens?.showsAll, false)
    }

    func testCurrentLensFloorOnlyShowsAll() {
        let a = adapter()
        seedTagMode(a, lens: TagModel.defaultBit)   // startup / show-all
        let lens = a.currentLens()
        XCTAssertEqual(lens?.tags, [])
        XCTAssertEqual(lens?.showsAll, true)
    }

    func testCurrentLensAllShowsEveryTag() {
        let a = adapter()
        seedTagMode(a, lens: TagModel(["work", "web", "media"]).allMask
                    | TagModel.defaultBit)
        let lens = a.currentLens()
        XCTAssertEqual(lens?.tags, ["work", "web", "media"])
        XCTAssertEqual(lens?.showsAll, true)
    }
}
