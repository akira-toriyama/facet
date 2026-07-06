# facet-1: SwiftUI tree RENDER phase — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the facet view `tree` (sections + window rows + badges,
keyboard-nav, #66 focus) with sill's SwiftUI `ThemedListView` hosted inside
the existing AppKit `KeyablePanel`/`PanelHost` — DnD and search stay on the
old path (later phases).

**Architecture:** Content-only migration. A pure `buildTreeRows` maps
`[ProjectedSection]` → `[TreeRowSpec]` (Sendable, unit-tested). An
`@Observable TreeViewModel` holds the rows + selection/highlight/collapsed
state + palette. A SwiftUI `TreeContentView` turns specs into
`[ListItem<TreeItemID>]` and drives `ThemedListView`. `PanelHost` hosts it
via `NSHostingView`; `Controller.apply` feeds the view-model; the global
keyDown monitor + #66 activation dance stay host-side unchanged.

**Tech Stack:** Swift 6, macOS 26+, SwiftUI + AppKit (`NSHostingView`), sill
`ThemeKitUI` (`ThemedListView` / `ListItem` / `ThemedListStyle`), sill
`PaletteKit` (`ResolvedPalette`), XCTest (via Xcode/CI).

## Global Constraints

- **Design source**: `docs/superpowers/specs/2026-07-06-facet-swiftui-tree-seam-design.md`. This plan implements its **facet-1** row only.
- **3-layer rule**: this is View-layer only. Do NOT touch `FacetAdapterNative` / `FacetAccessibility` / `WindowBackend` / `FacetCore` value types (except the additive `TreeItemID`/`TreeRowSpec` which live in `FacetViewTree`, not FacetCore).
- **Keep the `pal` var name** at any remaining AppKit call sites (CLAUDE.md hard rule).
- **`swift build` must pass** at the end of every task. XCTest needs Xcode: run tests with `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test` if CLT is the active toolchain (bare `swift test` if Xcode is active).
- **Row identity is the composite `(group, WindowID)`**, never `WindowID` alone (multi-match duplication).
- **sill dep**: this phase needs sill product `ThemeKitUI`. During dev use a `../sill` path-dep; before the PR, swap to a URL + SemVer floor and re-pin `Package.resolved` (no path-dep on main).
- **Custom/upstream glyphs (`spiral`, `bsp`, `master-*`) are vendored by sill-B**, which lands before this phase. Task 9 assumes those slugs resolve from sill's bundle.
- **Commits**: gitmoji + Conventional Commits (`<:gitmoji:> <type>(<scope>): <subject>`). Local hook at `scripts/hooks/commit-msg`. Commit locally freely; do NOT push without トミー's OK.
- **Branch**: `feat/swiftui-tree-render` (off `main`).

---

## File Structure

- **Create** `Sources/FacetViewTree/TreeItemID.swift` — composite row identity (pure, Sendable).
- **Create** `Sources/FacetViewTree/TreeRowSpec.swift` — pure row/badge spec types + `buildTreeRows` (pure, Sendable, unit-tested).
- **Create** `Sources/FacetViewTree/TreeViewModel.swift` — `@Observable @MainActor` view-model (rows + selection/highlight/collapsed/query/loading + palette box).
- **Create** `Sources/FacetViewTree/TreeContentView.swift` — SwiftUI view: `TreeRowSpec` → `ListItem` mapping + `ThemedListView` wiring.
- **Create** `Tests/FacetViewTreeTests/BuildTreeRowsTests.swift` — pure-logic tests.
- **Modify** `Package.swift:114-122` — add `ThemeKitUI` product to `FacetViewTree` deps.
- **Modify** `Sources/FacetView/IconResolver.swift` — add `phosphorSlug(forSF:)` name-map + a SwiftUI glyph helper.
- **Modify** `Sources/FacetApp/Controller.swift:1367-1377` — feed the view-model instead of `sidebarView.update(...)`.
- **Modify** `Sources/FacetApp/PanelHost.swift` — host `TreeContentView` via `NSHostingView`; retire the outer `NSScrollView`/`FlippedClipView`/`ThemedScroller`; sizing.
- **Modify** `Sources/FacetApp/Controller+ActiveMode.swift` — repoint `handleKbKey` targets to the view-model (keyboard routing).

---

## Task 1: Package wiring + ThemedListView smoke

**Files:**
- Modify: `Package.swift:114-122`
- Create: `Sources/FacetViewTree/TreeContentView.swift`

**Interfaces:**
- Produces: module `ThemeKitUI` importable in `FacetViewTree`; a placeholder `TreeContentView` proving the SwiftUI list compiles + links in facet.

- [ ] **Step 1: Add the sill path-dep for co-dev.** In `Package.swift` `dependencies`, temporarily point the `sill` package at the local checkout (record the original line to restore before PR):

```swift
// TEMP (facet-1 co-dev; restore to the URL + bumped floor before PR):
.package(name: "sill", path: "../sill"),
```

- [ ] **Step 2: Add `ThemeKitUI` to `FacetViewTree` deps.** Edit `Package.swift:120`:

```swift
.target(name: "FacetViewTree", dependencies: [
    "FacetView", "FacetCore",
    .product(name: "ThemeKitUI", package: "sill"),
]),
```

- [ ] **Step 3: Write a smoke view.** Create `Sources/FacetViewTree/TreeContentView.swift`:

