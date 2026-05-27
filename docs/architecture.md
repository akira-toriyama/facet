# facet — architecture

facet is a Swift workspace + window manager for macOS, built as the
spiritual successor to [ws-tabs](https://github.com/akira-toriyama/ws-tabs).
The split into **Core / Adapter / View** is the central design idea:
the same pure-logic core can drive multiple UI surfaces (tree
sidebar, full-screen overview grid, future docks/hovers), and the
same UI works against multiple backends (`rift-cli` today, native
AX/CGS later).

## Layers

```
┌─────────────────────────────────────────────────────────┐
│  FacetViewTree         FacetViewGrid     (future ...)   │  view
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
       ┌───────────────┴───────────────┐
       │                               │
┌──────┴────────────┐         ┌────────┴──────────┐
│  FacetAdapterRift │         │ FacetAdapterNative│  adapter
│   (rift-cli IPC)  │         │  (AX / CGS / SLS) │
└───────────────────┘         └───────────────────┘
```

`FacetCore` defines a `WindowBackend` protocol (workspaces, move,
focus, switch, layout, display, event stream, …). Adapters implement
it. The app picks an adapter at startup and the rest of the code is
unaware which one is in use.

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

## Migration milestones (from ws-tabs)

| Phase | Goal | Done when |
|---|---|---|
| **M1** | Repo scaffolded, multi-target Package.swift builds | `swift build` / `swift test` green |
| **M2** | tree + grid views + CLI working through `FacetAdapterRift` | feature parity with ws-tabs v1.6 |
| **M3** | Homebrew tap entry (under existing `akira-toriyama/homebrew-tap`) | `brew install akira-toriyama/tap/facet` works |
| **M4** | ws-tabs **archived** (README links forward to facet) | ws-tabs README updated, repo archived on GitHub |
| **M5+** | Native adapter Phase α–ε (long arc, no deadline) — **surface-core**. α/β/γ shipped, δ/ε pending | see below |
| **M6+** | **deep-core (`facet-x`) — SIP-off opt-in binary, MVP = 完全 hide のみ** | see [`facet-sip-off-core-plan` memory] |

## Native adapter phases

The SIP-enable boundary is firm **for surface-core (`facet`)**:
runs in user space, using only public APIs + Accessibility. No
yabai-style injection. This matches how rift / aerospace operate
today. SIP-off opt-in lives in **deep-core (`facet-x`)** as a
separate binary, scheduled for M6+ (see [Two-binary structure]
below).

| Phase | Scope | Reference reading |
|---|---|---|
| **α** | virtual workspace concept self-managed; focus tracking. **Frozen 2026-05-24**: (b) hybrid model (macOS Space × facet Space), default 5 WS dynamic, hide method = `anchor` (default 1×41 px) + `minimize` (option), CLI = `facet --workspace=N`. **Status (2026-05-26)**: workspace state + reconcile + focusedWindow + AX-driven event subscription landed (`FACET_BACKEND=native` opt-in usable) | rift `workspace` module, AeroSpace `MacWindow.hideInCorner` |
| **β** | window move across workspaces; off-screen park/unpark; closeWindow; persistence (external sh hook). **Status (2026-05-26)**: anchor hide / minimize hide / closeWindow + windowMenu Close + setupFiles startup hook all landed | rift `wm/window`, yabai window mgmt |
| **γ** | window tiling (BSP / stack layout engines). **Frozen 2026-05-26; γ.1 / γ.2 / γ.3 all shipped (PR #44 / #45 / #46)**: BSP + stack only, always-on auto-tile, auto-balance split, lazy retile, per-WS mode (default `"float"`), `LayoutTree` value type, 5 CLI verbs, AX-role auto-float for sheets / dialogs / palettes | rift `layout`, AeroSpace tree |
| **δ** | display reconfigure handling; persistence-aware geometry (no new state). **Frozen 2026-05-27**: `didChangeScreenParameters` listener, active WS re-tile, anchor-parked rescue to nearest visible display, panel snap to nearest display, pure helpers in `DisplayGeometry`. Single-display dev environment so multi-display polish is rescue-helpers-only | rift `display` |
| **ε** | deprecate `FacetAdapterRift`; native becomes default | — |

Each phase is gated by being usable end-to-end through the view layer
— no Phase α–δ landings ship unless the existing UI still works
against them.

### Phase α frozen decisions (2026-05-24)

Phase α design is fully decided. Details live in memory; this list
is the index. **Do not relitigate** without explicit grill round.

- **Workspace model**: (b) rift-style hybrid (macOS Space × facet
  Space, 2 dimensions). macOS Space co-use discouraged but not
  rejected. Window-unit management (not app-rules). Default 5 WS,
  dynamic add/remove via external `add_workspace.sh` + hot reload.
- **Hide methods**: 7 candidates evaluated, only `anchor` (1×41 px
  corner park) + `minimize` (Dock genie) adopted. Config:
  `[workspace] hide_method = "anchor" | "minimize"`. Default
  `anchor` (instant switching). True hide (MC/Cmd-Tab disappearance)
  is impossible in public API — comes from deep-core (M6+).
- **CLI surface**: `--workspace=N` switch, `window --move-to=N`
  move, `--reload` explicit + auto FSEvents watcher, `status` for
  state dump. TOML atomic write enforced in shipped templates.
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
- **Persistence**: not in facet. External sh hook via
  `setupFiles` config key (Vitest-style).
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
  parked via the configured `hide_method`. `cycleStackNext` /
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
  parks all but focused (via `hide_method`); the reverse
  re-inserts members in focus order via auto-balance. **Default
  mode for a new WS = `"float"`** (not `"bsp"`) so existing
  users see no surprise behaviour; opt-in per WS via
  `facet --set-layout=bsp`.
- **CLI surface (5 new verbs)**:
  - `facet --set-layout=NAME` — active WS mode (`bsp` / `stack` / `float`)
  - `facet --retile` — recompute + re-apply the active WS layout
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
  persistence, setupFiles only" is preserved).
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

## Two-binary structure (surface-core + deep-core)

Decided 2026-05-24. facet is **1 repo / 2 products** rather than
the original "1 product / many views" formulation. The view-multiplicity
half is unchanged; the second product is the SIP-off opt-in cousin.

```
Sources/Facet{Surface,Deep}Core/   ← Domain logic, 2 parallel cores
Sources/FacetAdapter{Rift,Native}/ ← surface-core adapters
Sources/FacetAdapterDeep/          ← deep-core adapter (M6+)
Sources/FacetView*/                ← shared by both cores
Sources/FacetApp/                  ← `facet` binary (surface-core)
Sources/FacetXApp/                 ← `facet-x` binary (deep-core, M6+)
```

| Aspect | surface-core (`facet`) | deep-core (`facet-x`) |
|---|---|---|
| API surface | public AX + CGS-light | private SLS + scripting addition |
| SIP | enable | off (Dock.app injection on install) |
| Distribution | `brew install facet` | `brew install facet-x` (depends on `facet`) |
| Code signing | notarized | ad-hoc / self-signed |
| Hide capability | 1×41 px sliver (anchor) or Dock minimize | true hide (MC + Cmd-Tab clean) |
| Phase | M5 (now) | M6+ (after surface-core completes) |
| Governs | `facet-buddha-palm-principle` (OS humility) | separate principle (TBD at M6) |

The two cores share `FacetView*` + theme + palette + key
monitor + config schema. They do **not** share Core logic — the
workspace invariants differ (e.g. "hide" means different things).

While implementing surface-core (now), keep adapter seams clean
(DRY) so deep-core can slot in later without surface-core surgery —
but **don't pre-implement deep-core features** (YAGNI). Details:
`facet-sip-off-core-plan` memory.

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
| **Clean Architecture — Platform / Infrastructure** (Repository impl) | `FacetAdapterRift` (`RiftAdapter`, `RFTypes`, `RiftMapper`, `EventSource`) |
| **Clean Architecture — Frameworks & Drivers** (UI) | `FacetView`, `FacetViewTree`, `FacetViewGrid` (AppKit-bound) |
| **Clean Architecture — Application** (DI + Coordinator) | `FacetApp` (`Controller` + `Main`) |
| **Clean Architecture — Use Case (Interactor)** | *NOT a separate layer* — see below |
| **DDD — Entity** | `Workspace`, `Window` |
| **DDD — Value Object** | `WindowID`, `Palette`, `FontKind`, `CGRect`, `GridConfig` |
| **DDD — Aggregate Root** | `Workspace` (owns its `windows`) |
| **DDD — Repository** | `WindowBackend` protocol |
| **DDD — Domain Service** | `Focus.assert` / `Focus.withRetry`, `AXTitles.resolve`, `RiftMapper.workspace(from:)`, `gridScaledWindowRect` |
| **DDD — Domain Event** | `BackendEvent` (consumed via `AsyncStream`) |
| **DDD — Bounded Context** | one binary = one context, no inter-context translation needed |

### Why no explicit Use Case layer

Strict Clean Architecture splits *application logic* (use cases /
interactors) from *coordination* (controller). facet collapses
both into `Controller` because at the current view count (2 — tree
+ grid) the use-case shapes are 1-line wrappers around backend
calls plus AX retry — a separate layer would be 100% boilerplate.

If a third / fourth view lands (dock, palette, hover-bar) **and**
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

- **SIP-disabled features in `facet`** — out of scope for
  surface-core. Mouse-follows-focus / true hide / programmable
  Spaces / etc. all require SIP off + Dock.app injection. Such
  features belong in the separate `facet-x` binary (deep-core,
  M6+) so users can choose their threat model. See [Two-binary
  structure] above.
- **Cross-platform** — macOS-only. Swift + native APIs are the
  comfortable spot.
- **Single binary "do everything"** — explicitly rejected
  2026-05-24. Two binaries (`facet` / `facet-x`) with brew
  dependency keeps the surface-core install clean for users who
  don't want SLS code on their machine.
- **Migration path for ws-tabs Homebrew users** — explicit
  non-requirement (user decision 2026-05-21). They reinstall as
  facet when M3 lands.
- **Keyboard shortcut management** — out of scope. facet exposes
  CLI; users wire shortcuts via skhd / Karabiner-Elements /
  hammerspoon (see `facet-cli-surface` memory). This mirrors
  yabai's separation from skhd.
- **App-based rules engine** ("Chrome → WS 2", etc.) — out of
  scope. facet operates window-by-window. New windows land in the
  current active WS; user moves them with `facet window
  --move-to=N`.
- **Persistence of workspace state across restart** — out of
  scope for facet itself. External shell hooks (Vitest-style
  `setupFiles` config) let users snapshot/restore if needed.
- **Plugin / extension system, menubar icon, system notifications,
  theme editor GUI, window snapping, global hotkey reservation,
  screen recording, animation customization, UI translation
  (i18n)** — all 9 explicitly rejected 2026-05-24
  (`facet-scope-exclusions` memory). Compose with shell tools or
  do without.

## Where pieces come from in ws-tabs

| ws-tabs path | facet target |
|---|---|
| `SidebarView` + handle drag / DnD logic | `FacetViewTree` |
| `GridView` + GridOverlay, `FacetCore` drag-state lifecycle | `FacetViewGrid` |
| `Controller`, `RiftBackend` (rift-cli spawn / event subscribe) | `FacetAdapterRift` + `FacetApp` |
| `Palette`, `pal`, theme system, `uiFont` | `FacetView` |
| `WsTabsConfig` (TOML), `parseTOMLSubset` | `FacetCore` |
| `WindowPreview` (ScreenCaptureKit), AX titles | `FacetView` (capture) + `FacetCore` (state) |
| Pure-logic tests | `Tests/FacetCoreTests` |

Migration is **code copy + restructure** — git history is not
preserved. ws-tabs the repo will be archived once facet reaches
feature parity (M4).
