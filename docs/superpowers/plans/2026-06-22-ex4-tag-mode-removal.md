# EX-4 — Tag-mode removal + tag-storage migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the legacy `[grouping] by="tag"` tag mode entirely (the M11-3 feature subsumed by the exclusive section model), migrate the surviving window-tag storage from a UInt64 bitmask to `Set<String>`, lift the grid/rail tag-mode `exit 2`, collapse the CLI to two systems, and pin startup = first `type="workspace"` section — the FINAL stage of the exclusive-selection model (EX-0…EX-4).

**Architecture:** EX-0…EX-3 (all shipped, main `73b3500`) built an `ActiveSection` model — exactly one section (`type="workspace"` XOR `type="lens"`) active at a time, with cross-workspace union tiling via `LensMembership` string-match predicates. The legacy "tag mode" (a UInt64-bitmask lens over a global tag vocabulary, `[grouping] by="tag"`) is now redundant: every tag-mode capability has a section-model twin (`type="lens"` + `match='tag~=X'`). EX-4 removes tag mode and re-represents the one surviving concept — **per-window tags as a free-form attribute** (used by lens `tag~=X` matching + `window --tag`) — as `Set<String>` instead of a bit in a registry.

**Tech Stack:** Swift 6, macOS 13+, 3 layers (`FacetCore` pure / `FacetAdapterNative` backend / `FacetView*`+`FacetApp` GUI). Build gate = `swift build` (CLT-local); XCTest runs CI-only (`feedback-swift-tests-only-compile-in-ci`).

## Global Constraints

