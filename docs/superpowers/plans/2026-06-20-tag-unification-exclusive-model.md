# Tag Unification — Exclusive Selection Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn facet's window grouping into a single "exclusive active section" model — at any moment exactly one section (a `type="workspace"` spatial cell **or** a `type="lens"` cross-workspace filter) is active, its `match` windows are shown (real anchor-park hide of everything else), and the three views (tree/grid/rail) are three renderings of the one shared section list.

**Architecture:** The exclusive model is a *unification of two tiling machineries facet already owns*, selected by the active section's `type`:
- `type="workspace"` active → per-workspace **stateful** tiling (bsp/stack/float/master-*), today's `activeIndex` path.
- `type="lens"` active → **cross-workspace union** stateless tiling, today's *tag-mode* path (`visibleNonFloatingMembers()` / `tagUnionFrames()` in [WorkspaceCatalog+Tags.swift](../../../Sources/FacetAdapterNative/WorkspaceCatalog+Tags.swift)), but driven by a `FacetFilter` `match` instead of a tag bitmask.

Phase 1 (shipped, #313) added section-lens real-hide but scoped it to the **active workspace only** ([`slot.workspace == activeIndex`](../../../Sources/FacetAdapterNative/WorkspaceCatalog+SectionLens.swift#L70)). This plan *generalises* that to cross-workspace and makes the active lens **exclusive** with the active workspace, then layers grid/rail parity, orphan/迷子 mechanics, symmetric DnD, and finally retires the parallel `[grouping] by="tag"` path.

**Tech Stack:** Swift 6, macOS 13+. Pure logic in `FacetCore` (no AppKit). Backend/AX in `FacetAdapterNative` (sole backend). GUI in `FacetView*`. Views talk only to the `WindowBackend` protocol. `swift build` is the local bar; XCTest runs in CI only (CommandLineTools can't run `swift test`).

## Global Constraints

- **Layer spine is non-negotiable.** `FacetCore` pure (CoreGraphics OK, no AppKit / no AX / no backend types). `FacetAdapterNative` is the only place AX/CGS types appear. Views talk to `WindowBackend`, never a concrete adapter. Crossing a layer means a missing protocol method. ([[facet-architecture-decisions]])
- **Real hide = anchor-park only.** A "hidden" window is moved to the 1×41px bottom-right sliver ([`parkAnchor`](../../../Sources/FacetAdapterNative/NativeAdapter+Anchor.swift#L24)); it stays in Mission Control. facet never moves a window across mac desktops (SIP-on contract). ([[native-window-hide-methods]])
- **Catalog is the single state authority.** Membership / active-section / park sets live in `WorkspaceCatalog` (mutated only on `cliQueue`); views read a snapshot. No view-side recompute that can drift from the catalog.
- **`match` evaluation is adapter-side.** The catalog holds no live `appName`/`title` (only `windowMap`: workspace + pid + tags). Lens `match` is evaluated in `FacetAdapterNative` via the shared [`LensMembership.matches`](../../../Sources/FacetCore/LensMembership.swift#L33) predicate, then handed to the catalog as an id set. Display (`FilterProjection`) and hide (park) route through the SAME predicate so they can never disagree.
- **All TOML keys clamp, never reject.** Out-of-range / unknown values fall back to the default for that one key. Read through the `effective*` accessors, never the raw Optional fields. ([[config-default-behavior]])
- **Loud on typo, silent on success.** Unknown view/section/layout NAME → `exit 2` with a stderr message. Happy path stays quiet. ([[control-is-cli-first]])
- **Tests compile in CI only.** Write XCTest defensively (`accuracy:` is non-Optional FloatingPoint; no test-only `@testable` surprises). Local gate is `swift build`. ([[feedback-swift-tests-only-compile-in-ci]])
- **No push/merge without an explicit OK from トミー.** Commit locally freely; each PR is squash-merged only on go. Branch names `feat/…` / `fix/…` / `refactor/…`. ([[pr-conventions]], [[grid-view-work-style]])
- **Glossary terms are canonical.** `mac desktop` / `facet workspace` / `facet view` / `lens` / `section` — add/rename a term in the same PR as the code. ([docs/glossary.md](../../glossary.md))

---

## The Unification (read this before any task)

### One concept: the *active section*

```
activeSection := activeLens (a type="lens" section)   if a lens is active
              := activeWorkspace (a type="workspace")  otherwise
```

There is **always exactly one** active section (decision ①: 0 is illegal, 2 is illegal). A workspace is always present (`activeIndex` is always valid), so the active section is "the active lens if one is set, else the active workspace." Activating a lens and activating a workspace are **mutually exclusive**:

- Activate workspace section W (`facet workspace --focus`, a tree/grid/rail click on a workspace cell): clear any active lens, switch to W, stateful-tile W.
- Activate lens section L (`facet lens NAME`, a click on a lens cell/window): set active lens = L, cross-workspace union-tile L's matches, anchor-park everything else **in every workspace**.

### What changes vs. Phase 1 (#313)

| Aspect | Phase 1 (shipped, 併用) | Exclusive model (this plan) |
|---|---|---|
| Lens scope | active workspace only | **all workspaces (横断)** |
| `lensParkedMembers` | active-WS windows only | windows in **any** workspace |
| Lens tiling | the active WS's own layout, on the narrowed subset | **union stateless tiling** of the cross-workspace matches (the lens's `layout`) |
| Highlight | active WS **and** active lens (both lit) | **exactly one** lit (lens active ⇒ WS not lit) |
| Switch WS while lens active | lens persists, re-composed in new WS (D1) | switching a workspace **clears the lens** (exclusive) |

### The two machineries are already there

Cross-workspace union tiling is *exactly* what tag-mode does today:
- Member set: [`visibleNonFloatingMembers()`](../../../Sources/FacetAdapterNative/WorkspaceCatalog+Tags.swift#L55) — global `windowMap` filter (no per-WS split).
- Frames: [`tagUnionFrames(in:)`](../../../Sources/FacetAdapterNative/WorkspaceCatalog+Tags.swift#L70) — one stateless engine over the union.
- Park delta: [`setLens`](../../../Sources/FacetAdapterNative/WorkspaceCatalog+Tags.swift#L389) — cross-workspace toPark/toRestore.
- Layout routing: [`applyLayout`](../../../Sources/FacetAdapterNative/NativeAdapter+Scratchpad.swift#L513) branches on `grouping == .tag`.

This plan builds the **section-model twin** of each, driven by a `match` string instead of a `UInt64` lens mask — reusing the same anchor-park chokepoints ([`applyHide`](../../../Sources/FacetAdapterNative/NativeAdapter+DynamicWS.swift#L114), [`detachFromLayouts`/`attachToLayout`](../../../Sources/FacetAdapterNative/WorkspaceCatalog+Layout.swift#L18)).

### Phase roadmap (supersedes the memory's old union-based Phase 2/3)

| Phase | Deliverable | Ships? | Defers |
|---|---|---|---|
| **EX-1** | Cross-workspace **exclusive** lens activation + union tiling + layout clamp by type | ✅ dogfoodable | orphans, grid/rail cells, DnD, by=tag |
| **EX-2** | Three views = one section list: grid/rail render lens sections as cells; window/cell click activates its section + focus; one unified highlight | ✅ | orphans, DnD, by=tag |
| **EX-3** | `workspace = 0 or 1` (nullable slot, 迷子) + symmetric DnD move (un-apply→apply, all pairs) + new-window apply inheritance + 迷子 lens receptacle config | ✅ | by=tag |
| **EX-4** | CLI = 2 systems (section-activate verb + window-attribute verbs); **delete `[grouping] by="tag"`** + bitmask tag-mode; startup-active = first workspace section; config template w/ 迷子 "推奨!!"; docs/glossary/README | ✅ | — |

**Why this order:** EX-1/EX-2 are the visible dogfood wins and reuse existing machinery (low risk). EX-3's nullable-`workspace` change touches ~7 assignment paths (high churn) — done once the visible model is proven. EX-4's `by=tag` deletion is only safe after the section model fully covers tag-mode's use cases (EX-1..3 do). Each phase ships working software; no phase leaves debt the next must clean.

---

# EX-1 — Cross-workspace exclusive lens (the 横断 core)

Three PRs, mirroring Phase 1's rhythm (core → runtime → view/CLI/docs). EX-1a is pure + additive (no behavior change). EX-1b flips the behavior. EX-1c polishes the surface.

## EX-1a — Lens `layout` field + stateless clamp (pure, additive, no behavior change)

A `type="lens"` section gains an optional `layout` that seeds its **union** tiling, clamped to a stateless engine (decision ⑩/⑫). Pure FacetCore; current runtime ignores it, so this PR changes no behavior.

**Files:**
- Modify: `Sources/FacetCore/DesktopSection.swift` (struct already has `layout: String?`; extend `parse` to accept it for `type="lens"`)
- Create: `Sources/FacetCore/LensLayout.swift` (pure clamp helper)
- Modify: `Sources/FacetCore/Grouping.swift` (expose a `statelessModeNames` / `isStateless(mode:)` helper if not already public)
- Test: `Tests/FacetCoreTests/LensLayoutTests.swift`
- Test: `Tests/FacetCoreTests/DesktopSectionTests.swift` (extend)

**Interfaces:**
- Consumes: `LayoutRegistry.allModeNames` / `LayoutRegistry.engine(named:)` ([Layout.swift:406](../../../Sources/FacetCore/Layout.swift#L406)), `LayoutGrouping.isCompatible(mode:with:)` ([Grouping.swift:61](../../../Sources/FacetCore/Grouping.swift#L61)).
- Produces:
  - `DesktopSection.layout` populated for `type="lens"` rows (was workspace-only).
  - `func LensLayout.resolve(_ requested: String?, globalDefault: String) -> String` — returns a **stateless** engine name. Non-stateless (`bsp`/`stack`/`float`) or unknown → fallback. Fallback = `globalDefault` if it is stateless, else `"grid"`.

- [ ] **Step 1: Write the failing test for the clamp helper**

`Tests/FacetCoreTests/LensLayoutTests.swift`:
```swift
import XCTest
@testable import FacetCore

final class LensLayoutTests: XCTestCase {
    func testStatelessRequestPassesThrough() {
        XCTAssertEqual(LensLayout.resolve("spiral", globalDefault: "grid"), "spiral")
        XCTAssertEqual(LensLayout.resolve("master-left", globalDefault: "grid"), "master-left")
    }
    func testStatefulRequestClampsToGlobalDefaultWhenStateless() {
        // bsp is workspace-only (stateful) → not allowed for a lens union.
        XCTAssertEqual(LensLayout.resolve("bsp", globalDefault: "spiral"), "spiral")
    }
    func testStatefulGlobalDefaultClampsToGrid() {
        // Neither request nor global default is a stateless engine → "grid".
        XCTAssertEqual(LensLayout.resolve("stack", globalDefault: "bsp"), "grid")
        XCTAssertEqual(LensLayout.resolve(nil, globalDefault: "float"), "grid")
    }
    func testUnknownRequestClamps() {
        XCTAssertEqual(LensLayout.resolve("nonsense", globalDefault: "grid"), "grid")
    }
    func testNilRequestUsesStatelessGlobalDefault() {
        XCTAssertEqual(LensLayout.resolve(nil, globalDefault: "spiral"), "spiral")
    }
}
```

- [ ] **Step 2: Run it to confirm it fails to compile**

Run: `swift build` (the type `LensLayout` doesn't exist yet).
Expected: FAIL — `cannot find 'LensLayout' in scope`.

- [ ] **Step 3: Implement the clamp helper**

`Sources/FacetCore/LensLayout.swift`:
```swift
// Resolve a lens section's union layout to a STATELESS engine. A
// type="lens" section tiles a cross-workspace union (decision ⑩/⑫); the
// stateful engines (bsp/stack) thread a per-workspace tree and can't
// represent an arbitrary union, so a lens layout is clamped here exactly
// like tag-mode's config validation. A typo / forbidden value never
// breaks tiling — it falls back, it doesn't reject.
public enum LensLayout {
    /// Stateless engine name for a lens union. `requested` is the
    /// section's `layout`; `globalDefault` is `[layout] default`. Order:
    /// requested-if-stateless → globalDefault-if-stateless → "grid".
    public static func resolve(_ requested: String?, globalDefault: String) -> String {
        if let r = requested?.lowercased(), isStateless(r) { return r }
        let g = globalDefault.lowercased()
        if isStateless(g) { return g }
        return "grid"
    }

    /// A stateless engine = a registered `LayoutEngine` (master-*/grid/
    /// spiral). bsp / stack / float are NOT stateless engines.
    public static func isStateless(_ mode: String) -> Bool {
        LayoutRegistry.engine(named: mode.lowercased()) != nil
    }
}
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `swift build` then (CI) the test target. Local: `swift build`.
Expected: PASS (build green). Note in the commit that XCTest runs in CI.

- [ ] **Step 5: Extend `DesktopSection.parse` to accept `layout` on lens rows**

In [DesktopSection.swift:161](../../../Sources/FacetCore/DesktopSection.swift#L161) `parse(fromTOMLRow:)`, the `case .lens` branch currently sets `layout: nil`. Read the `layout` key (same as the workspace branch does) and pass it through. Keep `match` + `label` required. Workspace branch unchanged.

Add to `DesktopSectionTests.swift`:
```swift
func testLensSectionDecodesLayout() {
    let row: [String: TOMLValue] = [
        "type": .string("lens"),
        "label": .string("Web"),
        "match": .string("app~=Chrome"),
        "layout": .string("spiral"),
    ]
    let (section, note) = DesktopSection.parse(fromTOMLRow: row)
    XCTAssertNil(note)
    XCTAssertEqual(section?.type, .lens)
    XCTAssertEqual(section?.layout, "spiral")
}
```

- [ ] **Step 6: Run build + commit**

Run: `swift build`. Expected: PASS.
```bash
git checkout -b feat/ex1a-lens-layout-field
git add Sources/FacetCore/LensLayout.swift Sources/FacetCore/DesktopSection.swift Tests/FacetCoreTests/
git commit -m ":sparkles: feat(core): [ex1] type=\"lens\" section gains a stateless-clamped union layout

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## EX-1b — Cross-workspace park + union tiling + exclusivity (runtime, the heart)

Generalise the section-lens from active-WS-only to **cross-workspace**, tile the matched union with the lens's stateless layout, and make lens activation **clear on workspace switch** (exclusive). This is the behavior flip.

**Files:**
- Modify: `Sources/FacetAdapterNative/WorkspaceCatalog+SectionLens.swift` (drop the `slot.workspace == activeIndex` scope; add union member/frame helpers)
- Modify: `Sources/FacetAdapterNative/WorkspaceCatalog.swift` (`setActive` clears the section lens; `nonFloatingMembers` already excludes `lensParkedMembers`)
- Modify: `Sources/FacetAdapterNative/NativeAdapter.swift` (`setSectionLens` cross-workspace; `applySectionLensAutoFocus`)
- Modify: `Sources/FacetAdapterNative/NativeAdapter+Queries.swift` (`sectionLensVisibleIDs` over ALL windows; `applySectionLensReconcile` cross-workspace)
- Modify: `Sources/FacetAdapterNative/NativeAdapter+Scratchpad.swift` (`applyLayout` routes to lens-union when a section lens is active)
- Modify: `Sources/FacetAdapterNative/NativeAdapter+LayoutMode.swift` (layout-mode command guard while a lens is active)
- Test: `Tests/FacetAdapterNativeTests/SectionLensCatalogTests.swift` (extend: cross-workspace plans, union frames, switch-clears-lens)

**Interfaces:**
- Consumes (from EX-1a): `LensLayout.resolve(_:globalDefault:)`; `DesktopSection.layout` on lens sections.
- Consumes (existing): `applySectionLens(visibleIDs:in:)` ([+SectionLens.swift:65](../../../Sources/FacetAdapterNative/WorkspaceCatalog+SectionLens.swift#L65)), `tagUnionFrames` pattern ([+Tags.swift:70](../../../Sources/FacetAdapterNative/WorkspaceCatalog+Tags.swift#L70)), `applyHide` ([+DynamicWS.swift:114](../../../Sources/FacetAdapterNative/NativeAdapter+DynamicWS.swift#L114)), `LensMembership.matches` ([LensMembership.swift:33](../../../Sources/FacetCore/LensMembership.swift#L33)).
- Produces:
  - `applySectionLens` parks/restores across **all** workspaces (signature unchanged; scope widened).
  - `func sectionLensUnionMembers() -> [WindowID]` (catalog): tracked, non-floating, non-hidden, non-lens-parked windows in stable serverID order — the union to tile.
  - `func sectionLensUnionFrames(layout: String, in: CGRect) -> [WindowID: CGRect]` (catalog).
  - `setActive(_:lensVisibleIDs:in:)` clears any active section lens first (returns the restore-all delta folded into its plan).
  - `applyLayout` lens-union branch active when `catalog.activeSectionLens != nil`.

### Task EX-1b.1: Widen `applySectionLens` to all workspaces

- [ ] **Step 1: Write the failing catalog test (cross-workspace park)**

In `SectionLensCatalogTests.swift`, seed a catalog with 2 workspaces, put window A in WS1 (active) and window B in WS2, then apply a lens whose `visibleIDs = {A}`. Assert **B is parked** (it lives in inactive WS2). Today's code only touches active-WS windows, so B would NOT park.
```swift
func testApplySectionLensParksAcrossWorkspaces() {
    var cat = makeCatalog(workspaces: 2)           // helper in this file
    cat.adopt(idA, workspace: 1)                    // active
    cat.adopt(idB, workspace: 2)                    // inactive
    cat.activeSectionLens = "Web"
    let plan = cat.applySectionLens(visibleIDs: [idA], in: rect)
    XCTAssertTrue(plan.toPark.map(\.id).contains(idB))   // FAILS today
    XCTAssertTrue(cat.lensParkedMembers.contains(idB))
}
```
(Use whatever adopt/seed helpers `SectionLensCatalogTests` already has; add a minimal one if absent.)

- [ ] **Step 2: Run it (CI-only; locally confirm it compiles)**

Run: `swift build`. Expected: PASS build. The assertion fails in CI today.

- [ ] **Step 3: Drop the active-WS scope in `applySectionLens`**

In [+SectionLens.swift:69](../../../Sources/FacetAdapterNative/WorkspaceCatalog+SectionLens.swift#L69), change the loop guard from
```swift
for (id, slot) in windowMap
where slot.workspace == activeIndex
    && isParkEligible(id)
    && !hiddenMembers.contains(id) {
```
to (drop the workspace clause):
```swift
for (id, slot) in windowMap
where isParkEligible(id) && !hiddenMembers.contains(id) {
```
Update the doc comment: `lensParkedMembers` now holds windows in **any** workspace (the cross-workspace exclusive model); `attachToLayout` on restore uses `slot.workspace` (already does for clear; do the same here — restore re-attaches to the window's **home** workspace, not `activeIndex`):
```swift
} else if shouldShow && isLensParked {
    lensParkedMembers.remove(id)
    attachToLayout(id, workspace: slot.workspace, focused: nil, in: rect)
    toRestore.append(WindowRef(id: id, pid: slot.pid))
}
```

- [ ] **Step 4: Run build; CI runs the test**

Run: `swift build`. Expected: PASS. CI: the new test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/FacetAdapterNative/WorkspaceCatalog+SectionLens.swift Tests/FacetAdapterNativeTests/SectionLensCatalogTests.swift
git commit -m ":recycle: refactor(adapter): [ex1] section-lens parks across all workspaces (横断)"
```

### Task EX-1b.2: Union members + frames for the active lens

- [ ] **Step 1: Write the failing test (union member order + frames)**

```swift
func testSectionLensUnionMembersExcludeParkedFloatingHidden() {
    var cat = makeCatalog(workspaces: 2)
    cat.adopt(idA, workspace: 1); cat.adopt(idB, workspace: 2); cat.adopt(idC, workspace: 2)
    cat.activeSectionLens = "Web"
    _ = cat.applySectionLens(visibleIDs: [idA, idB], in: rect)   // C parks
    XCTAssertEqual(Set(cat.sectionLensUnionMembers()), [idA, idB])
    XCTAssertFalse(cat.sectionLensUnionMembers().contains(idC))
}
func testSectionLensUnionFramesTileWithStatelessEngine() {
    var cat = makeCatalog(workspaces: 1)
    cat.adopt(idA, workspace: 1); cat.adopt(idB, workspace: 1)
    cat.activeSectionLens = "Web"
    _ = cat.applySectionLens(visibleIDs: [idA, idB], in: rect)
    let frames = cat.sectionLensUnionFrames(layout: "grid", in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    XCTAssertEqual(frames.count, 2)
    XCTAssertNotEqual(frames[idA], frames[idB])   // two cells, not overlapping
}
```

- [ ] **Step 2: Run (build)** — Expected: FAIL to compile (`sectionLensUnionMembers` missing).

- [ ] **Step 3: Implement the two helpers in `WorkspaceCatalog+SectionLens.swift`**

```swift
/// The cross-workspace union currently shown by the active section-lens:
/// every tracked, tileable window NOT parked out of the lens. Mirrors the
/// tag-mode `visibleNonFloatingMembers()` but the "in lens" decision is the
/// already-applied `lensParkedMembers` set (adapter evaluated the match).
/// Stable serverID order so tiling is deterministic.
func sectionLensUnionMembers() -> [WindowID] {
    windowMap
        .filter { !lensParkedMembers.contains($0.key)
            && !floatingWindows.contains($0.key)
            && !hiddenMembers.contains($0.key) }
        .map(\.key)
        .sorted { $0.serverID < $1.serverID }
}

/// Tiled frames for the active section-lens union, one stateless engine
/// over the cross-workspace set (the section-model twin of `tagUnionFrames`).
/// `layout` is the lens's resolved stateless engine (see `LensLayout`).
func sectionLensUnionFrames(layout: String, in rect: CGRect) -> [WindowID: CGRect] {
    guard let engine = LayoutRegistry.engine(named: layout) else { return [:] }
    return engine.frames(order: sectionLensUnionMembers(),
                         focused: nil, params: LayoutParams(), in: rect)
}
```

- [ ] **Step 4: Run build; CI runs tests.** Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git commit -am ":sparkles: feat(adapter): [ex1] cross-workspace lens union members + frames"
```

### Task EX-1b.3: `applyLayout` routes to the lens union when a lens is active

- [ ] **Step 1:** In [NativeAdapter+Scratchpad.swift:513](../../../Sources/FacetAdapterNative/NativeAdapter+Scratchpad.swift#L513) `applyLayout(workspace:rect:…)`, add a branch BEFORE the `grouping == .tag` branch:
```swift
// Active section-lens: tile the cross-workspace union (not the per-WS tree).
if let label = catalog.activeSectionLens {
    let resolved = LensLayout.resolve(lensLayout(forLabel: label),
                                      globalDefault: config.effectiveDefaultLayout)
    applyFrames(catalog.sectionLensUnionFrames(layout: resolved, in: rect),
                label: "section-lens \(label)", rect: rect, skip: skip, cached: cached)
    return
}
```
Add a small adapter helper `lensLayout(forLabel:)` (reads `config.effectiveMacDesktopSectionConfigs[ordinal]`, finds the `type=.lens` section with that label, returns its `layout`). Mirror the existing `sectionLensFilter()` lookup ([NativeAdapter+Queries.swift:376](../../../Sources/FacetAdapterNative/NativeAdapter+Queries.swift#L376)).

- [ ] **Step 2:** Run `swift build`. Expected: PASS.

- [ ] **Step 3:** Manual reasoning check (write as a comment in the PR): when no lens is active, `catalog.activeSectionLens == nil` → falls through to today's path unchanged. Commit.
```bash
git commit -am ":sparkles: feat(adapter): [ex1] applyLayout tiles the active lens union"
```

### Task EX-1b.4: `setSectionLens` applies the cross-workspace plan + union tiling

- [ ] **Step 1:** In [`setSectionLens`](../../../Sources/FacetAdapterNative/NativeAdapter.swift#L664), change the visible-id evaluation from active-WS-only to **all tracked windows**. Today `sectionLensVisibleIDs(workspace:live:)` ([NativeAdapter+Queries.swift:398](../../../Sources/FacetAdapterNative/NativeAdapter+Queries.swift#L398)) scopes to one workspace. Add/return-to an overload that evaluates `LensMembership.matches` over the **whole** live set, overlaying each window's home-workspace name (via `catalog.workspaceName(slot.workspace)`):
```swift
/// Cross-workspace: every tracked window whose live Window passes the
/// active lens match (home-workspace name overlaid per window).
func sectionLensVisibleIDsAll(live: [Window]) -> Set<WindowID>? {
    guard let filter = sectionLensFilter() else { return nil }
    var out: Set<WindowID> = []
    let byID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
    for (id, slot) in catalog.windowMap {
        guard let w = byID[id] else { continue }
        if LensMembership.matches(w, inWorkspaceNamed: catalog.workspaceName(slot.workspace),
                                  filter: filter) { out.insert(id) }
    }
    return out
}
```
`setSectionLens` then: resolve label → set `catalog.activeSectionLens` → `visibleIDs = sectionLensVisibleIDsAll(live:)` → `catalog.applySectionLens(visibleIDs:in:)` → `applyHide(plan)` → `applyLayout(activeIndex, rect)` (now routes to union) → `applySectionLensAutoFocus`.

- [ ] **Step 2:** Update [`applySectionLensReconcile`](../../../Sources/FacetAdapterNative/NativeAdapter+Queries.swift#L425) (D3 continuous re-park) to use the cross-workspace evaluator too, so a window opened in *any* workspace re-parks/-restores correctly each reconcile.

- [ ] **Step 3:** Run `swift build`. Expected: PASS. Commit.
```bash
git commit -am ":sparkles: feat(adapter): [ex1] setSectionLens evaluates + tiles cross-workspace"
```

### Task EX-1b.5: Exclusivity — switching a workspace clears the active lens

- [ ] **Step 1: Write the failing test**
```swift
func testSetActiveClearsSectionLens() {
    var cat = makeCatalog(workspaces: 2)
    cat.adopt(idA, workspace: 1); cat.adopt(idB, workspace: 2)
    cat.activeSectionLens = "Web"
    _ = cat.applySectionLens(visibleIDs: [idA], in: rect)   // B parked
    _ = cat.setActive(2, lensVisibleIDs: nil, in: rect)
    XCTAssertNil(cat.activeSectionLens)                      // lens cleared
    XCTAssertTrue(cat.lensParkedMembers.isEmpty)             // all restored
}
```

- [ ] **Step 2: Run (build).** Expected: build PASS; assertion fails in CI today.

- [ ] **Step 3: Make `setActive` clear the lens first.** In [`setActive(_:lensVisibleIDs:in:)`](../../../Sources/FacetAdapterNative/WorkspaceCatalog.swift#L551), at the top (before the existing lens-lift loop), if `activeSectionLens != nil` fold a full restore of `lensParkedMembers` into the plan and set `activeSectionLens = nil`, `lensParkedMembers.removeAll()`. (The existing loop that re-attaches `lensParkedMembers` already restores them; just also null `activeSectionLens` and ensure restore re-attaches to each window's **home** `slot.workspace`, which the post-EX-1b.1 code does.)

- [ ] **Step 4:** In [NativeAdapter.swift:464](../../../Sources/FacetAdapterNative/NativeAdapter.swift#L464) `switchWorkspace(toIndex:autoFocus:)`, pass `lensVisibleIDs: nil` (a workspace switch is now exclusive — it always clears the lens) and sync the lens mirror to nil. Remove the Phase-1 "re-compose lens in new WS" path (D1) — it contradicts the exclusive model.

- [ ] **Step 5:** Run `swift build`. Expected: PASS. Commit.
```bash
git commit -am ":boom: refactor(adapter)!: [ex1] workspace switch clears the active lens (exclusive)"
```

### Task EX-1b.6: Guard `--layout` while a lens is active

- [ ] **Step 1:** In [`setLayoutMode`](../../../Sources/FacetAdapterNative/NativeAdapter+LayoutMode.swift#L14): when `catalog.activeSectionLens != nil`, the layout command targets the **lens union** (stateless only). Reject `bsp`/`stack` loudly (mirror the tag-mode branch at line 18-35) and set the lens's runtime union layout; otherwise it targets the active workspace as today.

- [ ] **Step 2:** Run `swift build`. Expected: PASS. Commit.
```bash
git commit -am ":sparkles: feat(adapter): [ex1] --layout retargets the active lens union (stateless-guarded)"
```

**EX-1b ships:** `facet lens "Web"` now gathers every Chrome/Safari window from **all** workspaces into one union-tiled view; `facet lens --clear` or any `facet workspace --focus` returns to the workspace. The tree still shows both highlights (cosmetic; fixed in EX-1c).

---

## EX-1c — Exclusive highlight + CLI/config/docs (view + surface)

**Files:**
- Modify: `Sources/FacetApp/Controller.swift` (`apply` — suppress workspace active-highlight while a lens is active; the "active section" is the lens)
- Modify: `Sources/FacetApp/Controller+CLIDispatch.swift` (`setActiveLens` — already wires; ensure clear path re-tiles)
- Modify: `Sources/FacetViewTree/SidebarView.swift` (one lit header: when `activeLens != nil`, no workspace header is `hot`)
- Modify: `config.toml` (lens `layout` key + cross-workspace exclusive wording)
- Modify: `docs/glossary.md` (`### lens` = cross-workspace exclusive; `### active section` new term)
- Modify: `README.md` / `README.ja.md`, `docs/architecture.md`
- Regenerate: `config.schema.json` (`facet --emit-schema` — Spec doc changed → required)

**Interfaces:**
- Consumes: `backend.currentSectionLens()` ([NativeAdapter.swift:288](../../../Sources/FacetAdapterNative/NativeAdapter.swift#L288)), `Controller.currentActiveLens` ([Controller.swift:114](../../../Sources/FacetApp/Controller.swift#L114)).
- Produces: tree/grid/rail show exactly one active-section highlight.

- [ ] **Step 1:** In [`SidebarView.update(sections:…)`](../../../Sources/FacetViewTree/SidebarView.swift#L513) header-active logic (~line 569-573): a workspace header is `hot` only when `activeLens == nil && headerActive(ws)`. When a lens is active, only the matching lens header is `hot`. (One lit header total.)
- [ ] **Step 2:** Grid/rail: while a lens is active, no workspace cell is drawn `isActive` (cosmetic — full lens-cell rendering is EX-2). Pass `activeLens != nil` down so the active-cell ring is suppressed; keep `!isLensParked` thumbnail filtering (already cross-workspace via the snapshot flag).
- [ ] **Step 3:** Update `config.toml`: under the `type = "lens"` doc block, document `layout = "spiral"` (stateless union layout; bsp/stack clamp); rewrite the activation paragraph for cross-workspace exclusive ("parks every non-matching window in **every** workspace; switching a workspace clears the lens").
- [ ] **Step 4:** `docs/glossary.md`: `### lens` → cross-workspace exclusive filter; add `### active section`. `docs/architecture.md`: the unification table (workspace=stateful / lens=union). README EN+JA: a `facet lens` example showing cross-workspace gather.
- [ ] **Step 5:** Regenerate schema: `swift run facet --emit-schema > config.schema.json` (only if the config Spec types changed; the lens-layout key may need a Spec entry — verify with `git diff config.schema.json`).
- [ ] **Step 6:** `swift build`. Commit.
```bash
git commit -am ":lipstick: feat(view): [ex1] one active-section highlight; lens layout config + docs"
```

- [ ] **Step 7: HOST VERIFY (トミー操作・合成入力NG).** Build + run; トミー opens Chrome windows on WS1 and WS2; agent runs `facet lens "Web"`; confirm in `/tmp/facet.log` and on screen: windows from **both** workspaces gather into one union, non-Web windows park (sliver), tree lights only the lens header; `facet lens --clear` restores all to their home workspaces. Provide exact commands + expected `parked=N`/`restored=N` log lines ([[verification-commands-explicit]], [[claude-driven-testing-protocol]]).

---

# EX-2 — Three views = one section list (roadmap-grade; re-plan in detail after EX-1)

**Deliverable:** grid/rail render `type="lens"` sections as their own cells (best-effort content: SCK thumbnail → app icon → blank, decision ⑨); a click on any window or cell **activates the section it belongs to + focuses** (decision ③); one unified active-section highlight across all three views.

**Key files / changes:**
- `Sources/FacetCore/OverviewProjection.swift` / `OverviewModels.swift` — emit lens sections as cells (today: `.workspace` only; the "cell count INVARIANT" comment at [OverviewModels.swift:26](../../../Sources/FacetCore/OverviewModels.swift#L26) is revised — a lens is now a cell, not just an in-cell narrow).
- `GridView.swift` / `RailView.swift` — render lens cells; click → `controller.activateSection(id)`.
- `SidebarView.swift` — window-row click in a lens section activates that lens (today a click focuses; decision ③ makes click = section-select + focus, an upgrade of the [Phase 2/3 "lens窓 preview" idea that was withdrawn](../../../). The memory's withdrawn preview note is in [[facet-phase1-lens-realhide-plan]]).
- New backend/controller verb: `activateSection(id: String)` unifying workspace-focus and lens-activate (the EX-4 CLI ① system's in-process form).

**Risks:** lens-cell content best-effort (SCK can't capture parked sliver windows well — accept icon/blank fallback, decision ⑨); cell-count invariant rewrite ripples through grid/rail geometry tests.

---

# EX-3 — Orphans + symmetric DnD + new-window apply (roadmap-grade; re-plan after EX-2)

**Deliverable:** `workspace = 0 or 1` (decision ⑥); DnD = symmetric **move** for every section pair (un-apply source → apply dest, decision ⑤/⑭); new windows inherit the active section's `apply` (decision ④/⑨); 迷子 (lost-and-found) lens receptacle as explicit config (decision ⑦/⑧).

**Key files / changes:**
- `WorkspaceCatalog.swift` — `WindowSlot.workspace: Int?` (the invasive change; ~7 assignment paths flagged: adopt [+Reconcile.swift:183](../../../Sources/FacetAdapterNative/WorkspaceCatalog+Reconcile.swift#L183), move [:653](../../../Sources/FacetAdapterNative/WorkspaceCatalog.swift#L653), evacuate [:429](../../../Sources/FacetAdapterNative/WorkspaceCatalog.swift#L429), remap [:494](../../../Sources/FacetAdapterNative/WorkspaceCatalog.swift#L494), sticky re-home, scratchpad summon). A `nil` workspace = orphan (matches no workspace section).
- `ApplyResolver` — already implements un-apply/apply ([ApplyResolver.swift:133](../../../Sources/FacetCore/ApplyResolver.swift#L133)); wire the catalog DnD to call it for **all** drops (ws↔ws / ws↔lens / lens↔lens), `setWorkspace("")`/nil = leave-workspace.
- New-window adoption — instead of unconditional `activeIndex`, apply the **active section's** `apply` (decision ④). If active section is a lens with `apply: {tags:[web]}`, the new window gets tag web + no/stale workspace per the lens, guaranteed visible.
- `type="lens"` 迷子 receptacle — a section whose `match` catches orphans (e.g. `not workspace and not tag`); projection emits it (the `unassigned` type stays deprecated per decision ⑦/Q20).

**Risks:** nullable workspace is the single highest-churn change in the plan; gate behind exhaustive catalog tests before any AX wiring. Orphan invisibility (decision ⑧) is intentional — `log()` when a window becomes an orphan with no 迷子 section so it's never a silent vanish.

---

# EX-4 — CLI 2-system unification + retire `by="tag"` (roadmap-grade; re-plan after EX-3)

**Deliverable:** CLI = ① one **section-activation** verb (name selects any section: workspace or lens) + ② window-**attribute** verbs (`facet window --tag/--set-workspace/--float/…`); **delete** `[grouping] by="tag"` and the entire bitmask tag-mode path (decision ⑬); startup active = first `type="workspace"` section (decision ⑭); config template ships the 迷子 receptacle first, uncommented, marked "推奨!!" (decision ⑦); all docs/glossary/README/architecture synced; `cli-migration.md` entry.

**Key deletions (pure-removal, since EX-1..3 cover the use cases):**
- `Grouping.tag` + every `grouping == .tag` branch (15 call sites mapped — `NativeAdapter+LayoutMode.swift:18`, `+Queries.swift:257/357/613`, `+Scratchpad.swift:518`, `+Tagging.swift:175`, `NativeAdapter.swift:590/617`, `FacetConfig.swift:590/631`, `+Decode.swift:162`, `Controller+ActiveMode.swift:150`, `+CLIDispatch.swift:378`).
- `WorkspaceCatalog+Tags.swift`'s bitmask `setLens`/`LensPlan`/`tagUnionFrames` (the section-lens twins from EX-1 replace them; reconcile any still-shared helpers).
- `[[tag]]` config block + `TagModel` bitmask (tags become free-form strings on `match`/`apply`, already the section model's vocabulary).
- `LensRoute` collapses: with one grouping, `routeLens` is just section-activate + clear (the tag-only verbs / `csvInSectionName` / `tagOnlyVerb` errors disappear).
- Lift the grid/rail-in-tag-mode `exit 2` ([Main.swift:662](../../../Sources/FacetApp/Main.swift#L662)) — all three views work in the one model.

**Risks:** large deletion; do it as the last phase so the section model is proven first. Keep the unified verbs as the throughline established in EX-1 so removal is pure deletion, not a rewrite (per [[facet-phase1-lens-realhide-plan]]'s "前方互換に作る" note).

---

## Self-Review (EX-1)

**Spec coverage (decisions ①-⑭):**
- ① exactly-one-active → EX-1b.5 (switch clears lens) + EX-1c.1 (one lit header). ✅
- ⑩/⑫ layout clamp by type, lens `layout` → EX-1a + EX-1b.3/.6. ✅
- ② multi-match (window in many sections) → already true via FilterProjection; unchanged. ✅
- 横断 (cross-workspace lens, core of ①) → EX-1b.1/.2/.4. ✅
- ③ click=activate-section, ④ new-window apply, ⑤ symmetric DnD, ⑥ orphans, ⑦/⑧ 迷子, ⑨ grid/rail cells → **deferred to EX-2/EX-3** (declared, not silently dropped). ✅
- ⑬ by=tag removal, ⑭ startup-active → **EX-4** (declared). ✅
- ⑪ mark/float/sticky/master = attributes (not sections) → no change needed; they remain `apply` ops / filter fields. ✅

**Placeholder scan:** EX-1a/b/c steps carry real code or exact file:line edits. EX-2/3/4 are explicitly roadmap-grade (deliverable + files + risks) and flagged "re-plan in detail after" the prior phase lands — not placeholders, deliberate staging (the foundation each builds on is changed by its predecessor).

**Type consistency:** `LensLayout.resolve(_:globalDefault:)`, `sectionLensUnionMembers()`, `sectionLensUnionFrames(layout:in:)`, `sectionLensVisibleIDsAll(live:)`, `activeSectionLens: String?`, `lensParkedMembers: Set<WindowID>` used consistently EX-1a→EX-1c.

**Decision needing トミー confirmation (none blocking):** phase order (EX-1..4) and deferring nullable-`workspace` to EX-3 — confirmed delegated to Claude per the design memo; surfaced in chat for a sanity check before execution.