```swift
import SwiftUI
import ThemeKitUI
import PaletteKit

/// facet-1 render surface. Placeholder body until the view-model lands (Task 7).
@MainActor
struct TreeContentView: View {
    let palette: ResolvedPalette
    var body: some View {
        ThemedListView<String>(
            items: [
                ListItem(id: "h", primary: "workspace · 1", kind: .sectionHeader()),
                ListItem(id: "w", primary: "Safari", secondary: "GitHub"),
            ],
            palette: palette,
            style: ThemedListStyle(selectionMode: .single, highlightStyle: .outline)
        )
    }
}
```

- [ ] **Step 4: Build.** Run: `swift build`
  Expected: compiles clean (ThemeKitUI + transitive ThemeKit/ListCore link).

- [ ] **Step 5: Commit.**

```bash
git add Package.swift Package.resolved Sources/FacetViewTree/TreeContentView.swift
git commit -m ":building_construction: feat(tree): link ThemeKitUI + ThemedListView smoke (facet-1)"
```

---

## Task 2: Composite row identity

**Files:**
- Create: `Sources/FacetViewTree/TreeItemID.swift`
- Test: `Tests/FacetViewTreeTests/BuildTreeRowsTests.swift`

**Interfaces:**
- Produces: `enum TreeItemID: Hashable, Sendable { case header(String); case window(group: Int, WindowID) }` — the `ID` type parameter for `ThemedListView<TreeItemID>`.

- [ ] **Step 1: Write the failing test.** Create `Tests/FacetViewTreeTests/BuildTreeRowsTests.swift`:

```swift
import XCTest
import FacetCore
@testable import FacetViewTree

final class BuildTreeRowsTests: XCTestCase {
    func testCompositeIDDistinguishesSameWindowInTwoGroups() {
        let wid = WindowID(serverID: 42)
        let a = TreeItemID.window(group: 0, wid)
        let b = TreeItemID.window(group: 1, wid)
        XCTAssertNotEqual(a, b)                       // same window, two sections
        XCTAssertEqual(a, .window(group: 0, wid))     // stable
        XCTAssertNotEqual(TreeItemID.header("ws:0"), .header("ws:1"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails.** Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test --filter BuildTreeRowsTests`
  Expected: FAIL — `TreeItemID` not found.

- [ ] **Step 3: Implement.** Create `Sources/FacetViewTree/TreeItemID.swift`:

```swift
import FacetCore

/// Stable identity for one tree row. A window appears in EVERY section it
/// matches (multi-match), so the render-group ordinal is part of the key —
/// `WindowID` alone would collide across sections. Header rows key on the
/// stable `ProjectedSection.id`.
public enum TreeItemID: Hashable, Sendable {
    case header(String)                 // ProjectedSection.id
    case window(group: Int, WindowID)   // group = render-group ordinal
}
```

- [ ] **Step 4: Run test to verify it passes.** Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test --filter BuildTreeRowsTests`
  Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/FacetViewTree/TreeItemID.swift Tests/FacetViewTreeTests/BuildTreeRowsTests.swift
git commit -m ":sparkles: feat(tree): composite (group,WindowID) row identity (facet-1)"
```

---

## Task 3: Row specs + `buildTreeRows` (headers + window rows)

**Files:**
- Create: `Sources/FacetViewTree/TreeRowSpec.swift`
- Test: `Tests/FacetViewTreeTests/BuildTreeRowsTests.swift`

**Interfaces:**
- Consumes: `TreeItemID` (Task 2), `ProjectedSection`/`ProjectedSectionType`/`Window` (FacetCore).
- Produces:
  - `struct TreeRowSpec: Sendable, Equatable { let id: TreeItemID; let kind: Kind; let primary: String; let secondary: String?; let badges: [TreeBadge] }`
  - `enum TreeRowSpec.Kind { case header(sectionType: ProjectedSectionType, subtitle: String?); case window(pid: Int) }`
  - `func buildTreeRows(sections: [ProjectedSection], query: String) -> [TreeRowSpec]`
  - (badges filled in Task 4; here `badges = []`, `subtitle = nil`.)

- [ ] **Step 1: Write failing tests.** Append to `BuildTreeRowsTests.swift`:

```swift
extension BuildTreeRowsTests {
    private func win(_ id: Int, _ app: String, _ title: String) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: app, bundleId: nil,
               title: title, isFocused: false, isFloating: false, frame: nil,
               isOnscreen: true, isMaster: false, mark: nil, isSticky: false,
               scratchpad: nil, tags: [])
    }
    private func sec(_ id: String, _ label: String, _ type: ProjectedSectionType,
                     _ wins: [Window], src: Int?) -> ProjectedSection {
        ProjectedSection(id: id, label: label, windows: wins,
                         sourceWorkspaceIndex: src, sectionType: type)
    }

    func testHeaderThenWindowRows() {
        let rows = buildTreeRows(
            sections: [sec("ws:0", "1", .workspace, [win(1, "Safari", "GitHub")], src: 0)],
            query: "")
        XCTAssertEqual(rows.count, 2)
        guard case .header(.workspace, nil) = rows[0].kind else { return XCTFail() }
        XCTAssertEqual(rows[0].id, .header("ws:0"))
        XCTAssertEqual(rows[0].primary, "workspace · 1")
        guard case .window(pid: 1) = rows[1].kind else { return XCTFail() }
        XCTAssertEqual(rows[1].id, .window(group: 0, WindowID(serverID: 1)))
        XCTAssertEqual(rows[1].primary, "Safari")
        XCTAssertEqual(rows[1].secondary, "GitHub")
    }

    func testGroupOrdinalIncrementsPerSection() {
        let w = win(1, "Safari", "GitHub")
        let rows = buildTreeRows(sections: [
            sec("ws:0", "1", .workspace, [w], src: 0),
            sec("section:0:dev", "dev", .lens, [w], src: nil),   // same window, lens
        ], query: "")
        XCTAssertEqual(rows[1].id, .window(group: 0, WindowID(serverID: 1)))
        XCTAssertEqual(rows[3].id, .window(group: 1, WindowID(serverID: 1)))
    }

    func testFuzzyFilterDropsNonMatchesAndEmptySections() {
        let rows = buildTreeRows(sections: [
            sec("ws:0", "1", .workspace,
                [win(1, "Safari", "GitHub"), win(2, "Terminal", "zsh")], src: 0),
            sec("ws:1", "2", .workspace, [win(3, "Notes", "todo")], src: 1),
        ], query: "saf")
        // WS1 keeps only Safari; WS2 has no match → whole section dropped.
        XCTAssertEqual(rows.map(\.primary), ["workspace · 1", "Safari"])
    }

    func testHeaderLabelsPerKind() {
        let rows = buildTreeRows(sections: [
            sec("section:0:dev", "dev", .lens, [], src: nil),
            sec("unassigned:0", "spare", .unassigned, [win(9, "X", "")], src: nil),
        ], query: "")
        XCTAssertEqual(rows[0].primary, "lens · dev")
        XCTAssertEqual(rows[1].primary, "unassigned · spare")
    }
}
```

