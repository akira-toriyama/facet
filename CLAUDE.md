# CLAUDE.md

Guidance for working in this repository.

## What this is

`facet` — Swift workspace + window manager for macOS. **Architectural
successor to [ws-tabs](https://github.com/akira-toriyama/ws-tabs)**: 1
binary, multiple views (`--view=tree|grid|…`), 1 backend at a time
(`rift-cli` adapter today, native AX/CGS adapter in M5+). Swift 6,
macOS 13+. See [docs/architecture.md](docs/architecture.md) for the
layer diagram.

## Build / run

```sh
swift build                # compile (works on CommandLineTools)
swift test                 # tests — needs Xcode (XCTest); fails on CLT
.build/debug/facet         # bootstrap stub output until M2 wires views
```

`swift test` does NOT work on CommandLineTools-only setups (`no such
module 'XCTest'`). Same constraint as ws-tabs — tests run in CI
([build workflow lands in M2 step 7](docs/architecture.md)). Locally,
`swift build` is the bar; let CI cover XCTest.

`@main enum FacetApp` lives in
[Sources/FacetApp/Main.swift](Sources/FacetApp/Main.swift) (NOT
top-level code in a `main.swift`) so XCTest's executable-target
`@testable import` keeps working once tests land. **Don't reintroduce
a `main.swift` file** — same trap as ws-tabs.

## Non-obvious constraints — read before editing

### Layer rules (the spine of the project)

- **3 layers are non-negotiable**: `FacetCore` is pure logic
  (CoreGraphics OK, NO AppKit / NO backend / NO OS interaction).
  `FacetAdapter*` wraps a backend (rift-cli, AX, …) and is the
  *only* place those types appear. `FacetView*` is GUI-only.
  Crossing layers always means there's a missing protocol.
- **`RF*` types stay inside `FacetAdapterRift`**.
  [Sources/FacetAdapterRift/RFTypes.swift](Sources/FacetAdapterRift/RFTypes.swift)
  is internal-by-design.
  [Sources/FacetAdapterRift/Mapper.swift](Sources/FacetAdapterRift/Mapper.swift)
  converts to the backend-neutral
  [Sources/FacetCore/Models.swift](Sources/FacetCore/Models.swift)
  types at the seam. Views and controller must never see `RFWorkspace`.
- **Views talk to the `WindowBackend` protocol, never to
  `RiftAdapter` directly**. This is what lets M5+ swap in
  `FacetAdapterNative` without touching a single view file.

### Ported from ws-tabs — keep the contracts intact

- **`pal` is a `@MainActor` module-level var in
  [Sources/FacetView/Theme.swift](Sources/FacetView/Theme.swift)**.
  The symbol name is preserved deliberately — every lifted view file
  references `pal.text`, `pal.dim`, etc. in dozens of places. Don't
  rename it to `Theme.current` or similar; it would touch ~hundreds
  of view-side lines for zero behavior gain.
- **`Palette` presets (`.terminal` / `.cute` / `.system`) are
  `@MainActor`** because `NSColor` is not `Sendable` under Swift 6
  strict concurrency. Don't try to make them ordinary top-level
  `let`s.
- **Window titles are AX-resolved when rift returns blank**. rift's
  `query workspaces` returns empty `title` for many apps (Chrome,
  Code, …). `AXTitles.resolve` reads `kAXTitle` directly, short-TTL
  cached, only off-main. Don't assume `Window.title` is populated by
  the backend alone. (Memory:
  [[window-titles-AX-resolved]].)
- **`FlippedClipView` is used from day one**. ws-tabs's 2026-05-21
  "intermittent grip drag failure" traced back to a non-flipped
  `NSClipView` (memory [[grid-branch-grip-intermittent]]). Adopt
  `FlippedClipView` for every scroll view, not "once we hit the
  same bug."
- **The drag-state lifecycle is a backend round-trip flag**, not a
  mouse-event flag. Don't clear it on `mouseUp` — clear it when the
  backend confirms the move. Memory:
  [[grid-drag-state-lifecycle]].

### M2 / M5 boundaries

- **`/opt/homebrew/bin/rift-cli` is hard-coded** in
  [Sources/FacetAdapterRift/RiftCLI.swift](Sources/FacetAdapterRift/RiftCLI.swift).
  Don't add configurability — M5+ replaces this entire module with
  `FacetAdapterNative` (Phases α–ε). Engineering effort on this
  module has a sunset date.
- **AX helpers (focus + title resolution) live in
  `FacetAdapterRift` for now**. They aren't actually rift-specific
  (any backend benefits from AX) — they'll move to a shared
  `FacetAccessibility` module when the native adapter arrives
  (M5+). Place new AX code there, marked with a `// MOVE-AT-M5`
  comment if it would belong in the shared module.
- **Bundle id will be `com.facet.app`** once
  [package.sh](packaging/) lands in M2 step 8. NOT `com.wstabs.app`
  — separate TCC grants, separate self-signed cert. Don't reuse
  ws-tabs's id even temporarily.

### Workflow

- **Don't push without explicit OK**. Quality-first phased
  workflow inherited from ws-tabs (memory
  [[grid-view-work-style]]). Commit locally freely; pushing /
  merging waits for トミー's go.
- **Migration is code copy + restructure**, NOT git history merge.
  ws-tabs gets archived (M4) — don't pull commits from it.

## Conventions

- **Commit messages**: gitmoji + Conventional Commits —
  `<:gitmoji:> <type>(<scope>)<!>: <subject>`. Full spec:
  [docs/commit-convention.md](docs/commit-convention.md). Enable
  the local hook: `git config core.hooksPath scripts/hooks` (script
  lands in M2 step 8).
- **README is bilingual** ([README.md](README.md) English +
  [README.ja.md](README.ja.md) Japanese). Keep them in sync when
  user-visible behavior changes. Memory [[readme-bilingual]].
- After source edits, **`swift build` must pass** before finishing
  a turn.
