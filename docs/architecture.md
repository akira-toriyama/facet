# facet — architecture

facet is a Swift workspace + window manager for macOS. The split
into **Core / Adapter / View** is the central design idea: the
same pure-logic core can drive multiple UI surfaces (tree sidebar,
full-screen overview grid, future docks/hovers), and the same UI
works against the native AX / CGS backend (`FacetAdapterNative`).
The `WindowBackend` protocol seam stays in place as a unit-test
stub seam.

## Layers

```
┌─────────────────────────────────────────────────────────┐
│  FacetViewTree   FacetViewGrid   FacetViewRail  (future)│  view
│           \                  /                          │
│            └──── FacetView ──┘  (shared primitives)     │
└──────────────────────┬──────────────────────────────────┘
                       │
              ┌────────┴────────┐
              │   FacetCore     │  pure logic:
              │                 │   - Workspace / Window state
              │                 │   - focus rules, layout engines
              │                 │   - backend protocol + event types
              │                 │  GUI / OS / backend non-依存
              └────────┬────────┘
                       │
              ┌────────┴──────────┐
              │ FacetAdapterNative│  adapter
              │  (AX / CGS / dlsym private symbols) │
              └───────────────────┘
```

`FacetCore` defines a `WindowBackend` protocol (workspaces, move,
focus, switch, layout, display, event stream, …) — single
implementation today (`FacetAdapterNative`); the protocol seam
is preserved for unit-test stubs (`StubBackend` in `BackendTests`).

## Why three layers, not two

- **Test surface**: `FacetCore` is pure logic, fully exercised in
  `Tests/FacetCoreTests` without any AppKit. Adapters get contract
  tests by feeding canned event streams. Views are GUI-only — kept
  thin, no business logic.
- **Backend swap**: the `Native` adapter starts as a stub and grows
  in Phases α–ε without ever breaking the views. When it's solid,
  `Rift` adapter is retired (without modifying any view code).
- **Multiple views over the same state**: tree and grid are two
  facets of the same workspace model. Future views (hover-bar,
  dock-bar, command palette, etc.) plug in without touching Core
  or Adapter.

## Milestones