- [ ] **Step 2: Run to verify fail.** Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test --filter BuildTreeRowsTests`
  Expected: FAIL — `buildTreeRows`/`TreeRowSpec` not found.

- [ ] **Step 3: Implement.** Create `Sources/FacetViewTree/TreeRowSpec.swift`:

```swift
import FacetCore

/// A pure, Sendable render spec for one tree row (badges resolved to NSImage
/// only at the SwiftUI seam — see `TreeContentView`). The single builder that
/// replaces the two `SidebarView.update()` height/Cell ladders.
public struct TreeRowSpec: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case header(sectionType: ProjectedSectionType, subtitle: String?)
        case window(pid: Int)
    }
    public let id: TreeItemID
    public let kind: Kind
    public let primary: String
    public let secondary: String?
    public let badges: [TreeBadge]
}

/// Kind of the fuzzy filter, kept pure (app name + title only — WS/section
/// names are NOT searched, matching the AppKit tree).
private func matches(_ query: String, _ w: Window) -> Bool {
    query.isEmpty || fuzzyMatch(query, w.appName + " " + w.title)
}

private func headerPrimary(_ s: ProjectedSection) -> String {
    let kind: String
    switch s.sectionType {
    case .workspace: kind = "workspace"
    case .lens: kind = "lens"
    case .unassigned: kind = "unassigned"
    }
    return "\(kind) · \(s.label)"
}

/// Flatten `[ProjectedSection]` → ordered `[TreeRowSpec]`. `group` is the
/// render-group ordinal (0-based, per emitted section) so the same window in
/// multiple sections gets distinct ids. A section whose windows all fail the
/// filter is dropped whole (its header does not render).
public func buildTreeRows(sections: [ProjectedSection], query: String) -> [TreeRowSpec] {
    var rows: [TreeRowSpec] = []
    var group = 0
    for s in sections {
        let wins = s.windows.filter { matches(query, $0) }
        if !query.isEmpty && wins.isEmpty { continue }   // #202 zero-match drop
        rows.append(TreeRowSpec(
            id: .header(s.id),
            kind: .header(sectionType: s.sectionType, subtitle: nil),
            primary: headerPrimary(s), secondary: nil, badges: []))
        for w in wins {
            rows.append(TreeRowSpec(
                id: .window(group: group, w.id),
                kind: .window(pid: w.pid),
                primary: w.appName,
                secondary: w.title.isEmpty ? nil : w.title,
                badges: []))
        }
        group += 1
    }
    return rows
}
```

Also define the (empty-for-now) badge type in the same file so Task 4 only extends it:

```swift
/// A pure badge spec — the SwiftUI seam maps `kind` to a Phosphor slug + role.
public struct TreeBadge: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case master, float, sticky, hidden, mark, scratchpad, tag, overflow
    }
    public let kind: Kind
    public let text: String
    public init(_ kind: Kind, _ text: String = "") { self.kind = kind; self.text = text }
}
```

- [ ] **Step 4: Run to verify pass.** Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test --filter BuildTreeRowsTests`
  Expected: PASS (all cases).

- [ ] **Step 5: Commit.**

```bash
git add Sources/FacetViewTree/TreeRowSpec.swift Tests/FacetViewTreeTests/BuildTreeRowsTests.swift
git commit -m ":sparkles: feat(tree): pure buildTreeRows for headers + window rows (facet-1)"
```

---

## Task 4: Badges + tag overflow

**Files:**
- Modify: `Sources/FacetViewTree/TreeRowSpec.swift` (extend `buildTreeRows` window loop)
- Test: `Tests/FacetViewTreeTests/BuildTreeRowsTests.swift`

**Interfaces:**
- Consumes: `TreeBadge` (Task 3), `Window` fields `isMaster`/`isFloating`/`isSticky`/`isOnscreen`/`mark`/`scratchpad`/`tags`.
- Produces: window-row `badges: [TreeBadge]` populated in status-then-tags order with a `+N` overflow cap.

- [ ] **Step 1: Write failing tests.** Append to `BuildTreeRowsTests.swift`:

