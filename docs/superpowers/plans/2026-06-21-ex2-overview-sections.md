# EX-2 — Grid/Rail Section Cells + 3-View Unified Highlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. This is the **detailed re-plan of the EX-2 row** in [2026-06-21-exclusive-model-revised-plan.md](2026-06-21-exclusive-model-revised-plan.md), refreshed against the EX-1 foundation (main `b75232e`, PR #315). The parent plan's EX-0→EX-4 phase split is unchanged; this doc expands EX-2.

**Goal:** Make the grid (and, in a follow-up sub-phase, the rail) render the **same ordered `[ProjectedSection]` list as the tree** — including `type="lens"` sections as cells — so all three views show **exactly one lit highlight**; route every cell/window click through the existing `activateSection` throughline (activate-or-switch + focus), never `switchWorkspace` directly.

**Architecture:** EX-1 already gave the tree single-highlight via one `headerActive` XOR gate (`activeLens != nil ? lens-lit : workspace-lit`) and a backend `activateSection(_:autoFocus:)` throughline that the Controller and tree clicks funnel through. EX-2 carries the *same two things* to the overview surfaces: (1) feed grid/rail the projected `[ProjectedSection]` + the active-lens label (currently they get only raw `[Workspace]` + `activeIndex`); (2) bake the `headerActive` XOR into `OverviewCell.isActive` at cell-build time so the existing accent-draw paints exactly one lit cell with no draw-code change; (3) route the grid's `onPick` closure — which **already captures the Controller** — through `controller.activateSection` with a new `.lens` pick case. The shared plumbing (an `OverviewCell` section discriminator, an `OverviewView` protocol extension, hoisting `FilterProjection.project` above the grid/rail feed) is built once in EX-2a and reused by the rail in EX-2b.

**Tech Stack:** Swift 6, macOS 13+, SwiftPM. 3-layer spine: `FacetCore` (pure) / `FacetAdapterNative` (AX + catalog, `cliQueue`-confined) / `FacetView*` + `FacetApp` (GUI/Controller). Tests are XCTest, **CI-only** (local gate is `swift build`). The view layer (`FacetViewGrid`/`FacetViewRail`/`FacetView`) and the Controller have **no XCTest harness** — they are build-gated + host-verified.

## Global Constraints

