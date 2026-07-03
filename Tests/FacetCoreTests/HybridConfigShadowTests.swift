import Foundation
import Testing
@testable import FacetCore

/// N1 (board review follow-up): a HYBRID config — both `[[desktop.N.section]]`
/// and `[[desktop.N.tab]]` at the SAME ordinal — must not let the flat list
/// leak to flat-list resolvers (notably the native adapter's `lensSection`),
/// which would silently mis-resolve a board-minted `section:<declOrder>:<label>`
/// id to a different flat lens (the EX-0.5 double-SSOT hole). The boards-win
/// rule is made TOTAL: tab configs SHADOW the flat sections at the same ordinal
/// in `effectiveMacDesktopSectionConfigs`, so every flat reader (including the
/// adapter) sees nothing there → it loud-rejects instead of mis-resolving.
/// Pure; CI-only.
struct HybridConfigShadowTests {

    private func ws(_ label: String) -> DesktopSection {
        DesktopSection(type: .workspace, label: label)
    }
    private func lens(_ label: String, _ match: String) -> DesktopSection {
        DesktopSection(type: .lens, label: label, match: match)
    }

    /// An ordinal with boards drops its flat sections from the effective view;
    /// an ordinal without boards keeps them.
    @Test func tabConfigShadowsFlatSectionsAtSameOrdinal() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [lens("Flat", "app=X")], 2: [ws("Keep")]]
        c.macDesktopTabConfigs = [1: [DesktopTab(type: .workspace,
                                                 sections: [ws("Board")])]]
        #expect(c.effectiveMacDesktopSectionConfigs[1] == nil,
                "boards shadow flat sections at the same ordinal (N1)")
        #expect(c.effectiveMacDesktopSectionConfigs[2]?.map(\.label) == ["Keep"],
                "an ordinal without boards keeps its flat sections")
    }

    /// No boards anywhere → the flat dict is returned verbatim (byte-identical
    /// to the pre-N1 accessor).
    @Test func noTabsLeavesFlatSectionsUntouched() {
        var c = FacetConfig()
        c.macDesktopSectionConfigs = [1: [ws("A")], 2: [ws("B")]]
        #expect(c.effectiveMacDesktopSectionConfigs[1]?.map(\.label) == ["A"])
        #expect(c.effectiveMacDesktopSectionConfigs[2]?.map(\.label) == ["B"])
    }

    // MARK: - T2 (t-8p46): the hybrid is detected through the real load() path

    private func loadConfig(_ toml: String) -> FacetConfig {
        let path = NSTemporaryDirectory()
            + "facet-test-\(UUID().uuidString)/config.toml"
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try? toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        return FacetConfig.load(path: path)
    }

    /// The tests above construct a `FacetConfig` directly, which skips `load()`'s
    /// hybrid-warn branch (`FacetConfig+Decode.swift`). This drives a hybrid
    /// config through the REAL `load()` — the path that emits the loud warn — and
    /// asserts the load-level RESULT the warn announces: the boards decode AND the
    /// same-ordinal flat block is shadowed out of the effective view (so it can
    /// never render or mis-resolve). The warn itself goes to /tmp/facet.log via
    /// `Log.line`, so it is observation-only and not directly asserted here.
    @Test func hybridConfigDetectedAtLoad() {
        let c = loadConfig("""
        [[desktop.1.section]]
        type = "lens"
        label = "FlatGhost"
        match = 'tag~=ghost'
        [[desktop.1.tab]]
        type = "workspace"
        label = "Board"
        [[desktop.1.tab.section]]
        label = "Main"
        """)
        #expect(c.macDesktopTabConfigs[1] != nil,
                "boards are decoded from the hybrid config")
        #expect(c.effectiveMacDesktopSectionConfigs[1] == nil,
                "the flat block at the same ordinal is shadowed (boards win, N1)")
    }
}