```swift
extension BuildTreeRowsTests {
    private func rich(_ id: Int, master: Bool = false, floating: Bool = false,
                      sticky: Bool = false, onscreen: Bool = true, mark: String? = nil,
                      scratch: String? = nil, tags: [String] = []) -> Window {
        Window(id: WindowID(serverID: id), pid: id, appName: "A", bundleId: nil,
               title: "", isFocused: false, isFloating: floating, frame: nil,
               isOnscreen: onscreen, isMaster: master, mark: mark, isSticky: sticky,
               scratchpad: scratch, tags: tags)
    }
    private func badges(_ w: Window) -> [TreeBadge] {
        buildTreeRows(sections: [sec("ws:0", "1", .workspace, [w], src: 0)], query: "")[1].badges
    }

    func testStatusBadges() {
        XCTAssertEqual(badges(rich(1, master: true)), [TreeBadge(.master)])
        XCTAssertEqual(badges(rich(1, floating: true)), [TreeBadge(.float)])
        XCTAssertEqual(badges(rich(1, sticky: true)), [TreeBadge(.sticky)])
        XCTAssertEqual(badges(rich(1, onscreen: false)), [TreeBadge(.hidden)])
        XCTAssertEqual(badges(rich(1, mark: "a")), [TreeBadge(.mark, "a")])
        XCTAssertEqual(badges(rich(1, scratch: "shelf")), [TreeBadge(.scratchpad, "shelf")])
    }

    func testTagBadgesCapWithOverflow() {
        let b = badges(rich(1, tags: ["red", "green", "blue", "amber"]))
        // status badges (none) + 3 tag chips + a "+1" overflow badge
        XCTAssertEqual(b, [
            TreeBadge(.tag, "red"), TreeBadge(.tag, "green"), TreeBadge(.tag, "blue"),
            TreeBadge(.overflow, "+1"),
        ])
    }

    func testStatusBeforeTags() {
        let b = badges(rich(1, master: true, tags: ["x"]))
        XCTAssertEqual(b, [TreeBadge(.master), TreeBadge(.tag, "x")])
    }
}
```

- [ ] **Step 2: Run to verify fail.** Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test --filter BuildTreeRowsTests`
  Expected: FAIL — badges empty.

- [ ] **Step 3: Implement.** In `TreeRowSpec.swift` add a helper and use it in the window loop:

```swift
/// Max tag chips shown before collapsing the remainder into a `+N` badge.
private let tagVisibleCap = 3

private func windowBadges(_ w: Window) -> [TreeBadge] {
    var out: [TreeBadge] = []
    if w.isMaster { out.append(TreeBadge(.master)) }
    if w.isFloating { out.append(TreeBadge(.float)) }
    if w.isSticky { out.append(TreeBadge(.sticky)) }
    if !w.isOnscreen { out.append(TreeBadge(.hidden)) }
    if let m = w.mark { out.append(TreeBadge(.mark, m)) }
    if let s = w.scratchpad { out.append(TreeBadge(.scratchpad, s)) }
    let shown = w.tags.prefix(tagVisibleCap)
    out.append(contentsOf: shown.map { TreeBadge(.tag, $0) })
    if w.tags.count > tagVisibleCap {
        out.append(TreeBadge(.overflow, "+\(w.tags.count - tagVisibleCap)"))
    }
    return out
}
```

Replace `badges: []` in the window-row append with `badges: windowBadges(w)`.

- [ ] **Step 4: Run to verify pass.** Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test --filter BuildTreeRowsTests`
  Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/FacetViewTree/TreeRowSpec.swift Tests/FacetViewTreeTests/BuildTreeRowsTests.swift
git commit -m ":sparkles: feat(tree): window-row badges + tag +N overflow (facet-1)"
```

---

## Task 5: Icon name-map (SF → Phosphor) + SwiftUI glyph helper

**Files:**
- Modify: `Sources/FacetView/IconResolver.swift`

**Interfaces:**
- Produces:
  - `static func phosphorSlug(forSF sf: String) -> String?` — maps facet's `SF:`-stripped name to a Phosphor slug (nil = unknown).
  - `static func phosphorImage(_ slug: String, pt: CGFloat) -> NSImage?` — template NSImage from sill's `phosphorImage` (re-exported so the tree view resolves badge/header glyphs).
- Consumes: sill `ThemeKit.phosphorImage` (needs `ThemeKit` visible to `FacetView` — add `.product(name: "ThemeKit", package: "sill")` to the `FacetView` target if not transitively available).

> Depends on sill-B having vendored `spiral` (upstream) + the 6 custom tiling SVGs (`bsp`, `master-left/right/top/bottom/center`) + GAP-A slugs (`archive`, `push-pin`, `push-pin-slash`, `tray`, `arrows-left-right`).

- [ ] **Step 1: Add the ThemeKit dep** (for `phosphorImage`). `Package.swift` `FacetView` deps: add `.product(name: "ThemeKit", package: "sill")`. Run `swift build` to confirm it resolves.

- [ ] **Step 2: Add the name-map.** In `IconResolver.swift`, add:

```swift
import ThemeKit

