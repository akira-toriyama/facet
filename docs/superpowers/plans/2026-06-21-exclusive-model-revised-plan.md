# Exclusive Selection Model — REVISED Plan (EX-0 → EX-4)

> **Supersedes** [2026-06-20-tag-unification-exclusive-model.md](2026-06-20-tag-unification-exclusive-model.md).
> Product of a zero-base architecture re-examination (design judge-panel, workflow `wf_b2e86e11-b22`, 2026-06-21):
> 3 independent end-to-end designs → adversarial scoring → synthesis. Confidence: **high** — every load-bearing
> disputed fact verified directly in source. Blessed by トミー (adopt + start EX-0 + EX-0 as one host-verify phase).

## Why this revision (the decisive find)

The current branch (`feat/ex1-exclusive-lens`) has a **verified correctness bug**, not merely incomplete work:
`setSectionLens` feeds `applySectionLens` an **active-workspace-only** visible set
(`sectionLensVisibleIDs(workspace:live:)` is gated by `windowMap[id]?.workspace == n1Based`), while
`applySectionLens` (after EX-1b.1) scans **all** of `windowMap` to decide what to park. Net effect: a window that
MATCHES the lens but lives in an **inactive** workspace is **parked, not gathered** — `facet lens` does cross-WS
*park* but not cross-WS *gather*. EX-1a/b.1/b.2 are all correct primitives; the bug is the **caller**.

## End state (one concept: the active section)

`ActiveSection := activeLens (a type="lens" DesktopSection) XOR activeWorkspace (the always-present spatial slot)`.
Always exactly one active, enforced at the catalog seam (FacetAdapterNative), not scattered across callers.

