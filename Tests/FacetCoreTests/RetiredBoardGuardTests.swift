import Testing
@testable import FacetCore

/// The `[[desktop.N.tab]]` migration guard — the ONE piece of board code that
/// survived the abolition (t-0sbm), and the only one that must.
///
/// Why it is load-bearing, and why it is worth a test: boards no longer decode.
/// So a config that types its desktops ONLY with `[[desktop.N.tab]]` declares
/// nothing facet recognises — `macDesktopSectionConfigs` and
/// `macDesktopMetaConfigs` both come back empty — and `isMacDesktopManaged`
/// then falls through to `true` for EVERY ordinal. The user's opt-in
/// ("manage just desktop 1") silently becomes "manage all of them". The guard
/// is what makes that flip loud. `boardConfigFlipsToManageEveryDesktop` below
/// pins the flip itself, so the reason the guard exists cannot rot away
/// unnoticed.
struct RetiredBoardGuardTests {

    // MARK: - detection

    @Test func findsRetiredBoardHeaders() {
        let found = FacetConfig.retiredBoardHeaders(inTOML: """
        [[desktop.2.tab]]
        label = "Web"

        [[desktop.1.tab]]
        label = "Code"
        """)
        #expect(found == ["desktop.1.tab", "desktop.2.tab"])   // sorted
    }

    /// The match is on the literal array-of-tables header, so it is
    /// nesting-agnostic: a board's nested section blocks surface too, and a
    /// legacy `[[desktop.N.tab.section]]` can never be mistaken for a real
    /// `[[desktop.N.section]]` (its ordinal parses as `Int("1.tab")` → nil).
    @Test func findsBoardsRegardlessOfNesting() {
        let found = FacetConfig.retiredBoardHeaders(inTOML: """
        [[desktop.1.tab]]
        label = "Web"

        [[desktop.1.tab.section]]
        label = "Docs"
        """)
        #expect(found == ["desktop.1.tab"])
    }

    @Test func migratedConfigIsQuiet() {
        let found = FacetConfig.retiredBoardHeaders(inTOML: """
        [desktop.1]
        type = "workspace"

        [[desktop.1.section]]
        label = "Code"

        [desktop.2]
        type = "isolate"
        match = 'app=Safari'
        """)
        #expect(found.isEmpty)
    }

    /// `tab` must be the last path component — a section merely LABELLED "tab"
    /// is not a board.
    @Test func doesNotFalsePositiveOnSomethingNamedTab() {
        let found = FacetConfig.retiredBoardHeaders(inTOML: """
        [[desktop.1.section]]
        label = "tab"
        """)
        #expect(found.isEmpty)
    }

    // MARK: - the flip the guard exists to announce

    @Test func boardConfigFlipsToManageEveryDesktop() {
        let c = FacetConfig.load(source: """
        [[desktop.1.tab]]
        label = "Web"
        """)
        // Nothing decoded — the board block is inert.
        #expect(c.effectiveMacDesktopSectionConfigs.isEmpty)
        #expect(c.macDesktopMetaConfigs.isEmpty)
        // …so the opt-in is GONE: every mac desktop is managed, including ones
        // the user never mentioned. That is the flip the warn announces.
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(c.isMacDesktopManaged(ordinal: 7))
    }

    /// The contrast: migrate the same intent and the opt-in holds — desktop 1
    /// is managed, desktop 7 is hands-off.
    @Test func migratedConfigKeepsTheOptIn() {
        let c = FacetConfig.load(source: """
        [[desktop.1.section]]
        label = "Code"
        """)
        #expect(c.isMacDesktopManaged(ordinal: 1))
        #expect(!c.isMacDesktopManaged(ordinal: 7))
    }
}