extension IconResolver {
    /// facet `SF:<name>` → sill Phosphor slug. Tree-scope glyphs only
    /// (row badges, section-header, layout-mode badge); context-menu specs
    /// keep resolving via `resolve(_:)` (F2). Unknown → nil (logged by caller).
    public static func phosphorSlug(forSF sf: String) -> String? {
        switch sf {
        case "magnifyingglass": return "magnifying-glass"
        case "pencil": return "pencil"
        case "tag": return "tag"
        case "line.3.horizontal.decrease.circle": return "funnel"
        case "crown": return "crown"
        case "macwindow": return "app-window"
        case "eye.slash": return "eye-slash"
        case "chevron.down": return "caret-down"
        case "chevron.up": return "caret-up"
        case "plus": return "plus"
        case "minus": return "minus"
        case "xmark": return "x"
        case "square.stack": return "stack"
        case "square.grid.2x2": return "squares-four"
        case "archivebox": return "archive"            // GAP-A (sill-B)
        case "pin": return "push-pin"                  // GAP-A
        case "pin.slash": return "push-pin-slash"      // GAP-A
        case "tray": return "tray"                     // GAP-A
        case "arrow.left.and.right": return "arrows-left-right"  // GAP-A
        case "square.split.bottomrightquarter": return "spiral"  // upstream
        case "square.split.2x2": return "bsp"                     // custom (sill-B)
        case "rectangle.lefthalf.filled": return "master-left"   // custom
        case "rectangle.righthalf.filled": return "master-right" // custom
        case "rectangle.tophalf.filled": return "master-top"     // custom
        case "rectangle.bottomhalf.filled": return "master-bottom" // custom
        case "rectangle.center.inset.filled": return "master-center" // custom
        default: return nil
        }
    }

    /// A template (currentColor) Phosphor NSImage from sill, for SwiftUI
    /// `Image(nsImage:).renderingMode(.template).foregroundStyle(...)`.
    public static func phosphorImage(_ slug: String, pt: CGFloat) -> NSImage? {
        ThemeKit.phosphorImage(slug, pt: pt)
    }
}
```

- [ ] **Step 3: Build.** Run: `swift build`
  Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git add Package.swift Package.resolved Sources/FacetView/IconResolver.swift
git commit -m ":sparkles: feat(icons): SF→Phosphor slug map + SwiftUI glyph helper (facet-1)"
```

---

## Task 6: View-model + palette box

**Files:**
- Create: `Sources/FacetViewTree/TreeViewModel.swift`

**Interfaces:**
- Consumes: `TreeRowSpec` (Task 3), `ResolvedPalette` (PaletteKit).
- Produces:
  - `@Observable @MainActor final class TreeViewModel` with: `var rows: [TreeRowSpec]`, `var selection: Set<TreeItemID>`, `var highlight: TreeItemID?`, `var collapsed: Set<TreeItemID>`, `var query: String`, `var isLoading: Bool`, `var palette: ResolvedPalette`.
  - `func apply(sections: [ProjectedSection])` — rebuilds `rows` via `buildTreeRows(sections:query:)` (called from `Controller.apply`).

- [ ] **Step 1: Implement.** Create `Sources/FacetViewTree/TreeViewModel.swift`:

```swift
import Observation
import PaletteKit
import FacetCore

/// The single @Observable box the SwiftUI tree binds to. Injected via
/// `.environment`; `Controller` is the sole writer. Palette lives here so a
/// re-theme updates ONE value (never rebuilds `rows`) — the 30 Hz animator
/// tick must set only `palette` (spec §4.6/§7.7).
@Observable
@MainActor
final class TreeViewModel {
    var rows: [TreeRowSpec] = []
    var selection: Set<TreeItemID> = []
    var highlight: TreeItemID?
    var collapsed: Set<TreeItemID> = []
    var query: String = ""
    var isLoading: Bool = false
    var palette: ResolvedPalette

    init(palette: ResolvedPalette) { self.palette = palette }

    /// Rebuild rows from a fresh projection. Selection/highlight/collapsed are
    /// id-keyed and survive across rebuilds (dropped only if their id vanishes).
    func apply(sections: [ProjectedSection]) {
        rows = buildTreeRows(sections: sections, query: query)
        let ids = Set(rows.map(\.id))
        selection.formIntersection(ids)
        collapsed.formIntersection(ids)
        if let h = highlight, !ids.contains(h) { highlight = nil }
    }
}
```

- [ ] **Step 2: Build.** Run: `swift build`
  Expected: clean.

- [ ] **Step 3: Commit.**

```bash
git add Sources/FacetViewTree/TreeViewModel.swift
git commit -m ":sparkles: feat(tree): @Observable TreeViewModel + palette box (facet-1)"
```

---

## Task 7: `TreeContentView` — spec→ListItem mapping + list wiring

**Files:**
- Modify: `Sources/FacetViewTree/TreeContentView.swift` (replace the Task 1 placeholder body)

**Interfaces:**
- Consumes: `TreeViewModel` (Task 6), `TreeRowSpec`/`TreeBadge` (Tasks 3-4), `IconResolver.phosphorImage`/`AppIcons.icon(forPID:)`, sill `ListItem`/`ThemedListView`/`Badge`/`BadgeRole`/`ListTint`.
- Produces: a `TreeContentView` bound to a `TreeViewModel` that renders the real rows, wiring `selection`/`highlight`/`collapsed` bindings + `onActivate`/`onToggleSection`/`onHover` callbacks (the callbacks are stubbed to closures the host injects — real behaviour in Tasks 8/10/12).

- [ ] **Step 1: Implement the mapping + view.** Replace `TreeContentView.swift`:

