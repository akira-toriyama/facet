import Testing
@testable import FacetCore

/// W2.6 (t-wrd2): the lost-and-found receptacle is an `unassigned = true`
/// MARKER on an ordinary section, NOT a `type` value. The config `SectionType`
/// enum is purified to {workspace, lens}; `type = "unassigned"` is RETIRED
/// (unknown type → dropped LOUD). The receptacle's projected representation
/// keeps its own `ProjectedSectionType.unassigned` case (config vs rendered
/// types are separate concerns). Flat and tab configs are symmetric — both
/// declare a receptacle with the marker; a tab child inherits the parent type
/// AND carries the marker.
struct UnassignedMarkerTests {

    // MARK: - SectionType purity

    @Test func sectionTypeHasNoUnassignedCase() {
        // The config enum is {workspace, lens} only — the receptacle moved to a
        // marker. (CaseIterable makes this a discriminating compile+runtime pin.)
        #expect(SectionType.allCases == [.workspace, .lens])
    }

    // MARK: - flat decoder: `unassigned = true` marker

    @Test func flatUnassignedMarkerDecodes() {
        // A flat section with `unassigned = true` decodes to a receptacle: the
        // marker is set, match/apply ignored. Type is optional here (defaults
        // workspace) — the marker overrides the projection semantics.
        let (s, _) = DesktopSection.parse(fromTOMLRow: [
            "unassigned": .bool(true), "label": .string("Misc"),
        ])
        #expect(s != nil)
        #expect(s?.unassigned == true)
        #expect(s?.label == "Misc")
    }

    @Test func flatUnassignedMarkerIgnoresMatchAndApply() {
        let (s, note) = DesktopSection.parse(fromTOMLRow: [
            "unassigned": .bool(true),
            "match": .string("app=X"),
            "apply": .table(["tags": .array([.string("a")])]),
        ])
        #expect(s?.unassigned == true)
        #expect(s?.match == "")
        #expect(s?.apply == [])
        #expect(note != nil)   // loud caveat about the ignored match/apply
    }

    @Test func typeUnassignedSpellingRetired() {
        // `type = "unassigned"` is RETIRED — it is now an unknown type and the
        // row drops LOUD (never a silent receptacle).
        let (s, note) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("unassigned"),
        ])
        #expect(s == nil)
        #expect(note != nil)
        #expect(note?.contains("unknown") == true)
    }

    @Test func unassignedMarkerWinsOverInvalidType() {
        // The receptacle MARKER is checked BEFORE `type`, so a bogus type on a
        // marker row is projection-irrelevant: `recType` falls through to the
        // `.workspace` default and the row still decodes as a receptacle (no
        // drop note). Contrast `unknownTypeIsDropped` — the SAME bogus type
        // WITHOUT the marker drops LOUD. Regression pin: a refactor that
        // validated `type` before the marker would silently DROP a typo-typed
        // receptacle, losing the lost-and-found section.
        let (s, note) = DesktopSection.parse(fromTOMLRow: [
            "unassigned": .bool(true), "type": .string("bogus"),
        ])
        #expect(s != nil)
        #expect(s?.type == .workspace)   // bogus type → moot `.workspace` default
        #expect(s?.unassigned == true)
        #expect(s?.label == "")
        #expect(note == nil)             // marker accepts; no drop / caveat
    }

    // MARK: - non-receptacle sections keep the marker false

    @Test func workspaceSectionMarkerFalse() {
        let (s, _) = DesktopSection.parse(fromTOMLRow: ["type": .string("workspace")])
        #expect(s?.type == .workspace)
        #expect(s?.unassigned != true)
    }

    // MARK: - tab child: inherits parent type AND carries the marker

    @Test func tabUnassignedChildInheritsTypeWithMarker() {
        let t = FacetConfig.decodeDesktopTabs(fromTOML: """
        [[desktop.1.tab]]
        type = "lens"
        label = "Views"
        [[desktop.1.tab.section]]
        label = "Web"
        match = 'tag~=web'
        [[desktop.1.tab.section]]
        label = "Misc"
        unassigned = true
        """)
        let secs = t[1]?[0].sections ?? []
        #expect(secs.count == 2)
        #expect(secs.first?.type == .lens)
        #expect(secs.first?.unassigned != true)
        // the marker child inherits the parent (lens) type AND is a receptacle
        #expect(secs.last?.type == .lens)
        #expect(secs.last?.unassigned == true)
    }

    // MARK: - FilterProjection: marker emits the receptacle

    @Test func projectionMarkerEmitsUnassignedReceptacle() {
        let ws = Workspace(index: 0, name: "Main", isActive: true,
                           layoutMode: "float", windows: [])
        let orphan = Window(id: WindowID(serverID: 9), pid: 1, appName: "Z",
                            title: "z", isFocused: false, isFloating: false,
                            frame: nil, isOnscreen: true)
        let sections = [
            DesktopSection(type: .lens, label: "Web", match: "app=Nope"),
            DesktopSection(type: .lens, label: "Misc", unassigned: true),
        ]
        let r = FilterProjection.project(workspaces: [ws], sections: sections,
                                         orphans: [orphan])
        let receptacle = r.sections.first { $0.sectionType == .unassigned }
        #expect(receptacle != nil)
        // the orphan matches no lens → it is the leftover the receptacle rescues
        #expect(receptacle?.windows.map(\.id) == [WindowID(serverID: 9)])
    }
}
