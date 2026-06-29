import XCTest
@testable import FacetCore

/// W2.6 (t-wrd2): the lost-and-found receptacle is an `unassigned = true`
/// MARKER on an ordinary section, NOT a `type` value. The config `SectionType`
/// enum is purified to {workspace, lens}; `type = "unassigned"` is RETIRED
/// (unknown type → dropped LOUD). The receptacle's projected representation
/// keeps its own `ProjectedSectionType.unassigned` case (config vs rendered
/// types are separate concerns). Flat and tab configs are symmetric — both
/// declare a receptacle with the marker; a tab child inherits the parent type
/// AND carries the marker.
final class UnassignedMarkerTests: XCTestCase {

    // MARK: - SectionType purity

    func testSectionTypeHasNoUnassignedCase() {
        // The config enum is {workspace, lens} only — the receptacle moved to a
        // marker. (CaseIterable makes this a discriminating compile+runtime pin.)
        XCTAssertEqual(SectionType.allCases, [.workspace, .lens])
    }

    // MARK: - flat decoder: `unassigned = true` marker

    func testFlatUnassignedMarkerDecodes() {
        // A flat section with `unassigned = true` decodes to a receptacle: the
        // marker is set, match/apply ignored. Type is optional here (defaults
        // workspace) — the marker overrides the projection semantics.
        let (s, _) = DesktopSection.parse(fromTOMLRow: [
            "unassigned": .bool(true), "label": .string("Misc"),
        ])
        XCTAssertNotNil(s)
        XCTAssertTrue(s?.unassigned == true)
        XCTAssertEqual(s?.label, "Misc")
    }

    func testFlatUnassignedMarkerIgnoresMatchAndApply() {
        let (s, note) = DesktopSection.parse(fromTOMLRow: [
            "unassigned": .bool(true),
            "match": .string("app=X"),
            "apply": .table(["tags": .array([.string("a")])]),
        ])
        XCTAssertTrue(s?.unassigned == true)
        XCTAssertEqual(s?.match, "")
        XCTAssertEqual(s?.apply, [])
        XCTAssertNotNil(note)   // loud caveat about the ignored match/apply
    }

    func testTypeUnassignedSpellingRetired() {
        // `type = "unassigned"` is RETIRED — it is now an unknown type and the
        // row drops LOUD (never a silent receptacle).
        let (s, note) = DesktopSection.parse(fromTOMLRow: [
            "type": .string("unassigned"),
        ])
        XCTAssertNil(s)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("unknown") == true)
    }

    // MARK: - non-receptacle sections keep the marker false

    func testWorkspaceSectionMarkerFalse() {
        let (s, _) = DesktopSection.parse(fromTOMLRow: ["type": .string("workspace")])
        XCTAssertEqual(s?.type, .workspace)
        XCTAssertFalse(s?.unassigned == true)
    }

    // MARK: - tab child: inherits parent type AND carries the marker

    func testTabUnassignedChildInheritsTypeWithMarker() {
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
        XCTAssertEqual(secs.count, 2)
        XCTAssertEqual(secs.first?.type, .lens)
        XCTAssertFalse(secs.first?.unassigned == true)
        // the marker child inherits the parent (lens) type AND is a receptacle
        XCTAssertEqual(secs.last?.type, .lens)
        XCTAssertTrue(secs.last?.unassigned == true)
    }

    // MARK: - FilterProjection: marker emits the receptacle

    func testProjectionMarkerEmitsUnassignedReceptacle() {
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
        XCTAssertNotNil(receptacle)
        // the orphan matches no lens → it is the leftover the receptacle rescues
        XCTAssertEqual(receptacle?.windows.map(\.id), [WindowID(serverID: 9)])
    }
}