```swift
import SwiftUI
import ThemeKitUI
import PaletteKit
import FacetView   // AppIcons, IconResolver
import FacetCore

@MainActor
struct TreeContentView: View {
    @Bindable var model: TreeViewModel
    var onActivate: (TreeItemID) -> Void = { _ in }
    var onToggleSection: (TreeItemID) -> Void = { _ in }
    var onHover: (TreeItemID?) -> Void = { _ in }

    var body: some View {
        ThemedListView<TreeItemID>(
            items: model.rows.map(listItem(_:)),
            selection: $model.selection,
            collapsed: $model.collapsed,
            highlight: $model.highlight,
            style: ThemedListStyle(
                selectionMode: .single,
                highlightStyle: .outline,
                showsDividers: true,
                zebra: true,
                horizontalContentScroll: true,
                hosted: false),
            palette: model.palette,
            onActivate: onActivate,
            onToggleSection: onToggleSection,
            onHover: onHover)
    }

    private func listItem(_ r: TreeRowSpec) -> ListItem<TreeItemID> {
        switch r.kind {
        case let .header(type, subtitle):
            return ListItem(
                id: r.id,
                image: headerGlyph(type),
                primary: r.primary,
                kind: .sectionHeader(subtitle: subtitle))
        case let .window(pid):
            return ListItem(
                id: r.id,
                image: AppIcons.icon(forPID: pid),
                primary: r.primary,
                secondary: r.secondary,
                badges: r.badges.map(badge(_:)))
        }
    }

    private func headerGlyph(_ type: ProjectedSectionType) -> NSImage? {
        let slug: String?
        switch type {
        case .lens: slug = "funnel"
        case .unassigned: slug = "archive"
        case .workspace: slug = nil
        }
        return slug.flatMap { IconResolver.phosphorImage($0, pt: 13) }
    }

    private func badge(_ b: TreeBadge) -> Badge {
        let slug: String?
        let role: BadgeRole
        switch b.kind {
        case .master: slug = "crown"; role = .primary
        case .float: slug = "app-window"; role = .secondary
        case .sticky: slug = "push-pin"; role = .secondary
        case .hidden: slug = "eye-slash"; role = .error
        case .mark: slug = nil; role = .primary
        case .scratchpad: slug = "tray"; role = .secondary
        case .tag: slug = "tag"; role = .neutral
        case .overflow: slug = nil; role = .neutral
        }
        return Badge(b.text, symbol: slug.flatMap { IconResolver.phosphorImage($0, pt: 11) }, role: role)
    }
}
```

