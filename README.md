# facet

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-bootstrap-yellow)

**English** · [日本語](README.ja.md)

A Swift workspace + window manager for macOS. The same workspace
model viewed through pluggable surfaces — a translucent tree
sidebar, a TS3-style full-screen overview grid, and future docks /
hovers / palettes — all driven by a swappable backend (`rift-cli`
today, native AX/CGS later).

facet is the architectural successor to
[ws-tabs](https://github.com/akira-toriyama/ws-tabs). The grid view
DnD from ws-tabs v1.6 (which revived TS3's "drag windows between
Spaces" UX that macOS broke in Big Sur) is being lifted in alongside
a clean three-layer split. See [docs/architecture.md](docs/architecture.md).

## Status

**Bootstrap** — the multi-target SwiftPM scaffolding is in place
but the views/adapters are not migrated yet. Track:

| Milestone | Status |
|---|---|
| M1 — repo scaffolded, `swift build` green | ✅ |
| M2 — tree + grid views working through `FacetAdapterRift` | 🚧 |
| M3 — Homebrew tap (`brew install akira-toriyama/tap/facet`) | ⏳ |
| M4 — ws-tabs archived | ⏳ |
| M5+ — `FacetAdapterNative` Phases α–ε | ⏳ |

See [docs/architecture.md](docs/architecture.md) for the layer
diagram and the migration plan.

## Build

```sh
swift build
swift test
```

That's it for now — there's no app bundle until the views land in M2.

## Why "facet"

The user views every workspace as **the same data, just shown from
different angles**: a row in a sidebar, a tile in a grid, a chip in
a dock, etc. Each surface is a **facet** of the workspace model.
The architecture mirrors that: one core, many adapters, many views.

## License

[MIT](LICENSE) © akira-toriyama
