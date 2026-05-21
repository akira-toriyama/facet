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
| **M5+** | Native adapter Phase α–ε (long arc, no deadline) | see below |

## Native adapter phases

The SIP-enable boundary is firm: facet runs in user space, using only
public APIs + Accessibility. No yabai-style injection. This matches
how rift / aerospace operate today.

| Phase | Scope | Reference reading |
|---|---|---|
| **α** | virtual workspace concept self-managed; focus tracking | rift `workspace` module |
| **β** | window move across workspaces; off-screen park/unpark | rift `wm/window`, yabai window mgmt |
| **γ** | window tiling (BSP / stack layout engines) | rift `layout`, AeroSpace tree |
| **δ** | display reconfigure handling; geometry persistence | rift `display` |
| **ε** | deprecate `FacetAdapterRift`; native becomes default | — |

Each phase is gated by being usable end-to-end through the view layer
— no Phase α–δ landings ship unless the existing UI still works
against them.

## Non-goals

- **SIP-disabled features** (mouse-follows-focus via injection, etc.)
  — out of scope, by design.
- **Cross-platform** — macOS-only. Swift + native APIs are the
  comfortable spot.
- **Multi-app monorepo** — one product, multiple views, single
  binary. Decided 2026-05-21 (the modular layout above achieves
  separation without the overhead of multiple bundles / TCC grants).
- **Migration path for ws-tabs Homebrew users** — explicit
  non-requirement (user decision 2026-05-21). They reinstall as
  facet when M3 lands.

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