- [ ] **Step 2: Build.** Run: `swift build`
  Expected: clean (mapping typechecks against sill's `ListItem`/`Badge` inits).

- [ ] **Step 3: Commit.**

```bash
git add Sources/FacetViewTree/TreeContentView.swift
git commit -m ":sparkles: feat(tree): TreeRowSpec→ListItem mapping + ThemedListView wiring (facet-1)"
```

---

## Task 8: Host the SwiftUI tree in PanelHost + wire `Controller.apply`

**Files:**
- Modify: `Sources/FacetApp/PanelHost.swift` (retire outer `NSScrollView`/`FlippedClipView`/`ThemedScroller`; add `NSHostingView(rootView: TreeContentView)`; sizing)
- Modify: `Sources/FacetApp/Controller.swift:1367-1377` (feed `TreeViewModel`)

**Interfaces:**
- Consumes: `TreeViewModel` (Task 6), `TreeContentView` (Task 7).
- Produces: the panel renders the SwiftUI tree; `Controller.apply` calls `treeVM.apply(sections:)` + `treeVM.palette = pal` instead of `sidebarView.update(...)`.

> This is the render-swap checkpoint — verified by build + host GUI (render parity), not a unit test. `SidebarView` remains in the tree for DnD/search until facet-2/3; the SwiftUI view takes over rendering + selection display.

- [ ] **Step 1: Add a `TreeViewModel` + hosting view to `PanelHost`.** In `PanelHost`, construct `let treeVM = TreeViewModel(palette: pal)` and an `NSHostingView(rootView: TreeContentView(model: treeVM, onActivate: ..., onToggleSection: ..., onHover: ...))`. Replace the `NSScrollView`(FlippedClipView + `SidebarView` documentView + `ThemedScroller`) construction with the hosting view laid out in the content region below the search band. Wire `onActivate`/`onToggleSection`/`onHover` to the existing Controller/handleClick paths (real #66 behaviour lands in Task 12; here route `onActivate` → `controller?.exitActive(restore:false)` then the existing focus path).

- [ ] **Step 2: Sizing.** Replace the `layout(contentHeight:searching:)` height math: compute the hosting view's `fittingSize.height`, set panel height = `min(fittingHeight, screenMaxHeight)` (reuse the existing screen-relative clamp). When clamped, `ThemedListView` scrolls internally. Remove `FlippedClipView`/`ThemedScroller` usages.

- [ ] **Step 3: Feed the view-model from `Controller.apply`.** Replace `Controller.swift:1367-1377`:

```swift
panelHost.treeVM.palette = pal
if config.isSectionModelActive(ordinal: macDesktopOrdinal) {
    panelHost.treeVM.apply(sections: lastSections)
} else {
    panelHost.treeVM.apply(sections: FilterProjection.project(
        workspaces: displayWss, sections: []).sections)   // degrade → 1:1 sections
}
```

(Keep the `contentH`-based `panelHost.layout(...)` call, now driven by the hosting view's fitting size from Step 2.)

- [ ] **Step 4: Build.** Run: `swift build`
  Expected: clean.

- [ ] **Step 5: GUI render-parity check (host consent required).** Run `./run.sh`, summon the tree (`--view tree`), and confirm against success-criterion 1: same sections, window rows, badges, and active-section highlight as before. (Return the working window to a visible position afterward.)

- [ ] **Step 6: Commit.**

```bash
git add Sources/FacetApp/PanelHost.swift Sources/FacetApp/Controller.swift
git commit -m ":recycle: feat(tree): host SwiftUI tree in PanelHost + wire apply (facet-1)"
```

---

## Task 9: Layout-mode subtitle + header glyphs (section headers)

**Files:**
- Modify: `Sources/FacetViewTree/TreeRowSpec.swift` (`buildTreeRows` gains a layout-mode lookup)
- Modify: `Sources/FacetViewTree/TreeContentView.swift` (header subtitle already wired; verify glyph resolution)
- Test: `Tests/FacetViewTreeTests/BuildTreeRowsTests.swift`

**Interfaces:**
- Consumes: the layout-engine name per workspace section.
- Produces: `buildTreeRows(sections:query:layoutMode:)` where `layoutMode: (ProjectedSection) -> String?` supplies the abbrev for `.workspace` headers (`nil` for lens/unassigned).

- [ ] **Step 1: Write failing test.** Append:

```swift
extension BuildTreeRowsTests {
    func testWorkspaceHeaderCarriesLayoutSubtitle() {
        let rows = buildTreeRows(
            sections: [sec("ws:0", "1", .workspace, [], src: 0)],
            query: "",
            layoutMode: { _ in "bsp" })
        guard case .header(.workspace, "bsp") = rows[0].kind else { return XCTFail() }
    }
    func testLensHeaderHasNoSubtitle() {
        let rows = buildTreeRows(
            sections: [sec("section:0:dev", "dev", .lens, [win(1,"A","")], src: nil)],
            query: "", layoutMode: { _ in "bsp" })
        guard case .header(.lens, nil) = rows[0].kind else { return XCTFail() }
    }
}
```

- [ ] **Step 2: Run to verify fail.** Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test --filter BuildTreeRowsTests`
  Expected: FAIL — `buildTreeRows(sections:query:layoutMode:)` not found.

- [ ] **Step 3: Implement.** Add a defaulted `layoutMode` param:

```swift
public func buildTreeRows(
    sections: [ProjectedSection], query: String,
    layoutMode: (ProjectedSection) -> String? = { _ in nil }
) -> [TreeRowSpec] {
    // ... in the header append, compute:
    //   let sub = s.sectionType == .workspace ? layoutMode(s) : nil
    //   kind: .header(sectionType: s.sectionType, subtitle: sub)
}
```

(Update the header append accordingly; the existing 2-arg call sites keep working via the default.)

- [ ] **Step 4: Wire the real lookup in `Controller.apply`.** Pass a closure resolving each workspace section's layout engine (from the live `Workspace`/backend layout name) into `treeVM.apply`. Extend `TreeViewModel.apply(sections:)` to accept + store the `layoutMode` closure, or precompute subtitles Controller-side.

- [ ] **Step 5: Run tests + build.** Run: `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer swift test --filter BuildTreeRowsTests && swift build`
  Expected: PASS + clean.

- [ ] **Step 6: GUI check (host consent).** Confirm workspace headers show the layout-mode abbrev; the `bsp`/`master-*`/`spiral` custom glyphs render (sill-B vendored). Commit:

```bash
git add Sources/FacetViewTree Sources/FacetApp Tests/FacetViewTreeTests
git commit -m ":sparkles: feat(tree): layout-mode header subtitle + glyphs (facet-1)"
```

---

## Task 10: Keyboard routing (repoint `handleKbKey` to the view-model)

**Files:**
- Modify: `Sources/FacetApp/Controller+ActiveMode.swift` (`handleKbKey` targets)
- Modify: `Sources/FacetViewTree/TreeViewModel.swift` (add cursor helpers driving `highlight` via `KbNav`)

**Interfaces:**
- Consumes: `KbNav.swift` pure fns (reused verbatim), `TreeViewModel.rows`/`highlight`/`selection`.
- Produces: `handleKbKey` moves the view-model `highlight`/`selection` + calls `TreeController` commits; every key from spec §4.8 preserved (`↑↓`/`Ctrl-N-P`/`j/k`→move; `←→`/`h/l`/`Tab`→jump; `Enter`→activate; `Space`→lift; `Esc`; `s`→search; `t`→tag-manage; `m`→menu).

> The global `NSEvent` keyDown monitor + `installKbMonitor` stay unchanged (spec §4.8) — only `handleKbKey`'s targets move from `SidebarView` methods to the view-model + `KbNav`. Verified by build + host GUI.

- [ ] **Step 1: Add cursor helpers to `TreeViewModel`.** Add `func moveCursor(_ delta: Int)` and `func jumpSection(_ delta: Int)` that compute the next `highlight` from `rows` via the existing `KbNav` pure fns (adapt `KbNav`'s `[TreeRow]` index math to the view-model's `rows`/`TreeItemID` — the fns are framework-agnostic; feed them the selectable ids). Add `func activateCursor() -> TreeItemID?` returning the current `highlight` for the host to commit.

- [ ] **Step 2: Repoint `handleKbKey`.** In `Controller+ActiveMode.swift`, change the tree-nav branch: `kbMove` → `panelHost.treeVM.moveCursor(±1)`; `kbJumpWS` → `jumpSection(±1)`; Enter → `exitActive(restore:false)` then commit the `activateCursor()` id via the existing `activateSection`/`focusWindow` routing; keep `s`/`t`/`m`/search-sub-mode exactly as today (they target host chrome, unchanged).

- [ ] **Step 3: Build.** Run: `swift build`
  Expected: clean.

- [ ] **Step 4: GUI check (host consent).** Verify success-criterion 3: `↑↓/hjkl/Enter/Space/Esc/Tab/Ctrl-N-P/s/t` all navigate/act; cursor (outline) is distinct from selection (fill).

- [ ] **Step 5: Commit.**

```bash
git add Sources/FacetApp/Controller+ActiveMode.swift Sources/FacetViewTree/TreeViewModel.swift
git commit -m ":sparkles: feat(tree): route keyboard-nav to the SwiftUI view-model (facet-1)"
```

---

## Task 11: Loading-skeleton overlay + optimistic highlight

**Files:**
- Modify: `Sources/FacetApp/PanelHost.swift` (host-side skeleton overlay)
- Modify: `Sources/FacetApp/Controller.swift` (drive show/clear from the content-ready signal; move the optimistic-highlight hold into `TreeViewModel`)

**Interfaces:**
- Consumes: `Controller.showLoading`, the content-ready transition.
- Produces: skeleton is a host-side AppKit overlay shown over the hosting view, cleared on the next content-ready signal; the 0.85 s optimistic-highlight hold moves into `TreeViewModel` `@State`.

- [ ] **Step 1: Skeleton overlay.** Add a simple AppKit placeholder view (grey bars) that `PanelHost` layers over the hosting view; `Controller.showLoading` shows it, and the `apply()` content-ready path (replacing the old `signature != skeletonBaseSig` clear) hides it. Preserve the `loadingWantsActive` deferred-activate at the skeleton→content transition (`Controller.swift:1389+`).

- [ ] **Step 2: Optimistic highlight.** Move the 0.85 s `optUntil` hold (that wins the backend focus-assert race) into `TreeViewModel` as a timestamped `@State` applied to `selection`; `apply()` respects the hold when re-projecting.

- [ ] **Step 3: Build + GUI check (host consent).** Run `./run.sh` + `facet --view tree --loading 700`; confirm the skeleton paints then clears on real content, and a header click holds its highlight through the round-trip. Commit:

```bash
git add Sources/FacetApp Sources/FacetViewTree
git commit -m ":sparkles: feat(tree): host-side skeleton overlay + optimistic highlight (facet-1)"
```

---

## Task 12: #66 activation on `onActivate` + final render-parity gate

**Files:**
- Modify: `Sources/FacetViewTree/TreeContentView.swift` / `Sources/FacetApp/PanelHost.swift` (finalize `onActivate` wiring)

**Interfaces:**
- Consumes: `TreeController.exitActive(restore:)`, `focusWindow`/`activateSection`.
- Produces: activating a row (mouse or Enter) runs the **#66 dance** — `exitActive(restore:false)` BEFORE focusing — so same-app focus succeeds.

- [ ] **Step 1: Finalize `onActivate`.** Ensure `TreeContentView`'s `onActivate(id)` (from list click + Enter) resolves the `TreeItemID` to its section/window and calls `controller.exitActive(restore:false)` **first**, then `activateSection`/`focusWindow`/`toggleActiveLens`/`focusFirstWindow` per the row kind (mirror `SidebarView.handleClick`'s routing).

- [ ] **Step 2: Build.** Run: `swift build`
  Expected: clean.

- [ ] **Step 3: #66 GUI gate (host consent — the load-bearing check).** Two same-app windows in different workspaces: activate the non-focused one from the tree; confirm it actually focuses (success-criterion 3, #66). Then run the full render-parity + kb-nav pass (criteria 1, 3). **Not verifiable in a Tart VM** (window-mgmt cand=0) — host only.

- [ ] **Step 4: Restore the sill dep for the PR.** Revert the `../sill` path-dep to the URL + a bumped SemVer floor covering sill-A/B; re-pin `Package.resolved`; `swift build`.

- [ ] **Step 5: Commit.**

```bash
git add Sources Package.swift Package.resolved
git commit -m ":sparkles: feat(tree): #66 activation on SwiftUI onActivate + sill floor bump (facet-1)"
```

---

## Self-Review notes (coverage against the spec)

- **§4.1 host/sizing/scroll** → Task 8 (retire outer scroll, fitting-size + clamp).
- **§4.2 view-model/data-in** → Tasks 6, 8 (single `@Observable`, `Controller.apply` feeds it, composite id, title pre-merge in `buildTreeRows`).
- **§4.3 render/anatomy/collapse/badge-overflow** → Tasks 3, 4, 7 (`+N` cap in Task 4; collapse via `collapsed` binding in Tasks 6-7).
- **§4.4 search** → OUT (facet-3).
- **§4.5 icons** → Task 5 (name-map; adapter SF specs excluded, per spec).
- **§4.6 palette** → Tasks 6, 7 (palette in view-model, injected; not rebuilt on tick).
- **§4.7 DnD** → OUT (facet-2).
- **§4.8 keyboard** → Task 10 (monitor stays host-side; all keys preserved).
- **§7 risks** → #66 (Task 12), skeleton/optimistic (Task 11), partial-migration (Task 8 keeps grid/rail feed), 30 Hz (Task 6 palette-only).
- **§9 success criteria** → 1 (Task 8/12 GUI), 3 (Tasks 10/12 GUI), 5 (Task 6/7). Criteria 2 (DnD) + 4 (search) are facet-2/3.

**Deferred to later phases (not gaps):** DnD (`onDrop`), search (`ThemedTextFieldView`), performSwap, dropTargetValidator, WindowShell.
