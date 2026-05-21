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

## Install

Once M3 lands (Homebrew tap available):

```sh
brew install akira-toriyama/tap/facet
curl --create-dirs -o ~/.config/facet/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/facet/main/config.toml
```

The `curl` line drops a fully-commented [config.toml](config.toml)
into place; defaults are sane and the app starts with the tree
sidebar straight away. Edit it to switch the default view, change
theme, columns, label position, etc. — see the file's comments
for each option.

## Configuration

facet reads `~/.config/facet/config.toml` (single source of truth)
and never writes to it. See [config.toml](config.toml) at the repo
root for every option + inline docs. Runtime CLI overrides
(`facet --theme=cute` etc.) apply for the current session only;
edit the file to make a change stick.

## CLI

facet is **CLI-driven**: a small set of flags posts a distributed
notification to the running server. Bind these from whatever
hotkey tool you already use (skhd, Karabiner, Raycast,
Hammerspoon, macOS Shortcuts, …).

```sh
# Symmetric per-view ops (canonical):
facet --view=tree                 # show the tree sidebar (idempotent)
facet --view=tree --active        # show + keyboard-nav mode
facet --view=grid                 # open the overview grid (idempotent)
facet --hide=tree                 # hide tree
facet --hide=grid                 # close grid
facet --toggle=tree               # toggle tree visibility
facet --toggle=grid               # toggle grid visibility

# Aliases (shorthand for the common "tree" view):
facet --show     # = --view=tree
facet --hide     # = --hide=tree
facet --toggle   # = --toggle=tree
facet --active   # = --view=tree --active

# Server controls:
facet --theme=NAME                # terminal | cute | system
facet --quit                      # terminate the running server
```

Unknown view / theme names exit `2` with a stderr message — typos
fail loudly rather than silently no-op.

## Debugging

Start facet with `--debug` to mirror everything that goes into
`/tmp/facet.log` to stderr as well, and to turn on verbose
tracing (refresh ticks, backend commands, focus retries, grid
DnD events, …):

```sh
.build/release/facet --debug              # foreground — events scroll live
.build/release/facet --debug 2>&1 | tee bug.log   # capture for an issue
```

`--debug` only takes effect at server startup (it's a no-op when
combined with client-mode flags like `--show`). Without it the
app stays quiet on stderr and `Log.debug` calls are zero-cost.

## Build from source

```sh
./run.sh             # build release → kill any running instance → launch Facet.app
./run.sh --dev       # same but builds Facet-dev.app (parallel bundle id;
                     #   coexists with a Homebrew install for TCC isolation)
./stop.sh            # kill any running facet (release / dev / raw SwiftPM)
```

`./run.sh` is the day-to-day rebuild loop — bumps the bundle,
swaps it in, brings it on screen. `./stop.sh` is the "I lost
track of what's running" escape hatch.

Just verifying without a bundle:

```sh
swift build          # compile only
swift test           # XCTest — needs Xcode (CLT has none)
```

## Why "facet"

The user views every workspace as **the same data, just shown from
different angles**: a row in a sidebar, a tile in a grid, a chip in
a dock, etc. Each surface is a **facet** of the workspace model.
The architecture mirrors that: one core, many adapters, many views.

## License

[MIT](LICENSE) © akira-toriyama