- **Layer spine is non-negotiable.** `FacetCore` stays pure (CoreGraphics OK, no AppKit/AX/backend). Tag storage lives in the adapter (`WorkspaceCatalog.WindowSlot`); the `FacetCore` `Window.tags` display field is the only tag type crossing to views.
- **Breaking changes are fine** (個人開発 / no-backward-compat — `design-principles`). No deprecation stubs, no compat shims, no auto-migration tool. Pure delete.
- **Each commit must `swift build` green.** Swift won't compile a half-deleted symbol graph — order deletions callers→impl→types.
- **Tests are CI-only.** Write them defensively (CLT can't run XCTest). A Spec/schema edit MUST regenerate `config.schema.json` (`facet --emit-schema`) + sweep contradicting tests in the SAME commit (EX-3 CI lesson, ledger).
- **Config never rejects unknown keys** — it clamps to defaults (`config-default-behavior`). A leftover `[grouping]`/`[[tag]]` in a user's config is silently ignored, never a crash.
- **Commit convention:** gitmoji + Conventional (`<:gitmoji:> <type>(<scope>)<!>: <subject>`). This is a breaking refactor → `:boom: feat(...)!:` / `:fire: refactor(...)!:`.
- **No push/merge without explicit トミー go** (`pr-conventions` / `grid-view-work-style`). Host-verify is トミー-operated (synthetic input NG, fresh consent each screen-moving op).

## The decision (トミー-blessed, 2026-06-22)

`AskUserQuestion` → **"全部削除・2系統化 (推奨)"**. Drop the runtime tag/lens composition CLI built in #176/#191 entirely; the exclusive model leaves only two CLI systems.

- **Deleted:** `facet lens --add/--remove/--toggle/--all` (dynamic multi-tag union composition) + `facet tag --add/--remove/--rename` (tag-vocabulary management). No dynamic lens composition (canon ⑬ "later phase" — deferred, not built).
- **Kept (the 2 systems):** ① `facet lens NAME` / `facet lens --clear` (section activate/deactivate); ② `facet window --tag/--untag/--toggle-tag/--retag` (window attribute, ungated — always available).

## Claude-decided implementation choices (house-rule-obvious; トミー may veto at plan review)

- **`WindowSlot.tags: UInt64` → `Set<String>`** (canon "string set"; removes the 63-tag cap).
- **`Window.tags` (FacetCore display model) → `[String]` SORTED** at the overlay seam (deterministic `#tag` chip order; avoids a `Set`-iteration-order regression). `ApplyResolver`'s simulated tags stay ordered `[String]` for apply-parity.
- **`facet query --windows` `tags` field = KEEP** (load-bearing for host-verify `tags=['web']`; machine contract). Emit sorted.
- **Leftover `[grouping]`/`[[tag]]` keys = silently ignored** (house clamp rule) + repo `config.toml` template cleaned. No loud reject, no migration tool.
- **`Grouping` + `LayoutGrouping` enums = pure delete** (no `.workspace`-only stub).

## Sequencing constraints (from the codemap critic, `wf_d454538f-389`)

1. `WindowSlot.tags` UInt64→Set migration lands WITH its readers (bitmask ops fail on a Set) — that's EX-4.3, one coherent commit.
2. `Grouping` enum deletion only AFTER every `grouping == .tag` branch is gone — EX-4.2.
3. `LayoutGrouping` deletion is safe: the section-lens layout reject already uses `LensLayout.isStateless`, NOT `LayoutGrouping.isCompatible` (EX-0.3; verified `NativeAdapter+LayoutMode.swift:29` comment). All 6 `LayoutGrouping` references are `with: .tag` (verified grep) → no workspace-path dependency.
4. CLI gate-removal + verb-deletion land together (no orphaned parser branches).
5. Startup verification lands FIRST (critic #17 — a broken startup active-section hidden by tag mode would surface mid-refactor).

## File structure (what each task touches)

**DELETE outright:**
- `Sources/FacetCore/Grouping.swift` (whole file — `Grouping` enum + `LayoutGrouping`)
- `Sources/FacetCore/LensRoute.swift` (whole file — `routeLens` / `LensAction` / `LensEffect` / `LensRouteError`)
- `Sources/FacetCore/TagModel+LensFilter.swift` (whole file — bitmask→filter parity, dead path)
- `Sources/FacetCore/TagModel.swift` (whole file — UInt64 bit registry; deleted in EX-4.3 after window-attr ops switch to `Set<String>`)
- `Sources/FacetAdapterNative/WorkspaceCatalog+Tags.swift` (whole file — tag-mode grouping/lens machinery; its 4 surviving window-attribute mutators move to a new file in EX-4.2)
- **`Sources/FacetView/TagEditPanel.swift` (whole file, 35KB — the `t`-key tag-manage GUI / vocabulary editor, #191; plan-review add)** — and its `LensSpec` payload in `Backend.swift` (the DNC wire type for tag-mode lens commands; dead once `setLens` is deleted).
- `Tests/FacetCoreTests/TagModelTests.swift`, `Tests/FacetAdapterNativeTests/TagCatalogTests.swift`, `Tests/FacetAdapterNativeTests/QueryTagsLensTests.swift`, `Tests/FacetCoreTests/LensRouteTests.swift` (CI-only; deleted/rewritten with their code — see EX-4.4 Step 4 for the exact pre-list + the survivors that must stay)

**CREATE:**
- `Sources/FacetAdapterNative/WorkspaceCatalog+WindowTags.swift` (the 4 surviving Set-based window-attribute mutators: `addTagToWindow` / `removeTagFromWindow` / `toggleTagOnWindow` / `retagWindow`)
- `Tests/FacetAdapterNativeTests/WindowTagsTests.swift` (Set-based attribute mutation parity)
- `Tests/FacetAdapterNativeTests/StartupActiveSectionTests.swift` (multi-section startup invariant) — or extend `SectionLensCatalogTests`

**MODIFY (delete tag branches / lift gates / migrate type):**
- `Sources/FacetCore/FacetConfig.swift` (`grouping`/`tagDefs` fields; `effectiveGrouping`/`effectiveTagModel`; `fatalConfigErrors` tag block; `effectiveMacDesktopSectionConfigs` tag clamp)
- `Sources/FacetCore/FacetConfig+Decode.swift` (`tagDefs` parse + tag-mode warning)
- `Sources/FacetCore/FacetConfig+Spec.swift` (`by` enum + `[[tag]]` shape)
- `Sources/FacetCore/Models.swift` (`Window.tags` type/doc)
- `Sources/FacetCore/ApplyResolver.swift` (`ApplyPlanWindowFields.tags` simulation)
- `Sources/FacetCore/Backend.swift` (`setLens` protocol method delete; window-tag method signatures)
- `Sources/FacetAdapterNative/WorkspaceCatalog.swift` (`WindowSlot.tags` type; `grouping`/`tagModel`/`lens`/`tagLayoutMode`/`effectiveTagLayout` state; `snapshot()` tag branch :789; `makeWindow` overlay :897-899)
- `Sources/FacetAdapterNative/NativeAdapter.swift` (`setLens` :639-689; tag-union comment :669)
- `Sources/FacetAdapterNative/NativeAdapter+Tagging.swift` (lift `tagVocabReady` gate; drop park/restore from settle; delete `addTag`/`removeTag`/`renameTag` vocab verbs)
- `Sources/FacetAdapterNative/NativeAdapter+Queries.swift` (tag seed :289; `parkOutOfLensWindows` :389; overlay :490)
- `Sources/FacetAdapterNative/NativeAdapter+QueryCommand.swift` (`currentLens` :49; overlay :151,168)
- `Sources/FacetAdapterNative/NativeAdapter+Scratchpad.swift` (applyLayout tag branch :532)
- `Sources/FacetAdapterNative/NativeAdapter+LayoutMode.swift` (setLayoutMode tag branch :44-61)
- `Sources/FacetAdapterNative/NativeAdapter+Slide.swift` (targetFrames tag branch :65)
- `Sources/FacetApp/Main.swift` (help text; `requireGrouping` :424; grid/rail exit-2 :656-667; `facet tag` dispatch :545)
- `Sources/FacetApp/FacetApp+ClientCommands.swift` (`runLensCommand` composition branches :110-208; `runTagCommand` :238-271; `runWindowCommand` gate :389)
- `Sources/FacetApp/Controller+CLIDispatch.swift` (tag-add/remove/rename DNC :194-225; `lens-section:`→`lens:` rename :65-81)
- `Sources/FacetCore/Layout.swift` (**plan-review must-fix**: delete `supportedGroupings: Set<Grouping>` protocol requirement :68 + default extension :79 — its only consumer is `LayoutGrouping`, deleted with it; no engine overrides, verified grep)
- **View-layer tag-mode surface (plan-review add — bigger than first mapped):**
  - `Sources/FacetView/ViewContextMenu.swift` (`tagMode` param + `LayoutGrouping…with: .tag` filter :112-123,214-258)
  - `Sources/FacetViewTree/SidebarView+Menus.swift` (`tagModeActive` :40,74,98 + `LayoutGrouping…with:.tag` :52)
  - `Sources/FacetViewTree/SidebarView.swift` (the `tagModeActive` flag :90 + `update(tagMode:)` param :291-307 + 9 branch sites — flat-list/uppercase/chip-count/reset; collapse every `tagModeActive ? X : Y` to the workspace branch `Y`)
  - `Sources/FacetViewTree/SidebarView+Drag.swift` (:102,374), `SidebarView+KbNav.swift` (:134), `SidebarView+Draw.swift` (:139,146) — `tagModeActive` branch removal
  - `Sources/FacetApp/Controller.swift` (`sidebarView.update(… tagMode: config.effectiveGrouping == .tag)` :1038 — drop the arg)
  - `Sources/FacetApp/Controller+ActiveMode.swift` (`t`-key `enterTagManage` case :151; `tagManage: config.effectiveGrouping == .tag` menu param :200; `enterTagManage`/`openTagEditor`/tag-manage undo :342-392)
  - `Sources/FacetViewTree/TreeController.swift` + `Sources/FacetView/PopupMenu.swift` + `Sources/FacetView/PopupGeometry.swift` (TagEdit / tag-manage invocations — delete with `TagEditPanel.swift`)
- docs: `config.toml`, `config.schema.json`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md`

**VERIFY-ONLY (must NOT regress — accidental-deletion risk):**
- `WorkspaceCatalog+SectionLens.swift` (applySectionLens, sectionLensUnionMembers/Frames, lensParkedMembers) — the whole EX-0…3 section machinery
- `NativeAdapter.swift:508` setActive section-lens gate (`activeSectionLens != nil && n == activeIndex`)
- `NativeAdapter+Queries.swift:154,423-433` `activeSectionLensApplyTags` (new-window inheritance, EX-3.3)
- `LensMembership.matches` / `FilterProjection` (tag~=X is STRING-based already — clean through migration)
- `ApplyResolver.inverse` (removeTag-only — strings, unchanged)
- `DesktopSection` `ApplyOp.addTag/removeTag` TOML parse (window-attribute apply — survives)
- marks (`markFocusedWindow`/`focusMark`/`unmark`) — window state, NOT tags

---

## Task EX-4.1: startup = first `type="workspace"` section (verify + harden)

Critic #17: verify startup BEFORE deleting tag mode. The startup-reader found canon ⑭ is ALREADY satisfied structurally (`WorkspaceCatalog.activeIndex` hardcoded `1`, no persistence). This task PINS that with a multi-section test and verifies the config filter, so any later regression is caught.

**Files:**
- Read/verify: `Sources/FacetCore/FacetConfig.swift` (`effectiveWorkspaceList` + `effectiveMacDesktopSectionConfigs`), `Sources/FacetAdapterNative/WorkspaceCatalog.swift:135,367,394,411`
- Test: `Tests/FacetAdapterNativeTests/StartupActiveSectionTests.swift` (new) or extend `SectionLensCatalogTests.swift:28`

**Interfaces:**
- Consumes: `WorkspaceCatalog.activeSection` (`= activeSectionLens.map(.lens) ?? .workspace(activeIndex)`), `WorkspaceCatalog.seed(configs:)`, `FacetConfig.effectiveWorkspaceList(forMacDesktopOrdinal:)`.
- Produces: a pinned guarantee that a catalog seeded from a config whose sections are `[lens, workspace "A", workspace "B"]` has `activeSection == .workspace(1)` pointing at the FIRST `type="workspace"` section ("A"), in section-array order.

- [ ] **Step 1: Read `FacetConfig.effectiveWorkspaceList` + `effectiveMacDesktopSectionConfigs`** and confirm: (a) it returns ONLY `type="workspace"` sections (drops `type="lens"`), (b) preserves section-array order (not raw config ordinal). Note the exact symbol names + line numbers in the task notes.

- [ ] **Step 2: Write the failing test** — seed a catalog from a config whose section order is lens-first, then two workspaces:

```swift
func testStartupActiveIsFirstWorkspaceSectionAcrossMultipleSections() {
    // sections in config order: a lens, then workspace "A", then workspace "B".
    let cfg = FacetConfig(/* desktop.1 sections = [lens "Web" match:"tag~=web", ws "A", ws "B"] */)
    var c = WorkspaceCatalog()
    c.seed(configs: cfg.effectiveWorkspaceList(forMacDesktopOrdinal: 1))
    // canon ⑭: startup active = FIRST type=workspace section, never the lens.
    XCTAssertEqual(c.activeSection, .workspace(1))
    XCTAssertEqual(c.workspaceNames.first, "A")   // first WORKSPACE section, not the lens
    XCTAssertNil(c.activeSectionLens)              // never a lens at startup
}

// Edge case (plan-review, codemap open-Q #5): a desktop config with ONLY
// type=lens sections (no type=workspace). seed()'s fallback = one unnamed
// workspace, so activeSection stays .workspace(1) — never lens, never crash.
func testStartupWithNoWorkspaceSectionFallsBackToOneWorkspace() {
    let cfg = FacetConfig(/* desktop.1 sections = [lens "Web" match:"tag~=web"] only */)
    var c = WorkspaceCatalog()
    c.seed(configs: cfg.effectiveWorkspaceList(forMacDesktopOrdinal: 1))  // → [] → fallback [""]
    XCTAssertEqual(c.activeSection, .workspace(1))   // the lone fallback ws
    XCTAssertNil(c.activeSectionLens)
}
```

- [ ] **Step 3: Run the test (CI-only — locally confirm it COMPILES via `swift build`)**. Run: `swift build`. Expected: GREEN (test target compiles). If `effectiveWorkspaceList` already filters+orders correctly, the assertion is satisfied at CI; if NOT, fix the filter in `FacetConfig` (filter `type == .workspace`, keep section-array order) — that fix becomes part of this commit.

- [ ] **Step 4: If a fix was needed, re-confirm `swift build` green.** Otherwise skip.

- [ ] **Step 5: Commit.**

```bash
git checkout -b feat/ex4-tag-mode-removal
git add Tests/FacetAdapterNativeTests/StartupActiveSectionTests.swift Sources/FacetCore/FacetConfig.swift
git commit -m ":white_check_mark: test(catalog): pin startup active = first type=workspace section (EX-4.1)"
```

---

## Task EX-4.2: delete the by=tag GROUPING machinery (breaking)

Delete tag-mode grouping/lens everywhere, KEEPING `TagModel` + `WindowSlot.tags: UInt64` as the window-attribute store (auto-vivify bit registry) — that storage migrates in EX-4.3. After this task: `catalog.grouping`/`lens`/`tagLayoutMode` gone, no `grouping == .tag` branch anywhere, `facet tag` + `lens --add/...` gone, `window --tag` ungated + a pure attribute setter (no park/restore — section-lens reconcile owns visibility), grid/rail exit-2 gone. Order: **delete callers → delete impl → delete types**, each sub-step `swift build` green (commit at green points; 2–3 commits acceptable).

**Files:** see "MODIFY/DELETE" lists above (the FacetCore types, the adapter machinery, the CLI surface).

**Interfaces:**
- Consumes: `catalog.activeSectionLens`, `applySectionLensReconcile()`/`applySectionLens(...)` (EX-0 section park/restore), `activeDisplayRect()`, `applyLayout(workspace:rect:)`.
- Produces: `WorkspaceCatalog` with NO `grouping`/`lens`/`tagLayoutMode`/`tagModel`-seeding-of-mode; the 4 window-attribute mutators relocated to `WorkspaceCatalog+WindowTags.swift` (still UInt64, still via `tagModel.add`/`bit`); `NativeAdapter` window-tag verbs ungated + reconcile-driven.

### Step group A — delete the CLI callers (build-green commit)

- [ ] **A1: `FacetApp/FacetApp+ClientCommands.swift`** — in `runLensCommand` (≈:110-208) delete the `--add/--remove/--toggle/--all` branches; keep positional `NAME` (activate section) + `--clear`. Delete `runTagCommand` (≈:238-271) entirely. In `runWindowCommand` (≈:277-416) delete the `requireGrouping(.tag)` gate (≈:389) so `--tag/--untag/--toggle-tag/--retag` always parse.
- [ ] **A2: `FacetApp/Main.swift`** — delete `requireGrouping` (:424) + all callers; delete the `tag` subcommand dispatch (:545); delete the grid/rail `requireGrouping(.workspace)` exit-2 (:656-667); rewrite `printHelp` (:94-207) to drop the `tag`/composition lines + tag-mode caveats and reflect the 2-system surface.
- [ ] **A3: `FacetApp/Controller+CLIDispatch.swift`** — delete the `tag-add`/`tag-remove`/`tag-rename` DNC cases (:194-225); rename the DNC `lens-section:` → `lens:` and delete the tag-mode `lens:` path (:65-81). (Single wire-protocol rename — no compat alias, no old clients exist.)
- [ ] **A4: View-layer tag-mode removal (plan-review — caller layer, must precede the backend deletion in B).** This is bigger than the layout-picker filter; the `tagModeActive` flag + the `t`-key tag-manage GUI thread through the tree view and are all callers of tag-mode state/backend:
  - DELETE `Sources/FacetView/TagEditPanel.swift` (whole file, the vocabulary editor) + its invocations: `Controller+ActiveMode.swift` `enterTagManage`/`openTagEditor`/the `t`-key case (:151) + the tag-manage undo branch (:342-392); `TreeController.swift` + `PopupMenu.swift` + `PopupGeometry.swift` TagEdit references. (It calls the `facet tag` backend verbs deleted in B1 — delete the caller first.)
  - `Controller.swift:1038` — drop the `tagMode:` arg from `sidebarView.update(...)`. `Controller+ActiveMode.swift:200` — delete the `tagManage: config.effectiveGrouping == .tag` menu param + `onTagManage`.
  - `SidebarView.swift` — delete the `tagModeActive` stored flag (:90) + the `tagMode:` param on `update(...)` (:291-307) + collapse all 9 `tagModeActive ? X : Y` branch sites to the workspace branch `Y` (flat-list header, uppercase names :376, chip count :378, reset :534, signature :328,443). `SidebarView+Drag.swift` (:102,374), `SidebarView+KbNav.swift` (:134), `SidebarView+Draw.swift` (:139,146) — same collapse.
  - `ViewContextMenu.swift` — delete the `tagMode` param (:112,214) + the `LayoutGrouping.isCompatible(..., with: .tag)` layout-picker filter (:118-123) + the `if tagMode` branch (:258). `SidebarView+Menus.swift` — delete the `LayoutGrouping…with:.tag` filter (:52) + the `tagModeActive` menu branches (:40,74,98). The layout picker now offers the workspace-compatible set for a workspace section (unconditional) / `LensLayout`-stateless set for a lens section (already handled by EX-0.3).
  - VERIFY: `grep -rn "tagModeActive\|tagMode\|TagEdit\|enterTagManage\|tagManage" Sources/FacetView* Sources/FacetApp/` → zero (all view tag-mode surface gone). `config.effectiveGrouping` is still referenced ONLY inside FacetConfig until C4.
- [ ] **A5: `swift build` green** (CLI + view no longer reference composition/vocab verbs or `tagModeActive`/`TagEditPanel`; backend `setLens`/vocab methods + `catalog.lensOnly/…` are now DEAD CODE but still present and compile — deleted in B2/B3, caller-before-callee). Commit:

```bash
git commit -am ":fire: refactor(cli)!: drop facet tag + lens composition verbs + tag-manage GUI (TagEditPanel) + view tagMode surface (EX-4.2a)"
```

### Step group B — delete the adapter tag-mode machinery (build-green commit)

- [ ] **B1: `NativeAdapter+Tagging.swift`** — delete `addTag(_:)` / `removeTag(_:)` / `renameTag(_:to:)` (vocab verbs, :196-251). In `tagVocabReady` (:181) drop `catalog.grouping == .tag`, keep `config.isMacDesktopManaged(...)`; rename to e.g. `windowTagReady`. In `settleWindowRetag` (:135-146) DELETE the `applyHide(toPark:/toRestore:)` park/restore block — instead call `applySectionLensReconcile()` (re-evaluate the active lens membership for the changed tag set) then `applyLayout(workspace:rect:)` + `refreshNeeded`. The catalog mutators still return `RetagVisibility`; ignore it here (reconcile owns visibility) — or change their return in B3.
- [ ] **B2: `NativeAdapter.swift`** — delete `setLens` (:639-689) + the tag-union comment (:669). `NativeAdapter+Scratchpad.swift` delete the `if catalog.grouping == .tag { applyFrames(tagUnionFrames…) }` branch (:532). `NativeAdapter+Slide.swift` delete the `if catalog.grouping == .tag { return tagUnionFrames }` branch (:65). `NativeAdapter+LayoutMode.swift` delete the whole `if catalog.grouping == .tag {…}` block (:44-61). `NativeAdapter+Queries.swift` delete the tag seed (:289 `if config.effectiveGrouping == .tag { seedTags(…) }`) + `parkOutOfLensWindows` (:389, tag-gated → delete or no-op). `NativeAdapter+QueryCommand.swift` delete `currentLens()` (:49) and its DNC/query wiring.
- [ ] **B3: split `WorkspaceCatalog+Tags.swift`** — CREATE `WorkspaceCatalog+WindowTags.swift` holding ONLY the surviving window-attribute mutators (`addTagToWindow` / `removeTagFromWindow` / `toggleTagOnWindow` / `retagWindow` / `addTagName` / `RetagVisibility` / `RetagOutcome` / `retagVisibility` helper) — UNCHANGED (still UInt64 + `tagModel`, migrated in EX-4.3). DELETE `WorkspaceCatalog+Tags.swift` (seedTags, tagsForNewWindow, visibleNonFloatingMembers, tagUnionFrames, tagSnapshot, lens resolvers `lensOnly/Added/Removed/Toggled/lensMaskStrict/lensAll`, removeTagName, renameTagName, setLens, LensPlan). In `WorkspaceCatalog.swift` delete state `grouping` (:154), `lens` (:162), `tagLayoutMode` (:196), `effectiveTagLayout` (:200) and the `snapshot()` tag branch (`if grouping == .tag { return tagSnapshot() }`, :789) — `snapshot()` always returns the workspace snapshot now. KEEP `tagModel` (:158) until EX-4.3 (window-attr ops still use it).
- [ ] **B4: `Backend.swift`** — delete the `setLens(_ spec: LensSpec)` protocol method (:216) + the `LensSpec` enum + its `parse(_:)` (:100-130 — the DNC wire payload; dead once `setLens` and the `lens --add/...` DNC are gone). Gate: `grep -rn "LensSpec\|setLens" Sources/ Tests/` → zero. Keep window-tag protocol methods + `activateSection`. Also delete `setLens` from any stub backend (`DummyBackend`).
- [ ] **B5: `swift build` green.** Commit:

```bash
git commit -am ":fire: refactor(adapter)!: delete tag-mode lens/grouping machinery; window --tag becomes a pure reconcile-driven attribute (EX-4.2b)"
```

### Step group C — delete the FacetCore types (build-green commit)

- [ ] **C1: `FacetCore/Grouping.swift` + `FacetCore/Layout.swift`** — **(plan-review must-fix)** BEFORE deleting `Grouping.swift`, delete the `supportedGroupings` protocol requirement (`Layout.swift:68` `var supportedGroupings: Set<Grouping> { get }`) AND its default extension (`Layout.swift:79` `public var supportedGroupings: Set<Grouping> { [.workspace, .tag] }`) — its ONLY consumer is `LayoutGrouping.supported` (`Grouping.swift:51`), being deleted; no engine overrides it (verified grep). THEN DELETE `Grouping.swift` (`Grouping` enum + `LayoutGrouping`). Gate: `grep -rn "Grouping\|supportedGroupings" Sources/` → zero non-comment hits (the surviving `ActiveSection`/`FilterProjection`/`OverviewModels` contain the unrelated word "lens"/"tag", not `Grouping`).
- [ ] **C2: `FacetCore/LensRoute.swift`** — Gate FIRST: `grep -rn "routeLens\|LensAction\|LensEffect\|LensRouteError\|LensRoute" Sources/ Tests/` → zero (the A1 CLI rewrite removed the `routeLens` call). THEN DELETE the file.
- [ ] **C3: `FacetCore/TagModel+LensFilter.swift`** — DELETE the file (`lensFilter`, bitmask→filter parity, dead).
- [ ] **C4: `FacetConfig.swift`** — delete `grouping` (:186) + `tagDefs` (:190) raw fields; `effectiveGrouping` (:599) + `effectiveTagModel` (:608); the `fatalConfigErrors` tag block (:631-654, the `guard effectiveGrouping == .tag` + `LayoutGrouping`/`[[tag]]`/grid checks). **`effectiveMacDesktopSectionConfigs` (:589) — change `effectiveGrouping == .tag ? [:] : macDesktopSectionConfigs` to just `return macDesktopSectionConfigs`** (sections are never clamped away now). **VERIFY `isSectionModelActive(ordinal:)` (:545) still reads correctly** — it gates on a non-empty `effectiveMacDesktopSectionConfigs`, so post-change it returns `true` whenever any section is configured (the desired behavior; was previously force-false under `.tag`). `FacetConfig+Decode.swift` delete `tagDefs` parse (:155) + the tag-mode-ignores-sections warning (:159-167). `FacetConfig+Spec.swift` delete the `by` field (:61) + the `[[tag]]` shape.
- [ ] **C5: `swift build` green.** Confirm `grep -rn "grouping\|TagModel\|LensRoute\|LayoutGrouping\|tagDefs\|\.tag\b" Sources/FacetCore/` returns only intentional survivors (Window.tags, ApplyOp.addTag, tag~= filter field). Commit:

```bash
git commit -am ":fire: refactor(core)!: delete Grouping/LayoutGrouping/LensRoute/TagModel+LensFilter + [grouping]/[[tag]] config (EX-4.2c)"
```

---

## Task EX-4.3: migrate tag storage UInt64 → `Set<String>` (delete `TagModel`)

Now the only `TagModel`/UInt64 users are the 4 window-attribute mutators + the `makeWindow`/query overlay + `ApplyPlanWindowFields`. Migrate `WindowSlot.tags` to `Set<String>`, delete `TagModel`, and simplify the mutators (a `Set.insert` IS auto-vivify; no bits, no floor, no `RetagVisibility` — reconcile owns visibility).

**Files:**
- `Sources/FacetAdapterNative/WorkspaceCatalog.swift` (`WindowSlot.tags` :61 + init :62 + doc :53-61; `makeWindow` overlay :897-899; all `tags: slot.tags` re-creation sites carry forward unchanged)
- `Sources/FacetAdapterNative/WorkspaceCatalog+WindowTags.swift` (the 4 mutators, created in B3 — rewrite to Set ops)
- `Sources/FacetAdapterNative/NativeAdapter+Tagging.swift` (mutator return-type/wiring)
- `Sources/FacetAdapterNative/NativeAdapter+QueryCommand.swift` (overlay :151,168) + `NativeAdapter+Queries.swift` (overlay :490, `withTags`)
- `Sources/FacetCore/Models.swift` (`Window.tags` — keep `[String]`, sorted at the seam; update doc)
- `Sources/FacetCore/ApplyResolver.swift` (`ApplyPlanWindowFields.tags` :232-287 — stays ordered `[String]`)
- DELETE `Sources/FacetCore/TagModel.swift` + `Tests/FacetCoreTests/TagModelTests.swift`
- Test: `Tests/FacetAdapterNativeTests/WindowTagsTests.swift` (new); update/delete `TagCatalogTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `WindowSlot.tags: Set<String>` (default `[]`); `addTagToWindow(_:name:)`/`removeTagFromWindow(_:name:)`/`toggleTagOnWindow(_:name:)` returning `Bool` (mutated? — no `RetagVisibility`); `retagWindow(_:old:new:)` returning a small `Bool`/`enum`; `makeWindow` overlay = `populateTags ? (windowMap[w.id]?.tags).map { $0.sorted() } ?? [] : []`.

**Test infrastructure (plan-review):** define the `seededCatalog` helper (mirror the existing `seededCatalog(_:)` in `SectionLensCatalogTests`/`WorkspaceCatalogTests` — confirm its exact shape there and reuse it). It must seed N workspaces AND register one tracked window so tag mutators have a target:

```swift
private func seededCatalog(_ n: Int) -> WorkspaceCatalog {
    var c = WorkspaceCatalog()
    c.seed(configs: (1...n).map { (index: $0, config: WorkspaceConfig(name: "ws\($0)")) })
    c.windowMap[WindowID(serverID: 10)] = WindowSlot(workspace: 1, pid: 1234, tags: [])
    return c
}
```
(If `seededCatalog` already exists in the test target, extend it to register the test window rather than redefining — avoid a duplicate-symbol clash. Verify `WorkspaceConfig`'s exact init label before use.)

- [ ] **Step 1: Write the failing test** (`WindowTagsTests.swift`):

```swift
func testWindowTagsAreAFreeFormStringSet() {
    var c = seededCatalog(1)                 // one workspace, one tracked window id=10
    XCTAssertTrue(c.addTagToWindow(WindowID(serverID: 10), name: "web"))
    XCTAssertTrue(c.addTagToWindow(WindowID(serverID: 10), name: "code"))
    XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["web", "code"])  // Set<String>, no cap, no floor
    XCTAssertTrue(c.removeTagFromWindow(WindowID(serverID: 10), name: "web"))
    XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["code"])
    XCTAssertTrue(c.toggleTagOnWindow(WindowID(serverID: 10), name: "web"))     // re-adds
    XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["web", "code"])
}
func testNewTagNameAutoVivifiesWithNoVocabulary() {
    var c = seededCatalog(1)
    XCTAssertTrue(c.addTagToWindow(WindowID(serverID: 10), name: "brand-new-tag"))  // no TagModel, no 63-cap
    XCTAssertEqual(c.windowMap[WindowID(serverID: 10)]?.tags, ["brand-new-tag"])
}
```

- [ ] **Step 2: `swift build`** — expect FAIL (`addTagToWindow` still returns `RetagVisibility?`, `tags` still `UInt64`).

- [ ] **Step 3: Migrate `WindowSlot`** (`WorkspaceCatalog.swift:53-66`):

```swift
/// Free-form per-window tag set (EX-4). Used by lens `match='tag~=X'`
/// + `facet window --tag/--untag/--toggle-tag/--retag`. Session-only
/// (never persisted); empty until the user tags the window. Every
/// `WindowSlot` re-creation carries it forward (a Set copies trivially).
var tags: Set<String>
init(workspace: Int?, pid: Int, tags: Set<String> = []) {
    self.workspace = workspace
    self.pid = pid
    self.tags = tags
}
```

- [ ] **Step 4: Rewrite the 4 mutators** (`WorkspaceCatalog+WindowTags.swift`) to Set ops — no bit, no floor, no `RetagVisibility`/`RetagOutcome`/`TagModel`:

```swift
@discardableResult mutating func addTagToWindow(_ id: WindowID, name: String) -> Bool {
    guard var slot = windowMap[id] else { return false }
    slot.tags.insert(name); windowMap[id] = slot; return true
}
@discardableResult mutating func removeTagFromWindow(_ id: WindowID, name: String) -> Bool {
    guard var slot = windowMap[id], slot.tags.contains(name) else { return false }
    slot.tags.remove(name); windowMap[id] = slot; return true
}
@discardableResult mutating func toggleTagOnWindow(_ id: WindowID, name: String) -> Bool {
    guard var slot = windowMap[id] else { return false }
    if slot.tags.contains(name) { slot.tags.remove(name) } else { slot.tags.insert(name) }
    windowMap[id] = slot; return true
}
/// `facet window --retag OLD NEW` (#228): replace OLD with NEW (a no-op
/// on OLD if absent = a bare add of NEW). Returns false only if untracked.
@discardableResult mutating func retagWindow(_ id: WindowID, old: String, new: String) -> Bool {
    guard var slot = windowMap[id] else { return false }
    slot.tags.remove(old); slot.tags.insert(new); windowMap[id] = slot; return true
}
```

- [ ] **Step 5: Rewire `NativeAdapter+Tagging.swift`** — the `applyWindowRetag`/`retagFocusedWindow` handlers now take a `Bool`-returning mutator (no `RetagVisibility`). `settleWindowRetag` becomes: mutate → **re-evaluate the active section-lens membership for the changed tag set** → retile → repaint, with NO manual `applyHide(toPark:/toRestore:)`. **Confirm the actual EX-0 reconcile entry-point's signature before wiring** (`grep -n "func applySectionLensReconcile" Sources/FacetAdapterNative/` — it may take `live:`/`rect:`; feed the current window enumeration + `activeDisplayRect()` exactly as the existing reconcile callers do). New shape:

```swift
private func settleWindowRetag(_ id: WindowID, changed: Bool, logDetail: String) {
    guard changed else { Log.debug("native: \(logDetail) [unchanged]"); return }
    applySectionLensReconcile(/* live + rect per its real signature */)  // active lens re-parks/restores
    applyLayout(workspace: catalog.activeIndex, rect: activeDisplayRect())
    Log.debug("native: \(logDetail)")
    eventContinuation.yield(.refreshNeeded)
}
```

  Map `retagWindow`/mutator `false` → the existing no-window error path. (Auto-vivify + vocab-full are no longer reject paths — `Set.insert` always succeeds for a tracked window; `--untag` of an absent tag returns `false` = "not present", surfaced as the prior `--untag` reject.) Drop the now-unused `RetagOutcome`/`WindowRetagResult` mapping if the only distinction left is no-window.

- [ ] **Step 6: Migrate the overlay seams** — `makeWindow` (`WorkspaceCatalog.swift:897-899`):

```swift
tags: populateTags ? (windowMap[w.id]?.tags.sorted() ?? []) : [],
```

`NativeAdapter+QueryCommand.swift:151,168` and `NativeAdapter+Queries.swift:490` (`withTags`): replace `cat.tagModel.names(in: slot.tags)` with `slot.tags.sorted()`.

- [ ] **Step 7: `ApplyResolver.swift` (`ApplyPlanWindowFields.tags`, :232-287)** — keep the simulated tags as ordered `[String]` applying `addTag`/`removeTag` ops; the post-orphan/section match invariant (EX-3) is unaffected (it reads names, never bits). Verify the apply-simulate compiles against `Window.tags: [String]` (unchanged FacetCore type).

- [ ] **Step 8: DELETE `TagModel.swift` + `TagModelTests.swift`.** `grep -rn "TagModel" Sources/ Tests/` → zero. Update/delete `TagCatalogTests.swift` (rewrite the surviving window-tag cases into `WindowTagsTests.swift`, delete the bit/lens/vocab cases). **Query-tags semantics (plan-review):** `facet query --windows` KEEPS the `tags` field, now emitting `slot.tags.sorted()` — session-only/volatile (empty until the user tags a window; no config seed, no persistence). Add `testQueryTagsSortedAndSessionOnly` if a query-test target exists; note "live only, not persisted" in the schema/docs (EX-4.4). **Run-the-survivors verification (plan-review):** confirm the section-model + apply tests still pass post-migration — `ApplyResolverTests` (esp. `inverse` + `removeTag` parity), `FilterProjectionTests` / `FacetFilterEvalTests` / `FacetFilterParserTests` (`tag~=X` grammar), `NewWindowInheritTests` (section apply addTag inheritance), `SectionLensGatherTests`. These must remain INTACT (they exercise the surviving string-tag path, not the deleted bitmask) — do not delete them.

- [ ] **Step 9: `swift build` green** + the new test compiles. Commit:

```bash
git commit -am ":boom: refactor(adapter)!: migrate window tags UInt64 bitmask → Set<String>; delete TagModel (EX-4.3)"
```

---

## Task EX-4.4: docs / config / schema / glossary / README + stale-test sweep + schema regen

EX-3 CI lesson: a Spec edit MUST regenerate `config.schema.json` + sweep contradicting tests in the SAME commit.

**Files:** `config.toml`, `config.schema.json`, `docs/glossary.md`, `docs/architecture.md`, `README.md`, `README.ja.md`, any `ConfigSchemaDriftTests`/`WindowFieldsFallbackTests`/`FacetConfigTests` asserting `[grouping]`/`[[tag]]`.

- [ ] **Step 1: `config.toml` (repo root)** — delete the `[grouping]` block + every `[[tag]]` table + any `by=tag` sample/commentary. Confirm the surviving template is workspace/section-only.
- [ ] **Step 2: Regenerate the schema** — `swift run facet --emit-schema > config.schema.json` (or the project's emit path). Confirm `[grouping]`/`[[tag]]`/`by` are gone from the JSON.
- [ ] **Step 3: `docs/glossary.md`** — delete `[grouping] by=tag` / tag-mode / `TagModel` / `lens` bitmask entries; ensure `lens`/`active section`/`tag` (as a window attribute) read correctly under the section model. `docs/architecture.md` — drop the by=tag grouping from any two-machineries / grouping table. `README.md` + `README.ja.md` — remove tag-mode + `facet tag` + `lens --add/...` from the CLI surface; keep them bilingually in sync (`readme-bilingual`).
- [ ] **Step 4: Stale-test sweep (plan-review — explicit pre-list).** DELETE entire files: `TagModelTests.swift`, `QueryTagsLensTests.swift`, `LensRouteTests.swift` (if present). REWRITE: `TagCatalogTests.swift` → fold the surviving window-tag cases into `WindowTagsTests.swift`, delete the bit/lens/vocab cases. UPDATE: `ConfigSchemaDriftTests` (compare against the freshly emitted `config.schema.json`), `FacetConfigTests`/`WindowFieldsFallbackTests` (any `effectiveGrouping`/`[[tag]]`/`by=tag` assertion). KEEP INTACT (survivors — do NOT touch): `NewWindowInheritTests`, `SectionLensGatherTests`, `FilterProjectionTests`, `FacetFilterEvalTests`/`FacetFilterParserTests`, `ApplyResolverTests`, `OrphanWorkspaceTests`, the EX-1/2/3 section tests. Then the **final precise survivor-aware grep gate** — these must be ZERO across `Sources/`:

```sh
grep -rnE "\bGrouping\b|supportedGroupings|\bTagModel\b|by=tag|by *= *\"tag\"|\[\[tag\]\]|tagMode|TagEdit|enterTagManage|tagManage|\bsetLens\b|LensRoute|LensSpec|tagDefs|parkOutOfLens|tagUnion|tagSnapshot|seedTags|effectiveGrouping|effectiveTagModel|tagLayoutMode|visibleNonFloatingMembers" Sources/
```

  (The SURVIVORS that legitimately contain "lens"/"tag" substrings — `activeSectionLens`, `sectionLens*`, `LensMembership`, `LensLayout`, `Window.tags`, `ApplyOp.addTag/removeTag`, `tag~=` filter field, `type="lens"` — are NOT matched by the patterns above. If any pattern hits, it's residue to delete.)

- [ ] **Step 4b: grid/rail × section-lens behavior (plan-review).** Document in `architecture.md`: after the tag-mode exit-2 is gone, grid/rail are unconditionally dispatchable; they remain workspace/section-overview surfaces and drop lens-parked windows via the snapshot's `isLensParked` (EX-2). They are NOT blocked by a CLI gate anymore. If a CI-testable seam exists, add `testGridRailDispatchUnconditionalPostTagRemoval`; otherwise this is a host-verify item.
- [ ] **Step 5: `swift build` green** + glossary/README terminology consistent (`CLAUDE.md` Terminology rule — terms land in the same PR as the code).
- [ ] **Step 6: Commit.**

```bash
git commit -am ":memo: docs(config)!: drop [grouping]/[[tag]] from template/schema/glossary/architecture/README + stale-test sweep (EX-4.4)"
```

---

## Host-verify (トミー operates; synthetic input NG, fresh per-op consent)

Run after the whole branch builds + the whole-branch adversarial review is clean. `./run.sh` (AX re-grant in System Settings ▸ Accessibility if the re-sign drops it). Verify (exact commands + expected log lines provided at host-verify time):

1. **Regression (highest risk):** facet adopts windows, no crash, AX writes land — `Set<String>` tags didn't break normal operation.
2. **`window --tag` ungated + works under section model:** `facet window --tag web` on a focused window → `query`: `tags=['web']`; with a `type="lens" match='tag~=web'` section active, the next reconcile gathers/parks by the new tag (reconcile-driven, not synchronous park).
3. **`facet tag …` + `facet lens --add/…` are GONE:** unknown-verb `exit 2` (loud, per house Rule of Repair).
4. **lens activate/clear (the 2-system surface):** `facet lens "Web"` gathers union; `facet lens --clear` restores.
5. **startup = first workspace:** fresh `./run.sh` → active = first `type="workspace"` section, no lens.
6. **grid/rail no longer exit-2:** (n/a — tag mode gone; views unconditional).
7. **leftover `[grouping]`/`[[tag]]` in a config is silently ignored** (no crash, clamps to workspace/section model).

---

## Plan-review (wf_9e9bc169-fbc, 2026-06-22) — folded

3-lens adversarial review + adjudicator (source-grounded). Adjudicator verdict: **needs-fixes → 1 confirmed must-fix + 7 should-fix; the rest of the lenses' "must-fix" were REJECTED as misreadings** (the deletion sequencing callers→impl→types is sound; A5 compiles green because `setLens`+`catalog.lensOnly/…` survive until B2/B3; the window-`--tag` gate/`RetagVisibility` correctly survive EX-4.2 and are replaced in B1/4.3; the EX-4.1 test already calls `seed(configs:)`). Folded:

- **MUST-FIX — `Layout.swift` `supportedGroupings`** (the real gap): `LayoutEngine` declares `supportedGroupings: Set<Grouping>` (:68) + default `[.workspace, .tag]` (:79); deleting `Grouping` breaks it → delete the requirement + default in C1 (no overrides). → **folded into EX-4.2c C1.**
- SHOULD — view-layer tag surface (bigger than first mapped): `TagEditPanel.swift` (35KB tag-manage GUI) + `tagModeActive` flag across SidebarView+5 files + `enterTagManage`/`t`-key + `Controller.swift:1038` tagMode arg. → **folded into EX-4.2a A4** (caller layer, before B).
- SHOULD — `LensSpec` enum deletion (Backend.swift, dead after setLens) → **B4**; `effectiveMacDesktopSectionConfigs` explicit code + `isSectionModelActive` verify → **C4**; `seededCatalog` helper definition → **EX-4.3 test-infra**; `applySectionLensReconcile` real signature → **EX-4.3 Step 5**; LensRoute pre-deletion grep gate → **C2**; explicit test pre-list + survivor-aware final grep gate → **EX-4.4 Step 4**; grid/rail × section-lens behavior doc/test → **EX-4.4 Step 4b**; query-tags KEEP-but-volatile + ApplyResolver/survivor parity run → **EX-4.3 Step 8**; startup no-workspace-section edge test → **EX-4.1 Step 2**.

VERDICT after folding: **execution-ready (0 open must-fix).**

## Self-Review

**1. Spec coverage** (revised-plan EX-4 row + canon ⑬⑭ + トミー decision):
- `[grouping] by=tag` deleted → EX-4.2c (Grouping enum, config, fatalConfigErrors). ✓
- `[[tag]]` + UInt64 bitmask tag-mode deleted → EX-4.2 (machinery) + EX-4.3 (TagModel/storage). ✓
- tag STORAGE migration UInt64→string-set + own tests → EX-4.3 (`WindowTagsTests`). ✓
- grid/rail tag-mode exit-2 lifted → EX-4.2a (Main.swift :656-667). ✓
- CLI 2-system (drop composition/vocab, keep `lens NAME/--clear` + `window --tag/...`) → EX-4.2a + EX-4.3. ✓
- startup = first type=workspace → EX-4.1. ✓
- docs/glossary/README/schema → EX-4.4. ✓

**2. Placeholder scan:** migration code blocks (EX-4.3 Steps 3-6) are complete; deletion steps name exact file:line + the surviving shape (a deletion plan can't show "complete code" for removed lines — it shows the exact targets + the post-state + a `grep` gate). No "TBD"/"handle edge cases".

**3. Type consistency:** `WindowSlot.tags: Set<String>` (storage) vs `Window.tags: [String]` (display, sorted at the `makeWindow`/query seam) vs `ApplyPlanWindowFields.tags: [String]` (ordered apply-sim) — three deliberate types, bridged by `.sorted()` at the overlay. Mutators return `Bool` (EX-4.3) replacing `RetagVisibility?` (EX-4.2) — the `NativeAdapter+Tagging` rewire (EX-4.3 Step 5) is where the return-type change lands; until then (EX-4.2) they keep `RetagVisibility?` but the adapter ignores it (reconcile owns visibility).

**4. Risks carried into review:**
- `LayoutGrouping` deletion: all 6 refs are `with: .tag` (verified) — but re-grep before C1 to catch any merge-in-flight new use.
- Section machinery accidental deletion (critic): `applySectionLens` / `setActive` gate / `activeSectionLensApplyTags` are VERIFY-ONLY — the whole-branch review must confirm they're untouched.
- `window --tag` reconcile latency: dropping synchronous park/restore means a tag change reflects on the next reconcile (D3). Confirm `applySectionLensReconcile()` after the mutation makes it prompt (host-verify item 2).
- `--layout` typo rejection must survive `LayoutGrouping` deletion (it validates via `LayoutRegistry`/canonical layouts, not `LayoutGrouping`) — verify in C1.

## Execution Handoff

Plan complete. Execution = **Ultra** (per `facet-exclusive-model-execution-plan`): in-place on `feat/ex4-tag-mode-removal` (host-verify loop needs the main working dir); implementer = main loop or a sequential implementer subagent with full verified context; **adversarial 3-lens review per task** + **whole-branch review** at the end; push/merge + host-verify await トミー go. Before executing, run a **3-lens adversarial plan review** of THIS doc and fold the must-fixes.