- **Layer spine is non-negotiable.** `FacetCore` pure (CoreGraphics OK, no AppKit / no AX / no backend types). `ProjectedSection`/`OverviewCell`/`ActiveSection`/`SectionType` are pure FacetCore. Views talk to `WindowBackend` + the Controller-supplied closures, never a concrete adapter. ([[facet-architecture-decisions]])
- **Catalog is the single state authority.** active-section / park sets live in `WorkspaceCatalog` (mutated only on `cliQueue`). Views read a snapshot. `OverviewCell.isActive` is a *render mirror* computed from the snapshot's `activeLens` + `Workspace.isActive`, never an independent source of truth.
- **`workspaces` stays the UNFILTERED snapshot.** `OverviewView.workspaces` is documented "ALWAYS the UNFILTERED set (even under an active lens): the landing gate / cell count / swap source it" ([OverviewView.swift:44](../../../Sources/FacetView/OverviewView.swift#L44)). EX-2 **adds** `sections` + `activeLens` **alongside** it — it does NOT replace `workspaces`. The DnD landing gates (`OverviewPendingDrop.landed(in: workspaces)`) and swap source still read `workspaces`.
- **`ActiveSection.workspace(Int)` is 1-based; cell/workspace indices are 0-based.** `OverviewCell.wsIndex == Workspace.index` (0-based wire index). Routing a workspace cell click → `activateSection(.workspace(wsIndex + 1))`. **This +1 is the same off-by-one that bit EX-1 (M1) — get it right.**
- **Tests compile in CI only.** Any test calling a `cliQueue`-guarded adapter method MUST wrap it in `cliQueue.sync { … }` (EX-0.3 lesson). FacetCore tests (the only unit-testable EX-2 piece) need no wrap. Local gate is `swift build`. ([[feedback-swift-tests-only-compile-in-ci]])
- **Loud on typo, silent on success.** Routing through `controller.activateSection` reuses the EX-1 validation (unknown lens label → operational error via status; range-checked workspace index). EX-2 adds no new error surface. ([[control-is-cli-first]])
- **No push/merge without an explicit OK from トミー.** Commit locally on `feat/ex2-overview-sections`; squash-merge only on go. View changes are host-verified by トミー (synthetic input NG — [[claude-driven-testing-protocol]], [[feedback-no-input-injection-while-active]]). ([[pr-conventions]], [[grid-view-work-style]])
- **Patch by SYMBOL, not line number.** Earlier audits found systematic line drift; all line numbers below are *as of main `b75232e`* and must be re-located by symbol before editing.

---

## EX-1 foundation recap (what EX-2 builds on)

Verified in source at main `b75232e` + via the EX-2 codemap (`wf_165f48db-2eb`):

- **`ProjectedSection`** ([OverviewModels.swift:35](../../../Sources/FacetCore/OverviewModels.swift#L35)): `id: String` (`"ws:<index>"` or `"section:<declOrder>:<label>"`), `label`, `windows: [Window]`, `sourceWorkspaceIndex: Int?` (0-based; **nil for lens**), `sectionType: SectionType` (`.workspace`/`.lens`/`.unassigned`). `Sendable`. Produced by `FilterProjection.project(workspaces:sections:)` ([FilterProjection.swift:102](../../../Sources/FacetCore/FilterProjection.swift#L102)) in config-declaration order; multi-match (a window appears in every section it matches).
- **`OverviewCell`** ([OverviewModels.swift:83](../../../Sources/FacetCore/OverviewModels.swift#L83)): the view-built mini-screen cell grid/rail render. `wsIndex: Int`, `rect`, `headerRect`, `isActive: Bool`, `label`, `mode`, `windows: [MiniWindowHit]`, `isHero`. **NOT Sendable.** Today built one-per-`Workspace`.
- **Tree single-highlight** is one gate: `headerActive(_ sec: ProjectedSection) -> Bool` ([SidebarView.swift:569](../../../Sources/FacetViewTree/SidebarView.swift#L569)):
  ```swift
  sec.sectionType == .lens
      ? (activeLens != nil && sec.label == activeLens)
      : (activeLens == nil && wsActive(sec.sourceWorkspaceIndex))
  ```
- **`activateSection` throughline:** `WindowBackend.activateSection(_ section: ActiveSection, autoFocus:)` ([Backend.swift:244](../../../Sources/FacetCore/Backend.swift#L244), default no-op :601; NativeAdapter impl [:473](../../../Sources/FacetAdapterNative/NativeAdapter.swift#L473)). Controller side: `Controller.activateSection(_:autoFocus:)` ([Controller+CLIDispatch.swift:575](../../../Sources/FacetApp/Controller+CLIDispatch.swift#L575)) routes `.lens(label)` → `setActiveLens`, `.workspace(n)` → `dispatchWorkspace`, updating the `currentActiveSection` mirror on main **before** the backend op (the EX-0.5/EX-1 same-index-clear fix). The tree's workspace-header click already calls `controller?.activateSection(.workspace(i + 1), autoFocus: true)` ([SidebarView+Drag.swift:415](../../../Sources/FacetViewTree/SidebarView+Drag.swift#L415)).
- **Controller `apply()` feed order** ([Controller.swift](../../../Sources/FacetApp/Controller.swift)): the grid/rail refresh block (`if let g = gridView { g.workspaces = wss; g.activeIndex = …; g.layoutCells() }` and the rail equivalent, ~882–903) runs **before** the tree's section projection (`FilterProjection.project(...)`, ~988–999). EX-2 hoists the projection above the grid/rail feed so all three share it.
- **Snapshot-on-show:** `showGrid`/`showRail` build the view from `lastWorkspaces` (Controller+Grid.swift / Controller+Rail.swift); `seedOverviewCommon` ([Controller+Overview.swift:26](../../../Sources/FacetApp/Controller+Overview.swift#L26)) seeds `v.workspaces`/`v.activeIndex`. The grid/rail `onPick` closures **already capture `[weak self]` = the Controller**, so they can call `self?.activateSection(...)` with no new view→controller handle.
- **Thumbnail fallback already handles parked slivers.** Grid/rail drop `isLensParked` windows *before* requesting captures (`where !win.isLensParked`, [GridView.swift:330](../../../Sources/FacetViewGrid/GridView.swift#L330) / RailView.swift:447); `drawMiniThumb` ([OverviewPaint.swift:15](../../../Sources/FacetView/OverviewPaint.swift#L15)) falls back to the app icon (grid) / subtle fill (rail) when no thumbnail is cached. A 1×41 parked sliver is therefore **never captured**.
- **Tag-mode exit-2 is NOT the section model.** `grid|rail` view ops exit-2 only under legacy `[grouping] by="tag"` ([Main.swift:662](../../../Sources/FacetApp/Main.swift#L662)). The exclusive **section/lens model** runs under default `by="workspace"` with `[[desktop.N.section]]` blocks — grid/rail already open there. EX-2 needs **no** gate change (lifting the tag-mode exit-2 is EX-4).

---

## Design decisions locked (this re-plan)

Implementation-shape calls delegated to Claude by the design canon ([[facet-tag-unification-design]]: "CLI 詳細の綴り・tree の見た目・実装フェーズの刻み方は全てクロード委任"; トミー "推奨でOK" for grid/rail single-highlight). The product design (exclusive model, single-highlight, 3-view parity) is not re-opened.

1. **Decision ⑨ (lens-cell sliver capture) is MOOT — no special handling.** Verified: parked windows are filtered by `isLensParked` *before* capture, so a sliver is never captured; the existing icon/blank fallback covers everything. The parent plan's flagged トミー question is a false alarm; record it closed.
2. **Scope split: EX-2a (shared infra + GRID) ships first; EX-2b (RAIL) is a follow-up phase.** EX-2a delivers a dogfoodable unified-highlight grid and de-risks the shared plumbing. The rail is far more complex (carousel-over-sections, hero, `selectedWS` browse, DnD landing — all keyed on workspace index); a *partial* rail (suppress-only, no lens cells) is worse UX (no lit cell under a lens), so the rail is all-or-nothing and deferred to a full EX-2b, re-planned at its start. **Declared gap after EX-2a:** the rail still lights its active-workspace cell under an active lens (same cosmetic gap EX-1 left for both surfaces; the rail is rarely opened mid-lens). Not silently dropped — see "Deferred" below.
3. **`OverviewCell` gains a section discriminator, not a rewrite.** Add `sectionType: SectionType = .workspace` + `sectionID: String = ""` (defaulted, so all existing call sites compile unchanged). `wsIndex` stays for workspace cells (DnD/landing/keyboard all key on it); a lens cell sets `wsIndex = -1` (sentinel: "no source workspace") + carries its identity in `sectionID`/`label`. Field consolidation is not in scope.
4. **Single-highlight is baked into `OverviewCell.isActive` at build time — zero draw-code change.** `isActive` is already the *sole* driver of the active accent in `draw()` and `drawHeader` (`cell.isActive ? pal.primary : …`). In `layoutCells`, compute `isActive` via the same XOR as the tree's `headerActive`: a workspace cell is active iff `activeLens == nil && ws.isActive`; a lens cell is active iff `cell.label == activeLens`. The existing accent paths then light exactly one cell.
5. **Click routing reuses the Controller's `onPick` closure.** The view fires `onPick` with enough info to distinguish kinds; the Controller closure (which holds `self`) routes to `self?.activateSection`. `GridPick` gains a `.lens(label: String)` case. No new view→controller protocol.
6. **Lens cells are not DnD targets.** A lens section has no `sourceWorkspaceIndex`, so a window cannot be moved onto it and its header cannot be swapped. Guard the drag-promotion paths on lens cells (mouse + keyboard). A window thumb *inside* a lens cell, clicked, still focuses that window (switches to its home workspace first).
7. **Degrade path is preserved byte-identically.** When the section model is inactive on this mac desktop, `sections` is empty and `layoutCells` falls back to the existing `workspaces` iteration — the default section-less config renders exactly as today.

### Deferred to EX-2b / later (declared, not dropped — 未達成を暗黙にしない)

- **Rail section rendering + single-highlight + hero** → **EX-2b** (re-planned at its start; includes the rail-hero-under-lens visual call deferred from EX-1 — likely "the active lens cell becomes the hero, rendering its union," but decided then).
- **Lens-cell window mini-layout polish.** A lens cell lays out its member windows by their real `Window.frame` scaled into the cell. When the lens is **active** they are union-tiled (looks right); when **inactive** they may overlap (members at home frames from different workspaces). Acceptable cosmetic for EX-2a (the cell is mainly a click target; activating it union-tiles + the grid auto-dismisses). Refine in EX-2b/brushup if トミー dislikes it during dogfood ([[facet-dogfood-adoption-test]]).
- **`updateConfig` auto-clear of a now-undefined active lens** — pre-existing #313 MINOR BACKLOG carried from the EX-1 plan; still EX-2/backlog.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `Sources/FacetCore/OverviewModels.swift` | `OverviewCell` gains `sectionType` + `sectionID` (defaulted). Pure. | EX-2.1 |
| `Sources/FacetView/OverviewView.swift` | protocol gains `sections: [ProjectedSection]` + `activeLens: String?`. | EX-2.2 |
| `Sources/FacetApp/Controller+Overview.swift` | `seedOverviewCommon` seeds `sections`/`activeLens`. | EX-2.2 |
| `Sources/FacetApp/Controller.swift` | hoist `FilterProjection.project` above the grid/rail feed; stash `lastSections`/`lastActiveLens`; feed grid (+rail in EX-2b). | EX-2.2 |
| `Sources/FacetViewGrid/GridView.swift` | `sections`/`activeLens` stored props; `layoutCells` builds workspace + lens cells with `isActive` XOR baked in; `mouseDown` lens-cell routing + drag guard. | EX-2.3, EX-2.5 |
| `Sources/FacetViewGrid/GridPick.swift` | `.lens(label:)` case. | EX-2.5 |
| `Sources/FacetApp/Controller+Grid.swift` | `onPick` closure routes `.workspace`/`.lens` → `self?.activateSection`; seeds `gv.sections`/`gv.activeLens` at show. | EX-2.5 |
| `config.toml`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md` | doc the 3-view section parity (grid now renders lens cells). | EX-2.6 |
| `Tests/FacetCoreTests/OverviewModelsTests.swift` (NEW or extend) | `OverviewCell` discriminator defaults + equality-by-fields. | EX-2.1 |

Execution: one branch `feat/ex2-overview-sections`. Sub-task = one commit, TDD where testable (FacetCore only), adversarial review per sub-task. **ONE host-verify after EX-2a** (トミー operates; synthetic input NG). EX-2b is a separate branch + plan.

---

## Task EX-2.1: `OverviewCell` section discriminator (pure FacetCore, additive)

**Files:**
- Modify: `Sources/FacetCore/OverviewModels.swift` (`OverviewCell` struct + init)
- Test: `Tests/FacetCoreTests/OverviewModelsTests.swift` (new)

**Interfaces:**
- Produces: `OverviewCell.sectionType: SectionType` (default `.workspace`), `OverviewCell.sectionID: String` (default `""`); a `var isLens: Bool { sectionType == .lens }` convenience.
- Consumes: `SectionType` (existing, [DesktopSection.swift:56](../../../Sources/FacetCore/DesktopSection.swift#L56)).

- [ ] **Step 1: Write the failing FacetCore test**

```swift
// Tests/FacetCoreTests/OverviewModelsTests.swift
import XCTest
import CoreGraphics
@testable import FacetCore

final class OverviewModelsTests: XCTestCase {
    private func cell(_ type: SectionType, id: String) -> OverviewCell {
        OverviewCell(wsIndex: -1, rect: .zero, headerRect: .zero,
                     isActive: false, label: "L", mode: "", windows: [],
                     sectionType: type, sectionID: id)
    }
    func testDefaultsAreWorkspaceKind() {
        // 8-arg legacy call site (no sectionType/sectionID) must still compile + default.
        let c = OverviewCell(wsIndex: 0, rect: .zero, headerRect: .zero,
                             isActive: true, label: "W", mode: "bsp", windows: [])
        XCTAssertEqual(c.sectionType, .workspace)
        XCTAssertEqual(c.sectionID, "")
        XCTAssertFalse(c.isLens)
    }
    func testLensKindFlag() {
        XCTAssertTrue(cell(.lens, id: "section:1:Web").isLens)
        XCTAssertEqual(cell(.lens, id: "section:1:Web").sectionID, "section:1:Web")
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift build` then (CI) `swift test --filter OverviewModelsTests`. Expected: compile FAIL (`extra arguments 'sectionType', 'sectionID'` / no `isLens`). Locally `swift build` fails to compile the test.

- [ ] **Step 3: Add the fields + init params + convenience**

In `OverviewCell` ([OverviewModels.swift:83](../../../Sources/FacetCore/OverviewModels.swift#L83)) add stored props after `isHero`:

```swift
    /// Which section kind this cell renders — `.workspace` (the spatial
    /// substrate) or `.lens` (a cross-workspace saved-filter section, EX-2).
    /// Defaulted so every existing 8-arg call site compiles unchanged.
    public let sectionType: SectionType
    /// The `ProjectedSection.id` this cell came from (`"ws:<i>"` /
    /// `"section:<declOrder>:<label>"`) — stable identity for routing /
    /// signatures. Empty for legacy workspace-built cells.
    public let sectionID: String

    public var isLens: Bool { sectionType == .lens }
```

Extend the init signature (append the two defaulted params after `isHero: Bool = false`):

```swift
    public init(wsIndex: Int, rect: CGRect, headerRect: CGRect,
                isActive: Bool, label: String, mode: String,
                windows: [MiniWindowHit], isHero: Bool = false,
                sectionType: SectionType = .workspace,
                sectionID: String = "") {
        // … existing assignments …
        self.sectionType = sectionType
        self.sectionID = sectionID
    }
```

- [ ] **Step 4: Run to verify it passes** — `swift build` (local gate). Expected: PASS. (CI) `swift test --filter OverviewModelsTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FacetCore/OverviewModels.swift Tests/FacetCoreTests/OverviewModelsTests.swift
git commit -m ":sparkles: feat(core): OverviewCell に section 判別子追加 (EX-2.1)"
```

---

## Task EX-2.2: feed `[ProjectedSection]` + `activeLens` to the overview surfaces (additive, no behavior change)

**Files:**
- Modify: `Sources/FacetView/OverviewView.swift` (protocol)
- Modify: `Sources/FacetApp/Controller+Overview.swift` (`seedOverviewCommon`)
- Modify: `Sources/FacetApp/Controller.swift` (hoist projection; stash; feed grid)
- Modify: `Sources/FacetViewGrid/GridView.swift` (stored props only — consumed in EX-2.3)
- Modify: `Sources/FacetViewRail/RailView.swift` (stored props only — satisfies protocol; consumed in EX-2b)

**Interfaces:**
- Produces: `OverviewView.sections: [ProjectedSection]` (default `[]`) + `OverviewView.activeLens: String?` (default `nil`); `Controller.lastSections: [ProjectedSection]` + `Controller.lastActiveLens: String?` (stored, refreshed each `apply()`); `seedOverviewCommon` seeds both.
- Consumes: `FilterProjection.project` (existing), `currentActiveSection.lensLabel` (EX-1).

> No behavior change lands in this task — grid/rail store the new inputs but still iterate `workspaces` until EX-2.3. This task is the wiring + the projection hoist, reviewable on its own (build-green, identical pixels).

- [ ] **Step 1: Extend the `OverviewView` protocol**

In [OverviewView.swift](../../../Sources/FacetView/OverviewView.swift), under "Snapshot-on-show inputs", after `activeIndex`:

```swift
    /// The projected section list (EX-2): the SAME ordered `[ProjectedSection]`
    /// the tree renders (`type=workspace` + `type=lens`). Empty ⇒ the
    /// section model is off here ⇒ fall back to the `workspaces` iteration
    /// (byte-identical degrade). `workspaces` stays the unfiltered snapshot.
    var sections: [ProjectedSection] { get set }
    /// The active lens label (EX-2), or nil when a workspace is the active
    /// section. Gates the single-highlight: when non-nil, workspace cells
    /// suppress their active accent and only the matching lens cell lights.
    var activeLens: String? { get set }
```

- [ ] **Step 2: Add stored props to GridView + RailView**

`GridView` ([GridView.swift:29-30](../../../Sources/FacetViewGrid/GridView.swift#L29)) — after `activeIndex`:
```swift
    public var sections: [ProjectedSection] = []
    public var activeLens: String?
```
`RailView` ([RailView.swift:47-48](../../../Sources/FacetViewRail/RailView.swift#L47)) — same two lines (satisfies the protocol now; rail consumes them in EX-2b).

- [ ] **Step 3: Stash the projection on the Controller + hoist it above the grid/rail feed**

In `Controller` (stored state region), add:
```swift
    /// EX-2: last projected sections + active lens, refreshed every apply(),
    /// fed to the overview surfaces (snapshot-on-show seeds from these).
    /// Empty/nil ⇒ section model off ⇒ overview degrades to `workspaces`.
    var lastSections: [ProjectedSection] = []
    var lastActiveLens: String?
```

In `apply()`, place the projection **immediately after the active-section re-read block** (`if macDesktopSwapped || wsSwitched { … }` then `hasRenderedMacDesktop = true` / `if macDesktopOrdinal != nil { lastRenderedMacDesktopOrdinal = … }` at ~866–877) — the projection's `activeLens` reads the *freshly-resolved* `currentActiveSection.lensLabel`, so it must run after that block — and **before** the grid/rail feed block (`if let g = gridView { … }` at ~882). Compute it once and stash it:

```swift
    // EX-2: project ONCE here (hoisted above the grid/rail feed) so all
    // three views share one ordered section list. Section model off ⇒ empty
    // sections ⇒ grid/rail degrade to the `workspaces` path (byte-identical).
    if config.isSectionModelActive(ordinal: macDesktopOrdinal),
       let ordinal = macDesktopOrdinal {
        let secs = config.effectiveMacDesktopSectionConfigs[ordinal] ?? []
        let projected = FilterProjection.project(workspaces: wss, sections: secs)
        logDiagnosticsOnChange(projected.diagnostics, prefix: "overview: ",
                               against: &loggedSectionDiagnostics)
        lastSections = projected.sections
    } else {
        lastSections = []
    }
    lastActiveLens = currentActiveSection.lensLabel
```

Then **remove** the `FilterProjection.project` + `logDiagnosticsOnChange` from the **tree render block** (~988–999): the hoisted block is now the **sole** `FilterProjection.project` call AND the **sole** `logDiagnosticsOnChange(against: &loggedSectionDiagnostics)` in `apply()` (the prefix moves from `"tree: "` to `"overview: "` — there is no second log). The tree's `update(...)` consumes the stashed values: `sections: lastSections, … activeLens: lastActiveLens`. **Verify by symbol: exactly ONE `FilterProjection.project` call and ONE `logDiagnosticsOnChange` against `loggedSectionDiagnostics` remain in `apply()`.**

In the grid feed block (~882), add the two new seeds:
```swift
    if let g = gridView {
        g.workspaces = wss
        g.activeIndex = wss.first(where: { $0.isActive })?.index
        g.sections = lastSections          // EX-2
        g.activeLens = lastActiveLens      // EX-2
        g.layoutCells()
    }
```
(The rail block gets the same two lines in EX-2b, not now — but it is harmless to add them now since `RailView` already stores them. Add them now to keep the feed symmetric; the rail just ignores them until EX-2b.)

- [ ] **Step 4: Seed at show time in `seedOverviewCommon`**

In [Controller+Overview.swift:26](../../../Sources/FacetApp/Controller+Overview.swift#L26), after `v.activeIndex = …`:
```swift
    v.sections = lastSections       // EX-2: section list (empty ⇒ degrade)
    v.activeLens = lastActiveLens   // EX-2: active lens for single-highlight
```

- [ ] **Step 5: Build + verify no behavior change**

Run: `swift build`. Expected: PASS. The grid/rail still iterate `workspaces` in `layoutCells` (unchanged), so pixels are identical. This task only plumbs the new inputs.

- [ ] **Step 6: Commit**

```bash
git add Sources/FacetView/OverviewView.swift Sources/FacetApp/Controller+Overview.swift \
        Sources/FacetApp/Controller.swift Sources/FacetViewGrid/GridView.swift \
        Sources/FacetViewRail/RailView.swift
git commit -m ":sparkles: feat(view): overview に section/activeLens 供給 + 射影 hoist (EX-2.2)"
```

---

## Task EX-2.3: GridView renders sections (workspace + lens cells) with single-highlight baked in

**Files:**
- Modify: `Sources/FacetViewGrid/GridView.swift` (`layoutCells`)

**Interfaces:**
- Consumes: `self.sections` / `self.activeLens` (EX-2.2), `OverviewCell.sectionType`/`sectionID` (EX-2.1).
- Produces: `cells: [OverviewCell]` built from `sections` (when non-empty), with `isActive` already gated by the single-highlight XOR; lens cells carry `wsIndex = -1`, `sectionType = .lens`, `sectionID = section.id`.

> This is the deliverable: the grid shows the same ordered section list as the tree, lens cells included, with exactly one lit cell. The accent draw paths are UNCHANGED (they read `cell.isActive`); the gating happens here at build time.

- [ ] **Step 1: Refactor the cell-build loop to iterate sections, with a degrade fallback**

In `layoutCells` ([GridView.swift:215](../../../Sources/FacetViewGrid/GridView.swift#L215)), replace `for (i, ws) in workspaces.enumerated()` with a section-driven loop. Build a small local model so the geometry code (cellRect, header rect, window hits) is shared between the two kinds:

```swift
    // EX-2: render the projected section list (workspace + lens cells) when
    // the section model is active; else the by-workspace degrade (identical
    // to pre-EX-2). `workspaces` stays the unfiltered snapshot for DnD/landing.
    struct CellSource {
        let wsIndex: Int            // 0-based; -1 for a lens (no source WS)
        let sectionType: SectionType
        let sectionID: String
        let label: String
        let mode: String            // layout engine; "" for a lens
        let windows: [Window]
        let isActive: Bool          // single-highlight already gated
    }
    let sources: [CellSource] = sections.isEmpty
        ? workspaces.map { ws in
            CellSource(wsIndex: ws.index, sectionType: .workspace,
                       sectionID: "ws:\(ws.index)", label: ws.name,
                       mode: ws.layoutMode, windows: ws.windows,
                       isActive: activeLens == nil && ws.isActive)
        }
        : sections.map { sec in
            let isLens = sec.sectionType == .lens
            // Workspace cells need their live layoutMode (the projection
            // doesn't carry it); look it up by source index.
            let mode = isLens ? "" :
                (sec.sourceWorkspaceIndex.flatMap { src in
                    workspaces.first { $0.index == src }?.layoutMode } ?? "")
            // EX-2 single-highlight (mirror of the tree's headerActive XOR):
            let active = isLens
                ? (activeLens != nil && sec.label == activeLens)
                : (activeLens == nil
                   && sec.sourceWorkspaceIndex
                        .flatMap { src in workspaces.first { $0.index == src }?.isActive } == true)
            return CellSource(
                wsIndex: sec.sourceWorkspaceIndex ?? -1,
                sectionType: sec.sectionType,
                sectionID: sec.id, label: sec.label, mode: mode,
                windows: sec.windows, isActive: active)
        }
```

> `.unassigned` sections never reach here (`FilterProjection` emits none), so `sources` is workspace + lens only.

- [ ] **Step 2: Build each cell from a `CellSource`; build the window→home-WS map (geometry + label unchanged; identity from the source)**

**Window home-WS resolution (MUST-FIX #1 prerequisite).** A window thumb inside a *lens* cell belongs to some workspace, but the lens cell's `wsIndex` is `-1` — so a window pick cannot derive its home workspace from the cell. Build the lookup once at the top of `layoutCells` from the **unfiltered `workspaces` snapshot** (the authority for membership) and store it on the view for the click/keyboard handlers (EX-2.5 / EX-2.6):

```swift
    // EX-2: window → home workspace index (0-based). A window thumb may sit
    // in a LENS cell (wsIndex=-1) but still has a real home WS; picks resolve
    // through this, never through the cell's wsIndex. (Stored prop on GridView:
    //   private var windowHomeWS: [WindowID: Int] = [:]   )
    windowHomeWS = [:]
    for ws in workspaces { for w in ws.windows { windowHomeWS[w.id] = ws.index } }
```

Replace the body that built `OverviewCell` from `ws` so it iterates `sources` and threads the new identity through. The window-hit loop is **unchanged** (still `where !win.isLensParked`, still `gridScaledWindowRect`; note `sec.windows` may repeat a window that matches several sections — the grid renders it in each cell, a cosmetic accepted for EX-2a):

```swift
    for (i, src) in sources.enumerated() {
        let r = i / cols, c = i % cols
        // … existing cellRect / rowSlotY / x / y / headerRect geometry,
        //     using `src.windows` in place of `ws.windows` …
        var hits: [MiniWindowHit] = []
        if useScreen.width > 0 {
            for win in src.windows where !win.isLensParked {
                guard let f = win.frame else { continue }
                let wr = gridScaledWindowRect(windowFrame: f,
                                              screenFrame: useScreen,
                                              cellRect: cellRect)
                guard wr.width >= 2, wr.height >= 2 else { continue }
                hits.append(MiniWindowHit(pid: win.pid, id: win.id,
                                          isFocused: win.isFocused,
                                          rect: wr, mark: win.mark))
            }
        }
        // … existing headerY / headerRect …
        cells.append(OverviewCell(
            wsIndex: src.wsIndex,
            rect: cellRect, headerRect: headerRect,
            isActive: src.isActive,
            label: src.sectionType == .lens
                ? src.label                              // lens: bare label
                : gridLabel(name: src.label, idx: src.wsIndex),
            mode: src.mode, windows: hits,
            sectionType: src.sectionType, sectionID: src.sectionID))
    }
```

> Lens cells lay out their member windows by real frame (declared cosmetic — see "Deferred"). `isActive` already encodes the XOR, so `draw()` (509/513/533) and `drawHeader` (27/38/63/79) light exactly one cell with **no change to those paths**.

- [ ] **Step 3: Build + host-verify (deferred to the EX-2a host-verify; build-gate now)**

Run: `swift build`. Expected: PASS. Visual confirmation (lens cell appears; only one cell lit under a lens) is part of the EX-2a host-verify after EX-2.5.

- [ ] **Step 4: Commit**

```bash
git add Sources/FacetViewGrid/GridView.swift
git commit -m ":sparkles: feat(grid): section リストを cell 描画 + 単一ハイライト (EX-2.3)"
```

---

## Task EX-2.5: route grid clicks through `activateSection`; lens cells non-drag

> (Numbered 2.5 to match the ledger; EX-2.4 single-highlight folded into EX-2.3 — `isActive` baking made it a non-separable part of the cell build.)

**Files:**
- Modify: `Sources/FacetViewGrid/GridPick.swift` (`.lens` case)
- Modify: `Sources/FacetViewGrid/GridView.swift` (`mouseDown` lens routing + drag guard)
- Modify: `Sources/FacetApp/Controller+Grid.swift` (`onPick` closure → `self?.activateSection`)

**Interfaces:**
- Consumes: `OverviewCell.isLens`/`sectionID`/`label` (EX-2.1/2.3), `Controller.activateSection(_:autoFocus:)` (EX-1).
- Produces: `GridPick.lens(label: String)`; the grid no longer calls `bk.switchWorkspace` directly for cell picks.

- [ ] **Step 1: Add the lens pick case**

[GridPick.swift:9](../../../Sources/FacetViewGrid/GridPick.swift#L9). Note `.window` now carries the **window's resolved home workspace** (0-based), NOT the cell's `wsIndex` — a window in a lens cell has a real home WS but the lens cell's `wsIndex` is `-1` (MUST-FIX #1):
```swift
public enum GridPick: Sendable {
    case workspace(workspaceIndex: Int)
    case lens(label: String)              // EX-2: a lens-section cell was picked
    // homeWorkspaceIndex = the WINDOW's home WS (0-based), resolved via
    // windowHomeWS — works whether the thumb sits in a workspace OR a lens cell.
    case window(homeWorkspaceIndex: Int, pid: Int, windowID: WindowID)
}
```

- [ ] **Step 2: Fire `.lens` for a lens cell; block lens-cell drag**

In `mouseDown` ([GridView.swift:688](../../../Sources/FacetViewGrid/GridView.swift#L688)):
- Header band branch (`pendingHeaderDown`): a lens cell's header is a **click target, not a swap handle** — fire the lens pick immediately and do not arm the swap drag:
  ```swift
  if let cell = cells.first(where: { $0.headerRect.contains(p) }) {
      if cell.isLens { onPick?(.lens(label: cell.label)); return }
      pendingHeaderDown = (point: p, ws: cell.wsIndex)
      return
  }
  ```
- Empty-area branch (`onPick?(.workspace(...))` at line 708): fire `.lens` for a lens cell:
  ```swift
  } else if cell.isLens {
      onPick?(.lens(label: cell.label))
  } else {
      onPick?(.workspace(workspaceIndex: cell.wsIndex))
  }
  ```
- Window-thumb branch: the pick must carry the **window's home WS**, not the cell's `wsIndex` (MUST-FIX #1). Where the window pick fires (the `onPick?(.window(…))` at ~775 on click resolution, and the empty-cell-thumb arm at `pendingDown` ~706), resolve the home WS through the map built in EX-2.3:
  ```swift
  let home = windowHomeWS[win.id] ?? cell.wsIndex   // real home, even in a lens cell
  onPick?(.window(homeWorkspaceIndex: home, pid: win.pid, windowID: win.id))
  ```
- **Mouse** drop-target guard (lens cells are not move/swap targets): in `mouseDragged` where `dropTargetWS` is computed (the cell-under-cursor during a drag, ~759–763), **exclude lens cells** — add `&& !$0.isLens` to the candidate-cell predicate so a lens cell never becomes a `dropTargetWS`. (The **keyboard** drag paths are guarded in EX-2.6 — MUST-FIX #2.)

- [ ] **Step 3: Route the Controller `onPick` closure through `activateSection`**

[Controller+Grid.swift:69](../../../Sources/FacetApp/Controller+Grid.swift#L69) — replace the direct `bk.switchWorkspace` calls. The closure already captures `[weak self]`:

```swift
        gv.onPick = { [weak self, bk = backend] pick in
            switch pick {
            case .workspace(let ws):
                // ws is 0-based (cell.wsIndex == Workspace.index); ActiveSection
                // is 1-based → +1. Routes through the validated throughline
                // (clears any active lens, updates the mirror on main).
                self?.activateSection(.workspace(ws + 1), autoFocus: true)
            case .lens(let label):
                self?.activateSection(.lens(label), autoFocus: true)
            case .window(let home, let pid, let id):
                // `home` is the WINDOW's home WS (0-based), resolved via
                // windowHomeWS — correct whether the thumb sat in a workspace
                // OR a lens cell. Switch there (clears any lens; runs on main,
                // updates the mirror immediately), THEN re-assert focus. Guard
                // home >= 0 so an unresolvable window (no home) focuses without
                // a bogus .workspace(0) (which dispatchWorkspace silently drops).
                if home >= 0 {
                    self?.activateSection(.workspace(home + 1), autoFocus: false)
                }
                cliQueue.async {
                    let win = Window(id: id, pid: pid, appName: "", title: "",
                                     isFocused: false, isFloating: false, frame: nil)
                    Focus.assert(win, backend: bk)
                }
            }
            self?.hideGrid()
        }
```

> **Verify the +1**: a workspace cell for `Workspace.index == 0` must activate `.workspace(1)`. A window pick passes `home + 1` (`home` is 0-based). `.workspace(0)` is the bug the `home >= 0` guard + the `windowHomeWS` resolution prevent (MUST-FIX #1). Getting either wrong reproduces the EX-1 M1 trap / the lens-cell no-op.

- [ ] **Step 4: Seed `gv.sections`/`gv.activeLens` at show**

`seedOverviewCommon` (EX-2.2) already seeds `sections`/`activeLens` for any `OverviewView`, and `showGrid` calls `seedOverviewCommon(gv, …)`, so the section feed at show is covered. The `kbSelectedWS` → `kbSelectedIdx` seed conversion (the `showGrid` selection seed at ~110–112) is **not** done here — it changes in EX-2.6 Step 1 (the keyboard re-key owns it). Between EX-2.5 and EX-2.6 the grid is functional via mouse; keyboard nav is correct after EX-2.6.

- [ ] **Step 5: Build**

Run: `swift build`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FacetViewGrid/GridPick.swift Sources/FacetViewGrid/GridView.swift \
        Sources/FacetApp/Controller+Grid.swift
git commit -m ":sparkles: feat(grid): cell クリックを activateSection 経由化 + lens 非DnD (EX-2.5)"
```

---

## Task EX-2.6: keyboard nav over section cells + docs

**Files:**
- Modify: `Sources/FacetViewGrid/GridView.swift` (keyboard select/commit guards)
- Modify: `config.toml`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md`

**Interfaces:**
- Consumes: `OverviewCell.isLens`/`sectionID` (EX-2.1/2.3).

- [ ] **Step 1: Re-key keyboard selection on the cell-array index; commit lens cells; guard keyboard drag (MUST-FIX #2 + should-fix #1)**

The grid keys keyboard selection on `kbSelectedWS` (a `wsIndex: Int?`) and matches cells via `cells.firstIndex(where: { $0.wsIndex == kbSelectedWS })`. Lens cells share `wsIndex == -1`, so multiple lens cells collide (arrow/Tab traps on the first). **Re-key the whole keyboard surface on the cell-array index** (`kbSelectedIdx: Int`, an index into `cells`), and read `cells[kbSelectedIdx]` for commit + accent + drag. The `wsIndex == -1` sentinel STAYS (DnD/landing still use it for workspace cells); only keyboard selection stops keying on it.

**Enumerate and convert every `kbSelectedWS` site** (grep `kbSelectedWS` — should-fix #1; ~11 sites, re-locate by symbol, line numbers as of `b75232e`):
- `kbMoveSelection(dx:dy:)` (~978–994): compute the 2-D move over `cells` array indices, not `wsIndex` lookups. **While a drag is in flight, skip lens cells as landing targets** (a lens is not a swap/move destination — MUST-FIX #2).
- `kbCycleWindow` (~1003), `kbSelectedWindow` helper (~1014–1016): read `cells[kbSelectedIdx]`.
- `syncKbDragToSelection` (~1024–1028): set `d.dropTargetWS` from the selected cell **only when `!cells[kbSelectedIdx].isLens`**, else `d.dropTargetWS = nil` (MUST-FIX #2 — a keyboard-lifted window/workspace must never commit onto a lens cell).
- `kbLiftWorkspace` (~1073): a lens cell cannot be lifted for a swap — `guard !cells[kbSelectedIdx].isLens else { return }`.
- `kbCommit` (~1097, 1113–1124) + its `dst` lookup (`cells.first(where: { $0.wsIndex == dst })`): branch on the selected cell's kind —
  - lens cell → `onPick?(.lens(label: cells[kbSelectedIdx].label))`;
  - workspace cell, empty-area Return → `onPick?(.workspace(workspaceIndex: cells[kbSelectedIdx].wsIndex))` (Controller closure does the `+1`);
  - window-in-cell Return → resolve the window home WS via `windowHomeWS` and fire `.window(homeWorkspaceIndex: home, …)` (same as the mouse path, MUST-FIX #1);
  - the drag-commit `dst` lookup must reject lens cells (it cannot be one after the `syncKbDragToSelection` guard, but assert/guard defensively).
- `commitSwitch` (~1133): route through the same `onPick` kind-branch (no raw `wsIndex` switch).
- **Draw accents** that compared `kbSelectedWS == cell.wsIndex` for the browse-target accent (GridHeader.swift `headerSel` ~23, GridView.draw ~532): compare the cell-array index against `kbSelectedIdx` instead.
- **`showGrid` seed** (Controller+Grid.swift ~110–112): currently `gv.kbSelectedWS = lastWorkspaces.first { $0.isActive }?.index ?? …`. Convert to a cell-array-index seed: after `layoutCells`, set `kbSelectedIdx` to the index of the active cell (`cells.firstIndex { $0.isActive } ?? 0`). (This supersedes the EX-2.5 Step 4 note — the seed change lands here.)

- [ ] **Step 2: Build**

Run: `swift build`. Expected: PASS.

- [ ] **Step 3: Docs — grid now renders lens cells (3-view parity)**

- `config.toml`: in the `[[desktop.N.section]]` / lens commentary, note that lens sections now appear as **cells in the grid** (not tree-only) and clicking one activates the lens (same as `facet lens NAME`).
- `docs/glossary.md`: under `### lens` / `### active section`, broaden "tree-only" wording — lens sections render in the tree **and the grid** (rail in EX-2b). Update any "grid/rail render the `.workspace` kind only" note.
- `docs/architecture.md`: the two-machineries / 3-view table — mark the grid as a section-list consumer (rail pending EX-2b).
- `README.md` + `README.ja.md`: if the views section claims grid is workspace-only, update to "grid renders the same section list as the tree, including lenses." Keep bilingual in sync ([[readme-bilingual]]).

- [ ] **Step 4: Commit**

```bash
git add Sources/FacetViewGrid/GridView.swift config.toml docs/glossary.md \
        docs/architecture.md README.md README.ja.md
git commit -m ":memo: docs(grid): lens cell の 3-view parity を反映 + kb-nav 整理 (EX-2.6)"
```

---

## EX-2a host-verify (トミー operates; synthetic input NG)

Build + run; on a mac desktop whose ordinal has a `[[desktop.N.section]]` block with **both** a `type="workspace"` and a `type="lens"` section (the `config.toml` ACTIVE SAMPLE `desktop.1` works: 2 workspaces + a "Web" lens). Re-grant AX if `./run.sh` re-sign dropped it (System Settings ▸ Accessibility ▸ toggle facet; or `tccutil reset Accessibility com.facet.app`). Confirm on screen + `/tmp/facet.log`:

1. **Lens cell renders.** Open Chrome on facet WS1 + WS2; `facet --view grid` → the grid shows the workspace cells **and** a "Web" lens cell (its member Chrome windows mini-rendered). (Provide exact commands.)
2. **Single-highlight, no lens active.** With no lens active, exactly the active *workspace* cell is lit (`pal.primary`); the lens cell is muted.
3. **Single-highlight, lens active.** `facet lens "Web"`, then `facet --view grid` → exactly the **"Web" lens cell** is lit; **all workspace cells are muted** (the EX-2 deliverable — confirm no workspace cell shows the primary accent).
4. **Click a lens cell activates the lens.** Click the "Web" cell → grid dismisses, `/tmp/facet.log` shows `setSectionLens "Web" visible=N` + union tile + autoFocus (same as `facet lens "Web"`).
5. **Click a workspace cell switches + clears.** With "Web" active, click a workspace cell → switches to that WS, lens clears (`engine WS N frames=…`, parked windows restored), the now-active workspace is the lit section.
6. **Click a window thumb focuses it (workspace cell).** Click a specific window thumb in a workspace cell → switches to its WS + focuses that window.
6b. **Click a window thumb INSIDE the lens cell (MUST-FIX #1).** Click a window thumb in the "Web" lens cell → switches to **that window's home workspace**, clears the lens, focuses the window — NOT a silent no-op. (Pre-fix this routed `.workspace(0)` and did nothing.) Repeat via keyboard: arrow to the window inside the lens cell + Return → same result.
7. **Lens cell is not a drag target — mouse AND keyboard (MUST-FIX #2).** Drag a window thumb onto the lens cell (mouse) → no move. Lift a window with Space/Return then arrow onto the lens cell + Return (keyboard) → no move. Dragging/lifting a lens cell header does not start a swap.
8. **Degrade unchanged.** On a mac desktop with NO `[[desktop.N.section]]` block, `facet --view grid` renders exactly as before (workspace cells only, active one lit).

Record results in the SDD ledger. **push/merge awaits トミー go.**

---

## EX-2b — Rail section cells + hero + highlight (FOLLOW-UP PHASE, re-plan at start)

Deferred per Decision 2. A separate branch (`feat/ex2b-rail-sections`) + a detailed re-plan written when EX-2a lands + host-verifies. The shared infra (EX-2.1/2.2) is reused as-is. Enumerated key changes (to be detailed then), from the codemap (`wf_165f48db-2eb` rail-view reader):

- **`RailView.layoutCells`** iterates `sections` (carousel cells keyed by `sectionID`); `selectedWS: Int?` → a section-aware browse cursor (`selectedSectionID: String?`). `railCarouselOffsets` is pure/count-based — no change.
- **Hero** = the active/selected section. **Open visual call (トミー, then):** when the active section is a lens, the lens cell becomes the hero rendering its union (recommended — preserves "active = centre hero"), vs. blank/stable hero. Lens has no `sourceWorkspaceIndex` → guard every `wsIndex` read.
- **Single-highlight:** bake the XOR into the cell's accent like the grid (`drawCell` accent at RailView ~677-693 reads the active flag) — suppress the active-workspace accent when `activeLens != nil`.
- **Click routing:** `onPick` carries the section (workspace vs lens) → `self?.activateSection`; `onPickWindow` → `activateSection(.workspace(ws+1))` + `Focus.assert`. Lens cells non-drag (`selectedSectionID` lift guard).
- **`apply()` rail feed** (the `if let rv = railView` block) seeds `rv.sections`/`rv.activeLens` (already added symmetric in EX-2.2) + relayout — the rail is persistent, so an external lens activate/clear while it is open must re-light without a fresh show.
- **Carousel re-centre** (`rv.selectedWS == oldActive` re-centre logic, ~899) generalizes to the section cursor.
- **EX-2b host-verify** mirrors EX-2a on the rail.

When EX-2b lands, the "declared gap" (rail lights active-WS under a lens) is closed and the full "3-view unified highlight" deliverable is met.

---

## Self-Review

**1. Spec coverage** (parent plan EX-2 row: "grid/rail render lens sections as cells; click any window/cell → activate+focus; unified highlight 3-view"):
- "render lens sections as cells" → EX-2.3 (grid) + EX-2b (rail). ✓
- "click any window/cell → activate+focus" → EX-2.5 (grid `onPick` → `activateSection`; window thumb → switch+`Focus.assert`) + EX-2b (rail). ✓
- "unified highlight 3-view" → EX-2.3 bakes the tree's `headerActive` XOR into the grid; EX-2b extends it to the rail. Tree already done (EX-1). ✓ (Full 3-view parity completes at EX-2b — declared, not dropped.)
- Open question ⑨ → resolved MOOT (Decision 1). ✓

**2. Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". Every code step shows the code or names the exact symbol + edit. EX-2b is intentionally a *scoped* follow-up phase (not placeholder tasks) — re-planned at its start per the canon's "各 phase 着手時に再計画". ✓

**3. Type consistency:** `OverviewCell.sectionType: SectionType` / `sectionID: String` / `isLens` (EX-2.1) used consistently in EX-2.3/2.5/2.6. `OverviewView.sections: [ProjectedSection]` / `activeLens: String?` (EX-2.2) consistent. `GridPick.lens(label:)` (EX-2.5). `Controller.lastSections`/`lastActiveLens` (EX-2.2). `activateSection(.workspace(ws+1))` 1-based throughout. ✓

**4. Risks re-checked against the codemap:**
- `workspaces` snapshot retained alongside `sections` (DnD landing gate) — Constraint + EX-2.2 keep it. ✓
- `startOverviewCaptures` unchanged (lens-cell windows ⊆ workspace windows) — no capture task needed. ✓
- The +1 trap flagged in the Constraints + EX-2.5 Step 3 verify note. ✓
- Single `FilterProjection.project` + single `logDiagnosticsOnChange` in `apply()` after the hoist (EX-2.2 Step 3 verify). ✓

**5. Adversarial plan review folded (`wf_4b32d385-200`, 3 lenses + adjudication → needs-fixes, 2 must-fix):**
- **MUST-FIX #1** (window thumb in a lens cell → `activateSection(.workspace(0))` no-op): resolved — EX-2.3 builds `windowHomeWS`; `GridPick.window` carries `homeWorkspaceIndex`; EX-2.5 Step 3 routes `home + 1` guarded `home >= 0`; mouse + keyboard + host-verify (6b) all cover it. ✓
- **MUST-FIX #2** (lens cell guarded as a mouse drop target but not the keyboard drag paths): resolved — EX-2.6 Step 1 guards `syncKbDragToSelection` + the `kbCommit` dst lookup + `kbMoveSelection` landing; host-verify item 7 covers mouse AND keyboard. ✓
- **Should-fix:** EX-2.6 Step 1 enumerates all ~11 `kbSelectedWS` re-key sites + the `showGrid` seed; EX-2.2 Step 3 clarifies the single-call/single-log hoist + its placement after the active-section re-read (~877). ✓
- Reviewer "must-fixes" that were the plan's own deliverables (add `.lens` to `GridPick`, add protocol props, route through `activateSection`, the kb wsIndex=-1 collision already fixed by EX-2.6) were adjudicated as non-defects — no plan change. ✓