| Phase | Goal | Done when |
|---|---|---|
| **M1** | Repo scaffolded, multi-target Package.swift builds | `swift build` / `swift test` green |
| **M2** | tree + grid views + CLI working (originally via rift adapter, retired at ε) | tree + grid panels render against live backend |
| **M3** | Homebrew tap entry (under existing `akira-toriyama/homebrew-tap`) | `brew install akira-toriyama/tap/facet` works |
| **M5** | Native adapter Phase α–ε. All five phases shipped (α/β/γ.1/γ.2/γ.3/δ/ε); v2.0.0 retired rift, native is the only backend | see below |
| **M6–M11** | **Polish → window mgmt → WS ops → tag/scrollable → macOS 26.** M6 brushup done; **M7 is a numbering gap**; **M8 window management is code-complete (2026-06-02)** — themes A–D incl. rail (#109), marks / sticky / scratchpad, real-window DnD + resize, cheap tiling verbs; M9 (WS ops + view unification), M10 (tag model + scrolling columns), M11 (macOS 26 mac-desktop WS, v3.0.0) are the forward roadmap | `facet-future-roadmap` memory is canonical + "Themes A–D" below |

## Native adapter phases

The SIP-enable boundary is firm: facet runs in user space, using
only public APIs + Accessibility. No yabai-style injection. This
matches how rift / aerospace operate today.

| Phase | Scope | Reference reading |
|---|---|---|
| **α** | virtual workspace concept self-managed; focus tracking. **Frozen 2026-05-24, shipped 2026-05-26**: (b) hybrid model (mac desktop × facet workspace), default 5 WS dynamic, hide method = `anchor` (1×41 px corner park), CLI = `facet workspace --focus=N` (α 期の flag は `--workspace=N`、Theme C #81/#82 で subject-verb 化). Workspace state + reconcile + focusedWindow + AX-driven event subscription | rift `workspace` module, AeroSpace `MacWindow.hideInCorner` |
| **β** | window move across workspaces; off-screen park/unpark; closeWindow. **Shipped 2026-05-26**: anchor hide / closeWindow + windowMenu Close | rift `wm/window`, yabai window mgmt |
| **γ** | window tiling (BSP / stack layout engines). **Frozen 2026-05-26; γ.1 / γ.2 / γ.3 all shipped (PR #44 / #45 / #46)**: BSP + stack only, always-on auto-tile, auto-balance split, lazy retile, per-WS mode (default `"float"`), `LayoutTree` value type, 5 CLI verbs, AX-role auto-float for sheets / dialogs / palettes | rift `layout`, AeroSpace tree |
| **δ** | display reconfigure handling; persistence-aware geometry (no new state). **Frozen + shipped 2026-05-27 (PR #53)**: `didChangeScreenParameters` listener, active WS re-tile, anchor-parked rescue to nearest visible display, panel snap to nearest display, pure helpers in `DisplayGeometry`. Single-display dev environment so multi-display polish is rescue-helpers-only | — |
| **ε** | `FacetAdapterRift` retire; native becomes the only backend. **Frozen + shipped 2026-05-27 (v2.0.0 major bump)**: rift module deleted, `FACET_BACKEND` env var removed (kept as warning hint only), `WindowBackend` protocol preserved for unit-test stub seam. M5 completes here. | — |

Each phase is gated by being usable end-to-end through the view layer
— no Phase α–δ landings ship unless the existing UI still works
against them.

## Themes A–D (M8 window management, shipped 2026-06-02)

M5 shipped at v2.0.0 (themes stocked 2026-05-27). **All four themes
below shipped under M8** (#72 / #73–80 / #81–82 / rail #109), each
after a grill round (Phase γ/δ/ε pattern; see the Status column). M8
also shipped the stocked slots — window marks (#118/#119), sticky
(#128/#129), scratchpad (#135), real-window DnD (#122–124) + resize
(#125/#127), cheap tiling verbs (#115/#117). The forward roadmap is
**M9** (WS ops + view unification), **M10** (tag model + scrolling
columns), **M11** (macOS 26 mac-desktop WS, v3.0.0). M7 is a numbering
gap. Canonical: `facet-future-roadmap` memory.

| Theme | Goal | Status |
|---|---|---|
| **A. Tree DnD parity** | Tree view で WS / window DnD reorder (grid view と同等機能) | ✅ shipped (#72) |
| **B. Extended layouts** | Centered Master (3-column, ultrawide 向け) / Scrolling columns (niri 風) を Phase γ の `bsp` + `stack` に追加 | ✅ shipped (#73–80) — monocle / tall / centered-master / grid / spiral + master ops。命名整理は #108 (monocle→stack 統合・centered-master→centered) 経て **M9-2 で master 5 辺化に確定**: `master-left` / `master-right` / `master-top` / `master-bottom` / `master-center` + grid / spiral (tall/wide/centered は破壊的リネーム・`--toggle-orientation` の master flip 廃止)。scrolling columns (niri 風) は未実装 (M11-4) |
| **C. CLI redesign** | yabai 流の豊富 parameter 設計を参考に、整合性 / 一貫性を最優先で再設計。 **破壊的変更 OK** (トミー明示) | ✅ shipped (#81 / #82) — `facet workspace` / `window` subject-verb |
| **D. New view types** | 当初候補 (i) 自由配置 canvas Google Maps 風 / (ii) WS DnD reorder Mission Control 風 はいずれも却下 → 別案 **rail view** (全画面 WS overview バー) を採用 | ✅ shipped as `facet --view=rail` (#109) |

着手前 invariants: `facet-buddha-palm-principle` (OS 尊重) を壊さない / `facet-scope-exclusions` (15 not-do) と矛盾しない / `WindowBackend` protocol 経由設計を維持 (unit-test stub seam を壊さない)。

### Phase α frozen decisions (2026-05-24)

Phase α design is fully decided. Details live in memory; this list
is the index. **Do not relitigate** without explicit grill round.

- **Workspace model**: (b) rift-style hybrid (mac desktop × facet
  workspace, 2 dimensions). Window-unit management (not app-rules).
  Default 5 WS per mac desktop; dynamic add/remove/rename/move at
  runtime via `facet workspace --add` / `--remove` / `--rename` /
  `--move`. Persistent naming is via `[desktop.N]` in config.toml
  (read-only seed — facet never writes config).
- **Per-mac-desktop workspaces**: each mac desktop keeps an
  independent set of facet workspaces (own `WorkspaceCatalog`,
  parked/swapped on mac-desktop switch). The active mac-desktop id + ordinal
  are read read-only via private SkyLight (`MacDesktops`,
  `SLSGetActiveSpace` / `SLSCopyManagedDisplaySpaces`); facet never
  moves windows across mac desktops, so it stays SIP-on / public-contract
  (the rejected cross-mac-desktop move was hide 手法4). `[desktop.N]` config
  customises a mac desktop's WS list by Mission-Control ordinal — each
  entry is an inline-table value (`1 = { name = "...", layout = "..." }`,
  layout optional). Catalog state is session-only. Opt-in: any `[desktop.N]` → facet
  manages only configured mac desktops, others hands-off (panel hidden);
  no `[desktop.N]` → all mac desktops managed by default. SkyLight gone → single shared
  catalog. Memory: facet-per-native-space-ws. (This supersedes the
  earlier "mac desktop co-use discouraged" stance — facet now nests
  under mac desktops by design.)
- **Hide method**: 7 candidates evaluated; only `anchor` (1×41 px
  corner park) is used — instant, no animation, recoverable from
  Mission Control. `minimize` (Dock genie) was trialed then
  dropped (the genie animation makes workspace switching feel
  slow); no config knob remains, `anchor` is unconditional. True
  hide (MC/Cmd-Tab disappearance) is impossible in public API —
  out of scope for facet. A genuine *user* hide (Cmd+H / Cmd+M →
  `isOnscreen=false`) gives up the window's tile slot so neighbours
  reclaim it (`WorkspaceCatalog.reconcileHidden`); the window keeps
  its WS assignment + marks, shows dimmed with a `hidden` badge in the
  tree, and re-attaches at the tail when it returns on-screen (click
  restores via `WindowBackend.revealWindow`). facet's own anchor park
  keeps `isOnscreen` true, so only user hides trigger this (#131 /
  #132 / #133; memory `facet-hide-reclaim-decisions`).
- **CLI surface**: `facet workspace --focus=N` switch, `facet window
  --move-to=N` move, `--reload` explicit + auto FSEvents watcher,
  `status` for state dump. Subject-verb form since Theme C (#81/#82);
  the α-era top-level `--workspace=N` was deleted. TOML atomic write
  enforced in shipped templates.
- **Shortcut**: out of scope. README recommends skhd / Karabiner /
  hammerspoon (compose-friendly, like yabai + skhd).
- **New window detection**: per-app AX subscription via
  `WindowEventObserver` (pattern lifted from [focusfx]). Wires
  `kAXFocusedWindowChanged` + `kAXWindowCreated` +
  `kAXUIElementDestroyed` on every running app, folded with
  `NSWorkspace` launch / terminate. Public AX notifications are
  the OS-blessed seam — not a self-hook in the buddha-palm sense
  (`facet-buddha-palm-principle`); that line is reserved for
  swizzling / private SLS injection.
- **Multi-display**: independent WS sets per display. Untested
  (developer has 1 display).
- **Fullscreen apps**: excluded from facet management, left to
  macOS.
- **Persistence**: not in facet. Persistent WS names live in
  `[desktop.N]` config sections (read-only seed). Runtime layout /
  catalog mutations are session-only.
- **Startup**: don't touch existing windows. **Shutdown**: restore
  all hidden windows (treat shutdown = workspace feature OFF).

Memory cross-references: `facet-workspace-model`,
`native-window-hide-methods`, `facet-cli-surface`,
`facet-scope-exclusions`, `facet-buddha-palm-principle`.

### Phase γ frozen decisions (2026-05-26)

Phase γ design is fully decided. Details live in memory
(`facet-phase-gamma-decisions`); this list is the index. **Do
not relitigate** without explicit grill round.

- **Layout modes**: `bsp` + `stack` only. `master_stack` /
  `scrolling` / `traditional` are out of scope; future opt-ins.
- **BSP auto-tile**: always-on. A WS in `bsp` mode auto-splits
  the focused window on every new-window event.
- **Split direction**: auto-balance (wider window → vertical
  split, taller → horizontal). New window lands on the
  bottom / right of the resulting split.
- **Floating opt-out**: AX role auto-detection (`AXSheet`,
  `AXDialog`, `AXSystemDialog`, `kAXFloatingWindowSubrole`)
  plus manual `toggleFloat`. Floating windows skip the tree.
- **Manual resize**: lazy retile. facet only re-applies
  tree-computed frames on *tree-changing events* (new window,
  close, mode flip, `--retile`, WS switch). User drags survive
  until the next such event — drag observation + ratio update
  (yabai-style) is a later increment.
- **WS switch (active flip)**: tiled windows go to
  tree-computed frames; floating windows restore from
  `originalPosition` per existing hide flow.
- **Stack mode**: focused window fills the display; others are
  parked at the anchor sliver. `cycleStackNext` /
  `cycleStackPrev` actions move focus; a new window in a stack
  WS becomes the focused / top member.
- **Layout state**: `LayoutTree` value type in
  `FacetAdapterNative`, peer to `WorkspaceCatalog`. Catalog
  composes `layoutTrees: [Int: LayoutTree]` (per-WS, only
  present for `bsp` WSs). Same pattern as the PR-B
  `WorkspaceCatalog` extraction — pure data, no AX, fully
  unit-testable.
- **Multi-display**: unchanged from Phase α. Tree is per-WS,
  WS is per-display; the root rect is the active display's
  `visibleFrame`. No cross-display tree, no display-move action.
- **Gaps / padding**: zero, hardcoded. Config key reserved for
  later if demand surfaces.
- **Directional movement**: only `toggleOrientation` (rotate
  the focused window's parent split). `moveLeft/Right/Up/Down`
  are out of γ.1 scope; tree pathfinding adds enough complexity
  to deserve its own increment.
- **Mode change**: smooth migration — `toggleStack` from BSP
  parks all but focused (at the anchor sliver); the reverse
  re-inserts members in focus order via auto-balance. **Default
  mode for a new WS = `"float"`** (not `"bsp"`) so existing
  users see no surprise behaviour; opt-in per WS via
  `facet workspace --layout=bsp` (subject-verb since Theme C #81/#82).
- **CLI surface (5 new verbs)** (reshaped to subject-verb by Theme C #81/#82):
  - `facet workspace --layout=NAME` — active WS mode (`bsp` / `stack` / `float`)
  - `facet workspace --retile` — recompute + re-apply the active WS layout
  - `facet window --toggle-float`
  - `facet window --toggle-orientation`
  - `facet window --cycle-stack=next|prev`
- **Phasing**: ships as three PRs.
  - **γ.1 BSP core (shipped)** — `LayoutTree`, per-WS mode
    field, BSP auto-tile, manual `toggleFloat`,
    `toggleOrientation`, four of the five CLI verbs + this
    `architecture.md` section.
  - **γ.2 Stack mode (shipped)** — stack implementation +
    cycle ops + the `--cycle-stack` CLI.
  - **γ.3 AX role auto-float (shipped)** — populate
    `isFloating` on new windows whose AX role / subrole is in
    the floating set (`AXSheet`, `AXDrawer`,
    `kAXFloatingWindowSubrole`, `kAXSystemDialogSubrole`,
    `kAXSystemFloatingWindowSubrole`, `kAXDialogSubrole`).
    First-sight hint only — user's manual `toggleFloat` stays
    authoritative.

Memory cross-reference: `facet-phase-gamma-decisions`.

### Phase δ frozen decisions (2026-05-27)

Phase δ design is fully decided. Details live in memory
(`facet-phase-delta-decisions`); this list is the index. **Do
not relitigate** without explicit grill round.

- **Scope interpretation**: `display reconfigure handling +
  persistence-aware geometry`. The "persistence" half does
  NOT add new facet-managed state — it means making sure
  *existing* persisted geometry (panel position) survives
  display reconfiguration without breaking. WS state
  persistence stays out of scope (Phase α frozen "no state
  persistence — config seed only" is preserved).
- **Trigger**: `NSApplication.didChangeScreenParametersNotification`
  only. Covers resolution change, arrangement, hot-plug, lid
  open/close, sleep wake — one signal, one handler.
  Fine-grained `CGDisplayRegisterReconfigurationCallback` is
  YAGNI; the response is the same regardless of cause.
- **Handler**: re-tile *active WS only* (lazy retile invariant
  preserved, `facet-phase-gamma-lessons`). Plus: rescue
  `anchorParked` windows whose recorded `originalPosition` is
  no longer on any visible display — move to the nearest
  visible display's anchor sliver. Inactive WS layouts are
  not touched (catch up on next switch).
- **Panel snap fallback**: when the persisted panel rect is
  fully off-screen after a reconfig, snap to the nearest
  visible display's centre (preserving size). Main-display
  reset and default-position reset both rejected — nearest
  matches user intent best.
- **Architecture**: `Sources/FacetAccessibility/DisplayChangeObserver.swift`
  mirrors `WindowEventObserver` (same `init(onChange:)` /
  `start()` / `stop()` shape). Pure geometry helpers in
  `Sources/FacetAccessibility/DisplayGeometry.swift`
  (`orphanedPoints`, `nearestDisplay`, `isVisible`).
  Controller and NativeAdapter each own their own observer
  instance — backend doesn't notify the controller, each
  handles its own concern (separation maintained).
- **Debounce**: 0.5 s. Reconfig events fire in bursts of 2–3
  notifications; debounce coalesces them into a single
  handler invocation via `DispatchWorkItem` cancel /
  reschedule.
- **Testing strategy**: pure `DisplayGeometry` helpers get
  full unit coverage. `DisplayChangeObserver` lifecycle gets
  1–2 cases (start/stop + debounce). The AX-touching parts
  (NativeAdapter `handleDisplayReconfigure`, PanelHost
  reconfigure response) are acknowledged as untested on the
  current 1-display dev environment; production smoke is
  deferred to multi-display users.
- **PR phasing**: single PR (≈600–800 lines incl. tests).
  Same pattern as γ.1 — pure value type + first consumer in
  one mergeable unit, no orphan-consumer split.

**Single-display dev environment note**: The developer
machine has one display. Multi-display polish isn't pursued
beyond what the rescue helpers naturally cover. The geometry
helpers ARE implemented (they're pure, unit-testable, cheap)
so when multi-display use surfaces — own setup change, user
report — the response logic is already there.

Memory cross-reference: `facet-phase-delta-decisions`.

### Phase ε frozen decisions (2026-05-27)

Phase ε is the M5 finisher: retire the rift adapter, make native
the only backend, bump to v2.0.0. Details live in memory
(`facet-phase-epsilon-decisions`); this section is the index.
**Do not relitigate** without explicit grill round.

- **End state**: `FacetAdapterRift` module is **fully deleted**.
  `FACET_BACKEND` env var is removed as a switch — kept *only*
  as a startup-warning hint so users who had
  `FACET_BACKEND=rift` set in their shell see a `Log.line`
  explaining v2.0 dropped the rift adapter. `rift-cli`
  dependency is gone; the brew formula was always runtime-dep
  free so no formula change.
- **Phasing**: single PR. Deletion-heavy (~1500 line churn,
  almost all subtractions); no intermediate state.
- **`WindowBackend` protocol**: **preserved** as a unit-test
  stub seam (`StubBackend` in `BackendTests`). Surface (`name`,
  `layoutModes`, etc.) kept as protocol-shape expression.
- **Versioning**: major bump v1.x.y → **v2.0.0**. Commit
  message carries `BREAKING CHANGE:` footer so `git-cliff`
  derives the bump automatically. README milestone row
  records "v2.0.0: rift retired".
- **Migration messaging**: friendly hint, not error.
  `FACET_BACKEND=rift` upgrade case prints one `Log.line`
  ("FACET_BACKEND is no longer used; native is the only
  backend"). Silent ignore considered (less helpful) and
  hard error considered (too disruptive); hint is the
  Goldilocks. Warning code itself is removable in a later
  polish PR once v2.0 has settled.
- **Memory**: `rift-restart-gotcha` and
  `rift-workspace-names-config-reapply` are kept as
  historical (`applies to facet ≤ v1.x` banner added); the
  knowledge they carry stays useful for users running rift
  standalone.

Memory cross-reference: `facet-phase-epsilon-decisions`.

## Mapping to Clean Architecture / DDD

facet's 3-layer split is **Hexagonal (Ports & Adapters)** —
which is the same idea Clean Architecture distills into "the
dependency rule: source code dependencies always point inward."
The DDD tactical patterns also fit cleanly even though the code
never spells them out. This table is the rosetta stone so the
two vocabularies don't drift apart:

| Pattern | facet implementation |
|---|---|
| **Clean Architecture — Domain** (Entity + Repository protocol) | `FacetCore` (`Workspace`, `Window`, `WindowID`, `WindowAction`, `WindowBackend` protocol) |
| **Clean Architecture — Platform / Infrastructure** (Repository impl) | `FacetAdapterNative` (`NativeAdapter`, `WorkspaceCatalog`, `LayoutTree`) + `FacetAccessibility` (AX helpers) |
| **Clean Architecture — Frameworks & Drivers** (UI) | `FacetView`, `FacetViewTree`, `FacetViewGrid` (AppKit-bound) |
| **Clean Architecture — Application** (DI + Coordinator) | `FacetApp` (`Controller` + `Main`) |
| **Clean Architecture — Use Case (Interactor)** | *NOT a separate layer* — see below |
| **DDD — Entity** | `Workspace`, `Window` |
| **DDD — Value Object** | `WindowID`, `Palette`, `FontKind`, `CGRect`, `GridConfig` |
| **DDD — Aggregate Root** | `Workspace` (owns its `windows`) |
| **DDD — Repository** | `WindowBackend` protocol |
| **DDD — Domain Service** | `Focus.assert` / `Focus.withRetry`, `AXTitles.resolve`, `WorkspaceCatalog` reconciliation, `DisplayGeometry` queries, `gridScaledWindowRect` |
| **DDD — Domain Event** | `BackendEvent` (consumed via `AsyncStream`) |
| **DDD — Bounded Context** | one binary = one context, no inter-context translation needed |

### Why no explicit Use Case layer

Strict Clean Architecture splits *application logic* (use cases /
interactors) from *coordination* (controller). facet collapses
both into `Controller` because at the current view count (3 — tree,
grid, rail) the use-case shapes are 1-line wrappers around backend
calls plus AX retry — a separate layer would be 100% boilerplate.

The third view (rail, #109) landed without duplicating an operation
across view code paths, so YAGNI still holds. If a fourth view lands
(dock, palette, hover-bar) **and**
the same operation (e.g. "switch + focus this window") starts
appearing in two view code paths, that's the signal to extract a
`FacetUseCases` module. Until then, the rule is YAGNI (memory:
[[design-principles]]).

### Why no ViewModels

Clean Architecture / MVVM patterns usually put a ViewModel
between the View and the Use Case. facet's views are `NSView`
subclasses (AppKit), not SwiftUI — the natural seam between
view-state and command dispatch is the `TreeController` /
GridView-callbacks protocol, which is doing the ViewModel's job
without the boilerplate of a separate type. Same YAGNI logic
applies; revisit when a view needs to be shared across multiple
windows or hosts.

## Non-goals

- **SIP-disabled features in `facet`** — out of scope.
  Mouse-follows-focus / true hide / programmable mac desktops / etc.
  all require SIP off + Dock.app injection, which conflicts with
  facet's "釈迦の掌の上" philosophy (`facet-buddha-palm-principle`).
  If a user genuinely needs them, the answer is a separate
  fork — not a bolt-on in this repo (`facet-deep-core-deferred-to-fork`
  memory).
- **Cross-platform** — macOS-only. Swift + native APIs are the
  comfortable spot.
- **Keyboard shortcut management** — out of scope. facet exposes
  CLI; users wire shortcuts via skhd / Karabiner-Elements /
  hammerspoon (see `facet-cli-surface` memory). This mirrors
  yabai's separation from skhd.
- **App-based rules engine** ("Chrome → WS 2", etc.) — out of
  scope. facet operates window-by-window. New windows land in the
  current active WS; user moves them with `facet window
  --move-to=N`.
- **Persistence of workspace state across restart** — out of
  scope for facet itself. WS names persist via `[desktop.N]`
  config (read-only seed); runtime layout / catalog mutations
  are session-only by design.
- **Plugin / extension system, menubar icon, system notifications,
  theme editor GUI, window snapping, global hotkey reservation,
  screen recording, animation customization, UI translation
  (i18n)** — all 9 explicitly rejected 2026-05-24
  (`facet-scope-exclusions` memory). Compose with shell tools or
  do without.

