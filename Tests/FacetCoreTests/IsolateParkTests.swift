import Testing
@testable import FacetCore

/// `IsolatePark.parkSet` — the pure "which windows anchor-park when a lens is
/// isolate-active?" helper (t-c6fm). When a `type="lens"` board runs in
/// `isolate` mode and one of its lenses is active, the active workspace's
/// windows that do NOT satisfy the lens `match` slide to the corner — so the
/// screen shows only the active lens's world (dwm-style focus). Reviving the
/// park behaviour t-0021 removed, but DERIVED from `match` every reconcile (no
/// stored park-set to desync) and WITHOUT the union-tile that actually broke.
///
/// The rule: park = out-of-lens AND not sticky (`everywhere`). Sticky windows
/// are "always visible" by definition, so they are exempt; a float has NO
/// special handling — it parks by the same out-of-lens rule as a tiled window,
/// so it follows its app's lens membership. Pure; CI-only.
struct IsolateParkTests {

    private func win(_ id: Int, app: String = "App", tags: [String] = []) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, title: "",
               isFocused: false, isFloating: false, frame: nil, tags: tags)
    }

    private func filter(_ src: String) -> FacetFilter {
        switch FacetFilter.parse(src) {
        case .success(let f): return f
        case .failure(let e): Issue.record("parse failed: \(e.message)"); return .all
        }
    }

    private func ids(_ w: [WindowID]) -> [Int] { w.map(\.serverID) }

    // MARK: - core rule: park = out-of-lens AND not sticky

    @Test func outOfLensWindowIsParked() {
        let lens = filter("app~=Slack or app=Mail")   // "Chat"
        let park = IsolatePark.parkSet(
            windows: [win(1, app: "Code"), win(2, app: "Google Chrome")],
            inWorkspaceNamed: "Main", lens: lens, sticky: [])
        #expect(ids(park) == [1, 2])   // neither matches Chat → both park
    }

    @Test func inLensWindowNotParked() {
        let lens = filter("app~=Slack or app=Mail")
        let park = IsolatePark.parkSet(
            windows: [win(1, app: "Slack"), win(2, app: "Code")],
            inWorkspaceNamed: "Main", lens: lens, sticky: [])
        #expect(ids(park) == [2])   // Slack matches → stays; Code parks
    }

    @Test func stickyOutOfLensIsExempt() {
        let lens = filter("app~=Slack")
        // window 2 is out-of-lens BUT sticky → must stay visible.
        let park = IsolatePark.parkSet(
            windows: [win(1, app: "Code"), win(2, app: "Music")],
            inWorkspaceNamed: "Main", lens: lens,
            sticky: [WindowID(serverID: 2)])
        #expect(ids(park) == [1])   // only the non-sticky out-of-lens parks
    }

    /// A float has no special exemption — it parks by the same out-of-lens rule
    /// (a floating out-of-lens window still slides to the corner).
    @Test func floatOutOfLensIsParked() {
        let lens = filter("app~=Slack")
        var floater = win(1, app: "Calculator")
        floater = Window(id: floater.id, pid: floater.pid, appName: floater.appName,
                         title: floater.title, isFocused: false, isFloating: true,
                         frame: nil, tags: [])
        let park = IsolatePark.parkSet(windows: [floater],
                                       inWorkspaceNamed: "Main", lens: lens, sticky: [])
        #expect(ids(park) == [1])
    }

    @Test func tagLensParksUntaggedKeepsTagged() {
        let lens = filter("tag~=chat")
        let park = IsolatePark.parkSet(
            windows: [win(1, app: "Slack", tags: ["chat"]), win(2, app: "Code", tags: [])],
            inWorkspaceNamed: "Main", lens: lens, sticky: [])
        #expect(ids(park) == [2])   // untagged parks; tagged stays
    }

    @Test func allMatchNothingParks() {
        let lens = filter("app~=Slack or app=Code")
        let park = IsolatePark.parkSet(
            windows: [win(1, app: "Slack"), win(2, app: "Code")],
            inWorkspaceNamed: "Main", lens: lens, sticky: [])
        #expect(park.isEmpty)
    }
}
