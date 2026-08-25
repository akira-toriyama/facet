import XCTest
import FacetCore
import ListCore
@testable import FacetViewTree

/// The tree's drop semantics — one rule set shared by the commit
/// (`Controller.treeDrop`) and sill's `dropTargetValidator`.
final class TreeDropResolutionTests: XCTestCase {

    fileprivate func win(_ id: Int, _ app: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil)
    }
    fileprivate func sec(_ id: String, _ type: ProjectedSectionType,
                         _ wins: [Window], src: Int?) -> ProjectedSection {
        ProjectedSection(id: id, label: id, windows: wins,
                         sourceWorkspaceIndex: src, sectionType: type)
    }
    fileprivate func drag(_ src: TreeItemID) -> ListCore.DragContext<TreeItemID> {
        ListCore.DragContext(sourceID: src, memberIDs: [src])
    }
    fileprivate func onto(_ id: TreeItemID) -> ListCore.DropTarget<TreeItemID> {
        ListCore.DropTarget(placement: .onto(id: id))
    }
    fileprivate func between(_ id: TreeItemID?) -> ListCore.DropTarget<TreeItemID> {
        ListCore.DropTarget(placement: .between(beforeID: id))
    }

    /// ws:0 [w1], ws:1 [w2] — the ordinary two-workspace tree.
    fileprivate func twoSections() -> [ProjectedSection] {
        [sec("ws:0", .workspace, [win(1, "Safari")], src: 0),
         sec("ws:1", .workspace, [win(2, "Terminal")], src: 1)]
    }

    // MARK: chunk (section reorder)

    func testChunkToAHeaderBoundaryResolves() {
        let r = resolveTreeDrop(drag(.header("ws:1")), between(.header("ws:0")),
                                sections: twoSections(), sectionMode: true,
                                isolateDesktop: false)
        XCTAssertEqual(r, .chunk(boundary: 0))
    }

    func testChunkToTheEndGapResolvesToTheCount() {
        let r = resolveTreeDrop(drag(.header("ws:0")), between(nil),
                                sections: twoSections(), sectionMode: true,
                                isolateDesktop: false)
        XCTAssertEqual(r, .chunk(boundary: 2))
    }

    /// The affordance sill drew on a WINDOW gap did nothing on release —
    /// rejecting it here removes the promise as well as the no-op.
    func testChunkOverAWindowGapIsRejected() {
        let r = resolveTreeDrop(drag(.header("ws:0")),
                                between(.window(group: 1, WindowID(serverID: 2))),
                                sections: twoSections(), sectionMode: true,
                                isolateDesktop: false)
        XCTAssertNil(r)
    }

    /// An isolate desktop's sections are matched-then-holding by construction;
    /// the AppKit tree gated mode-4 on `!isolateDesktop` and the pointer path
    /// lost it in the render swap.
    func testChunkOnAnIsolateDesktopIsRejected() {
        let secs = [sec("iso:matched", .matched, [win(1, "Safari")], src: nil),
                    sec("iso:holding", .holding, [win(2, "Terminal")], src: nil)]
        let r = resolveTreeDrop(drag(.header("iso:matched")), between(nil),
                                sections: secs, sectionMode: true, isolateDesktop: true)
        XCTAssertNil(r)
    }

    func testChunkInTheDegradePathIsRejected() {
        let r = resolveTreeDrop(drag(.header("ws:0")), between(nil),
                                sections: twoSections(), sectionMode: false,
                                isolateDesktop: false)
        XCTAssertNil(r)
    }

    // MARK: window moves

    func testWindowOntoARowInAnotherSectionResolves() {
        let r = resolveTreeDrop(drag(.window(group: 0, WindowID(serverID: 1))),
                                onto(.window(group: 1, WindowID(serverID: 2))),
                                sections: twoSections(), sectionMode: true,
                                isolateDesktop: false)
        XCTAssertEqual(r, .window(id: WindowID(serverID: 1), from: 0, to: 1))
    }

    func testWindowOntoItsOwnSectionIsRejected() {
        let r = resolveTreeDrop(drag(.window(group: 0, WindowID(serverID: 1))),
                                onto(.header("ws:0")),
                                sections: twoSections(), sectionMode: true,
                                isolateDesktop: false)
        XCTAssertNil(r)
    }

    /// t-63h2: a holding row is display-only — inert as a SOURCE …
    func testWindowDraggedOutOfAHoldingSectionIsRejected() {
        let secs = [sec("iso:matched", .matched, [win(1, "Safari")], src: nil),
                    sec("iso:holding", .holding, [win(2, "Terminal")], src: nil)]
        let r = resolveTreeDrop(drag(.window(group: 1, WindowID(serverID: 2))),
                                onto(.window(group: 0, WindowID(serverID: 1))),
                                sections: secs, sectionMode: true, isolateDesktop: true)
        XCTAssertNil(r)
    }

    /// … and as a DESTINATION (its membership is the match's complement, not a place).
    func testWindowDroppedIntoAHoldingSectionIsRejected() {
        let secs = [sec("iso:matched", .matched, [win(1, "Safari")], src: nil),
                    sec("iso:holding", .holding, [win(2, "Terminal")], src: nil)]
        let r = resolveTreeDrop(drag(.window(group: 0, WindowID(serverID: 1))),
                                onto(.window(group: 1, WindowID(serverID: 2))),
                                sections: secs, sectionMode: true, isolateDesktop: true)
        XCTAssertNil(r)
    }

    /// The degrade path files by workspace index — a section without one has
    /// nowhere to put the window, so it must not offer itself as a target.
    func testDegradeDestinationWithoutAWorkspaceIndexIsRejected() {
        let secs = [sec("ws:0", .workspace, [win(1, "Safari")], src: 0),
                    sec("orphan", .workspace, [win(2, "Terminal")], src: nil)]
        let r = resolveTreeDrop(drag(.window(group: 0, WindowID(serverID: 1))),
                                onto(.window(group: 1, WindowID(serverID: 2))),
                                sections: secs, sectionMode: false,
                                isolateDesktop: false)
        XCTAssertNil(r)
    }

    // MARK: escape bands (t-65nf T2 — sill's ±32 pt tolerance vs wsBands)

    /// The gap BELOW the last row is the flick-away band: the old tree's
    /// wsBands ended at the list edges and a release past them ABORTED, but
    /// `destinationOrdinal` maps the end gap to the LAST section — a flick
    /// below the tree became a real move (measured: docY 145…175 committed
    /// into the last section).
    func testWindowToTheEndGapAborts() {
        let r = resolveTreeDrop(drag(.window(group: 0, WindowID(serverID: 1))),
                                between(nil),
                                sections: twoSections(), sectionMode: true,
                                isolateDesktop: false)
        XCTAssertNil(r)
    }

    /// Same band above the FIRST header (measured: docY −1…−31 committed into
    /// the first section). An interior header's gap still targets the
    /// previous section — see the test below.
    func testWindowAboveTheFirstHeaderAborts() {
        let r = resolveTreeDrop(drag(.window(group: 1, WindowID(serverID: 2))),
                                between(.header("ws:0")),
                                sections: twoSections(), sectionMode: true,
                                isolateDesktop: false)
        XCTAssertNil(r)
    }

    /// The degrade path shares the `.window` branch — same escape bands.
    func testDegradeWindowEscapeBandsAbort() {
        XCTAssertNil(resolveTreeDrop(drag(.window(group: 0, WindowID(serverID: 1))),
                                     between(nil),
                                     sections: twoSections(), sectionMode: false,
                                     isolateDesktop: false))
        XCTAssertNil(resolveTreeDrop(drag(.window(group: 1, WindowID(serverID: 2))),
                                     between(.header("ws:0")),
                                     sections: twoSections(), sectionMode: false,
                                     isolateDesktop: false))
    }

    /// The gap ABOVE a header closes the PREVIOUS section (sill's geometry has
    /// no sections; this is where the tree's meaning is applied).
    func testBetweenAboveAHeaderTargetsThePreviousSection() {
        let secs = twoSections() + [sec("ws:2", .workspace, [win(3, "Notes")], src: 2)]
        let r = resolveTreeDrop(drag(.window(group: 2, WindowID(serverID: 3))),
                                between(.header("ws:1")),
                                sections: secs, sectionMode: true,
                                isolateDesktop: false)
        XCTAssertEqual(r, .window(id: WindowID(serverID: 3), from: 2, to: 0))
    }
}