- **Two tiling machineries, selected by type, never duplicated:** `type=workspace` → existing per-WS stateful
  path (`applyLayout`'s bsp/stack/master/engine on `activeIndex`); `type=lens` → stateless union via
  `sectionLensUnionFrames(layout:in:)` over `sectionLensUnionMembers()`, through the SAME anchor-park chokepoints
  (`applyHide`/`detachFromLayouts`/`attachToLayout`).
- **One match predicate** (`LensMembership.matches`) shared by display (`FilterProjection`) and hide (park) — they
  cannot disagree. Match is adapter-side (catalog holds no live title/appName).
- **Three views = three renderings of one ordered section list** (tree rows / grid cells / rail carousel cells);
  a window/cell click in ANY view → `activateSection(id:)` + focus.
- **CLI = 2 systems:** (1) one section-activate verb (NAME selects any section), (2) window-attribute verbs.
- **Config:** each unit is a `[[desktop.N.section]]` (type/match/apply/layout); 迷子 receptacle = explicit
  `type="lens"` section.
- Hide is anchor-park throughout (SIP-on, never cross-desktop). Layer spine intact:
  `ActiveSection`/`FilterProjection`/`LensLayout` pure FacetCore; park + match-eval adapter-side; views read
  snapshots + `WindowBackend` only.

## Phase plan

| Phase | Deliverable (dogfoodable) | Key changes |
|---|---|---|
| **EX-0** ⭐ | `facet lens NAME` genuinely GATHERS every matching window from all WS into one union-tiled view + parks the rest everywhere; any `facet workspace --focus`/switch CLEARS the lens. **Host-verified.** Tree only. | gather-bug repair + wire dead union helpers + exclusive switch-clear |
| **EX-1** | Exactly one lit active-section highlight; `ActiveSection` authority + `activateSection` verb (throughline); config/docs/glossary; startup/session-active wired | `ActiveSection` enum; `activateSection(id:)`; single-highlight; startup pulled forward |
| **EX-2** | grid/rail render lens sections as cells; click any window/cell → activate+focus; unified highlight 3-view | grid/rail consume `[ProjectedSection]`; net-new lens-cell plumbing |
| **EX-3** | `workspace = 0 or 1` (迷子); symmetric DnD move; new-window apply inheritance | `WindowSlot.workspace: Int?`; **purpose-built `setWorkspace` move primitive** |
| **EX-4** | `[grouping] by=tag` + `[[tag]]` + UInt64 bitmask tag-mode removed; CLI 2-system; grid/rail tag-mode exit-2 lifted | tag **storage migration** UInt64→string-set (own tests); delete `grouping==.tag` branches |

## EX-0 — detailed (execute now; 4 reviewable sub-tasks, ONE host-verify at the end)

Each sub-task = one commit on `feat/ex1-exclusive-lens`, TDD where testable, adversarial review per sub-task,
single host-verify after all four. **Patch by symbol, not line — earlier audits found systematic line drift.**

### EX-0.1 — Cross-workspace gather (the correctness repair)
- Add `sectionLensVisibleIDsAll(live: [Window]) -> Set<WindowID>?` in `NativeAdapter+Queries.swift`: evaluate
  `LensMembership.matches` over the WHOLE `windowMap` (no `==n1Based` clause), overlaying each window's HOME
  workspace name via `catalog.workspaceName(slot.workspace)`. Mirror the existing `sectionLensVisibleIDs(workspace:live:)`
  but cross-workspace. Reuse `sectionLensFilter()`.
- Rewire BOTH callers in one step (no active-WS evaluator left wired where a lens is active):
  `setSectionLens` and `applySectionLensReconcile`.
- Test: prove a matching window in an inactive WS is GATHERED (in the visible set), not parked.

### EX-0.2 — Tile the union (activate the dead helpers)
- Add a lens branch at the TOP of `applyLayout` (before the `grouping == .tag` branch): when
  `catalog.activeSectionLens != nil`, call `applyFrames(catalog.sectionLensUnionFrames(layout:
  LensLayout.resolve(lensLayout(forLabel:), globalDefault: config.effectiveDefaultLayout), in: rect), …)`.
- Add `lensLayout(forLabel:)` mirroring `sectionLensFilter()` (guard `activeMacDesktopOrdinal`, look up the
  `type=.lens` section's `layout`).
- **Ensure ALL `applyLayout` callers honor the lens guard** (enumerate them: switch-settle, retile, move, setMode,
  perform, refresh — grep `applyLayout(`); a stray per-WS retile must not un-tile the union while a lens is active.

### EX-0.3 — `setLayoutMode` lens guard (Decision B)
- When `catalog.activeSectionLens != nil`: retarget the lens union; reject non-stateless modes loudly via
  `LensLayout.isStateless(mode)` + `errorContinuation.yield` (mirror the tag-mode reject branch's shape but do
  NOT route through `LayoutGrouping.isCompatible`/`.tag` — forward-compatible with EX-4 tag-mode deletion).

### EX-0.4 — Exclusive switch-clear (retire D1)
- `switchWorkspace` passes `lensVisibleIDs: nil` (a workspace switch is always exclusive now).
- **DELETE** the `setActive` destination re-park branch (the `lensVisibleIDs == nil || …` else-park block). Verified:
  `setActive` already `lensParkedMembers.removeAll()`s on every switch — so exclusivity is "caller passes nil +
  delete the re-park branch", NOT a hot-path rewrite.
- Sync `syncSectionLensMirror` wherever the clear timing changes so `currentSectionLens()` never goes stale.
- Test: switching a workspace while a lens is active clears `activeSectionLens` and restores all parked windows.

### EX-0 host-verify (トミー operates; synthetic input NG)
Build + run; トミー opens Chrome on WS1 and WS2; agent runs `facet lens "Web"`; confirm in `/tmp/facet.log` + on
screen: windows from **both** workspaces GATHER into one union (not just non-matching disappearing), non-Web parks
to the sliver, tree lights only the lens; `facet workspace --focus`/switch CLEARS the lens and restores windows to
home workspaces. Provide exact commands + expected `parked=N`/`restored=N`/gather log lines.

## Decisions locked
- **KEEP all EX-1 primitives as-is** (0 discard, 0 rewrite): EX-1a wired via `LensLayout.resolve`; EX-1b.1 catalog
  correct (caller fixed in EX-0.1); EX-1b.2 dead code activated in EX-0.2.
- `setActive` needs NO hot-path rewrite (already clears the lens; verified line ~563).
- EX-3 symmetric DnD needs a **purpose-built `setWorkspace` move primitive** (`ApplyResolver.inverse` is tag-only —
  drops `setWorkspace`).
- EX-4 is a **tag-storage migration** (UInt64 bitmask → free-form string set), not pure deletion — own test coverage.
- 迷子 = explicit `type="lens"` config section; do NOT revive the トミー-deferred `unassigned` projection (2026-06-17).

## Breaking changes
- Phase-1 D1 retired: activating a workspace CLEARS the active lens (was: persist + re-compose). Intentional per
  2026-06-20 大改訂; contradicts shipped #313.
- `facet lens NAME` becomes cross-workspace (pulls matching windows out of other workspaces into one union).
- (EX-3) `WindowSlot.workspace: Int?` — orphans allowed; no-receptacle orphans invisible-but-logged.
- (EX-3) DnD = symmetric move across all section pairs. New windows inherit active section's `apply`.
- (EX-4) `[grouping] by=tag` + `[[tag]]` + bitmask tag-mode deleted; tag storage migrates to string set;
  `by=tag` configs stop parsing. grid/rail tag-mode exit-2 removed. CLI collapses to 2 systems.

## Biggest risks
1. **EX-3 nullable `WindowSlot.workspace`** — non-Optional `let` read at dozens of sites incl. dictionary-subscript
   (`layoutTrees[slot.workspace]`); optionality forces a per-site orphan-policy DECISION (lazy guard-let-drop = the
   vanish bug). Land as pure catalog + exhaustive CI XCTest first, AX wiring after.
2. **EX-0 AX placement authority** — `applyLayout`'s new lens branch must be the SOLE placement while a lens is
   active; all `applyLayout` callers + `applySectionLensReconcile` must honor the guard.
3. **EX-0 host-verify stacks on #313 PR-4** (itself un-host-verified) — verify must confirm cross-WS GATHER
   specifically, not just non-matching windows disappearing.
4. **EX-4 tag-capability coverage** — enumerate each tag-mode capability + confirm a section twin exists BEFORE
   deleting (else regression).
5. **Cross-WS union has no on-current-desktop guard** — a stale cross-desktop window from the native-Space drift
   bug ([[facet-native-space-drift-heal]]) would now be union-TILED visibly; confirm the drift-heal evict runs
   before union tiling.

## Open questions for トミー (surfaced at each phase, not now)
- **EX-2:** lens-cell content in grid/rail is best-effort degraded (parked sliver → SCK yields a sliver); confirm
  icon/blank fallback acceptable + sliver-capture suppressed (decision ⑨).
- **EX-3:** confirm orphans with no 迷子 receptacle are invisible-but-logged (not auto-homed to WS1); confirm
  迷子-as-explicit-config-section replaces the deferred `unassigned`.
- **EX-4:** runtime tag-composition verbs (`facet lens --add/--remove/--toggle/--all`, #191/#228) have NO section
  replacement unless an apply-edit CLI is built — drop them, or build a window-attribute apply-edit verb? Ship the
  迷子 receptacle uncommented+推奨 (out-of-box) or commented (opt-in)?
