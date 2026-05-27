# facet

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-alpha-orange)

**English** · [日本語](README.ja.md)

A Swift workspace + window manager for macOS. The same workspace
model viewed through pluggable surfaces — a translucent tree
sidebar, a TS3-style full-screen overview grid, and future docks /
hovers / palettes — all driven by a native AX/CGS backend with no
external dependency.

facet is the architectural successor to
[ws-tabs](https://github.com/akira-toriyama/ws-tabs). The grid view
DnD from ws-tabs v1.6 (which revived TS3's "drag windows between
Spaces" UX that macOS broke in Big Sur) is lifted in alongside
a clean three-layer split. See [docs/architecture.md](docs/architecture.md).

## What it does

facet runs as a menu-bar-less agent (`LSUIElement`) and surfaces
your workspaces through one of two views — your choice at startup
via [`config.toml`](config.toml):

- **Tree** — a translucent always-on-top sidebar listing every
  workspace and its windows as a tree. Click rows to focus,
  drag rows to move windows between workspaces, hover for a live
  on-screen preview.
- **Grid** — a full-screen TS3-style overview with one cell per
  workspace, real ScreenCaptureKit thumbnails, and DnD between
  cells (window move on plain drag; entire-cell swap on
  Shift+Drag). The grid is summoned on demand
  (`facet --view=grid`) and dismissed with Esc / backdrop click.

Both views share the same backend and the same theme
(terminal / cute / system, live toggleable).

## Interactions

| Action | Result |
|---|---|
| Click a window row (tree) | switch to its workspace + focus that exact window |
| Click a workspace header (tree) | switch to that workspace |
| Drag a window row onto another workspace (tree) | move that window |
| Drag empty space (tree) | reposition the panel — position persists |
| Right-click (tree) | context menu — window actions / workspace layout picker |
| Hover a window row (tree, macOS 14+) | live preview at the window's real position |
| Click a cell (grid) | switch to that workspace |
| Click a window thumb (grid) | switch + focus that window |
| Drag a thumb to another cell (grid) | move that window to that workspace |
| **Shift+Drag** a thumb (grid) | swap the entire contents of source ↔ destination cells |

Show / hide / toggle and keyboard mode are driven entirely from
the CLI — see [CLI](#cli) below.

### Keyboard navigation

The tree panel responds to keys whenever it has focus. Two ways
to get focus:

- **Click the panel** — passive `facet --view=tree` stays out of
  your way until you actually click it; the click both promotes
  the panel to key and enables keyboard nav. Releasing focus
  (clicking another app) drops nav cleanly, no key leak.
- **`--active` flag** — `facet --view=tree --active` takes focus
  *immediately* (one shortcut from your hotkey tool, no extra
  click). Trade-off: facet briefly becomes the active app
  (Dock + Cmd-Tab) while you're in nav; `Esc` exits and restores
  whatever was frontmost before.

| Key | Action |
|---|---|
| `↓`/`↑`, `Ctrl-N`/`Ctrl-P`, `j`/`k` | move between rows |
| `Tab`/`⇧Tab`, `→`/`←`, `l`/`h` | jump to the prev/next workspace |
| `s` | type-to-filter: fuzzy-search windows across all workspaces (real text field, IME works) |
| `Space` | open the selected row's context menu (keyboard-navigable: `↑↓`/`Return`/`Esc`) |
| `Return` | switch + focus (same as a click) |
| `Esc` | clear filter → leave keyboard mode (panel stays visible) |

Window titles are resolved via Accessibility (`kAXTitle`, matched
by CGWindowID, short-TTL cached). Rows without a resolvable title
stay compact. Requires Accessibility (same grant as clicks).

### Grid overview keyboard

| Key | Action |
|---|---|
| Arrows | move the cell cursor |
| `Tab` / `⇧Tab` | cycle window selection within the current cell |
| `Space` | lift the selected window for keyboard DnD; arrows re-aim, `Return` commits |
| `Shift+Space` | lift the entire cell's contents for swap |
| `Return` | commit a lift / switch when not lifted |
| `Esc` | cancel a lift / dismiss the overlay |

Cells paint with **ScreenCaptureKit thumbnails** (macOS 14+,
Screen Recording grant); a background refresh keeps them warm
so the overlay opens with real screenshots, not icon fallbacks.

## Status

**Alpha** — native AX backend, no external dependency. Workspace
switching, window park (anchor / minimize), BSP / stack tiling
with AX-role auto-float, and display reconfigure handling all
ship in the default build. `brew install akira-toriyama/tap/facet`
is live.

| Milestone | Status |
|---|---|
| M1 — repo scaffolded, `swift build` green | ✅ |
| M2 — tree + grid views working | ✅ |
| M3 — Homebrew tap (`brew install akira-toriyama/tap/facet`) | ✅ |
| M4 — ws-tabs archived | ✅ |
| M5 Phase α — native workspaces + focus + AX events | ✅ |
| M5 Phase β — anchor / minimize hide, closeWindow, setupFiles | ✅ |
| M5 Phase γ — BSP + stack tiling, AX-role auto-float, tiling CLI | ✅ |
| M5 Phase δ — display reconfigure | ✅ |
| M5 Phase ε — native sole backend (v2.0.0) | ✅ |

See [docs/architecture.md](docs/architecture.md) for the layer
diagram and the migration plan.

## Install

```sh
brew install akira-toriyama/tap/facet

# facet is a GUI agent — installing doesn't launch it. Open the app once:
open "$(brew --prefix)/opt/facet/Facet.app"

# Drop a fully-commented config into place (sane defaults):
curl --create-dirs -o ~/.config/facet/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/facet/main/config.toml
```

On first launch, grant **Accessibility** to *facet* (System
Settings → Privacy & Security → Accessibility) or clicks/drags
won't work; grant **Screen Recording** too if you want grid-view
thumbnails.

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

Frequently-touched keys:

- `[appearance] theme` — `terminal` (default) / `cute` / `system`
- `[layout] default_view` — `tree` / `grid`
- `[workspace] hide_method` — `anchor` (default, 1×41 px corner park,
  instant) / `minimize` (Dock genie, cleaner but slower).
- `[workspace]` table — `1 = "dev"`, `2 = "ide"`, … (1-indexed,
  sparse OK; missing slots → `N` invalid for `--workspace=N`).
- `[workspace] setupFiles = [...]` — array of executable script
  paths run once at startup, Vitest-style. See "Workspace setup
  hooks" below.

### Workspace setup hooks

facet itself never persists window-to-workspace assignments. The
`setupFiles` config key lets your own scripts recreate whatever
layout you want on launch — they fire **after** facet's CLI
listener is up, so they can immediately call `facet status` /
`facet --workspace=N` / `facet window --move-to=N` like any other
hotkey would.

```toml
[workspace]
setupFiles = ["~/.config/facet/setup.sh"]
```

```sh
# ~/.config/facet/setup.sh (chmod +x)
#!/usr/bin/env bash
# Pre-stage apps into the workspaces they belong in. New windows
# always land in the currently-active facet WS, so the trick is:
# switch first, then `open` — the launched app's first window
# inherits the current WS.
facet --workspace=2 && open -ga Slack
sleep 0.4               # let Slack's window register
facet --workspace=1 && open -ga "Safari"
sleep 0.4
facet --workspace=1     # finish on the WS you want to look at
```

(`facet window --move-to=N` operates on the focused window only —
there's no `--id` flag today, so the pre-stage pattern is the
honest tool for shaping startup state.)

Notes:
- `~` and `$VAR` / `${VAR}` in paths are expanded.
- Each script must be executable (`chmod +x`).
- Fire-and-forget after spawn — a hung script can't stall facet
  startup. Errors (missing file, non-executable, non-zero exit)
  show up in `facet status`'s `lastError` slot.
- Re-invoked on full restart only; `facet --reload` skips them
  by design.
- stdout / stderr is captured to `/tmp/facet.log` (visible under
  `facet --debug`).

## CLI

facet is **CLI-driven**: a small set of flags posts a distributed
notification to the running server. Bind these from whatever
hotkey tool you already use (skhd, Karabiner, Raycast,
Hammerspoon, macOS Shortcuts, …). Full cheatsheet:
`facet --help`.

```sh
# Per-view ops — NAME ∈ tree | grid, required for every op.
facet --view=NAME [--active]      # open NAME (idempotent)
facet --hide=NAME                 # close NAME
facet --toggle=NAME               # toggle NAME

# Tiling (M5 Phase γ)
facet --set-layout=NAME              # active WS mode (bsp | stack | float)
facet --retile                       # re-apply active WS's layout (bsp or stack)
facet window --toggle-float          # flip focused window float flag
facet window --toggle-orientation    # rotate focused window's parent split (bsp)
facet window --cycle-stack=next|prev # rotate stack to next / previous member

# --active is a modifier — only meaningful with --view=tree.
# Without it the tree panel still gains keyboard nav as soon as
# you click it; --active just takes focus immediately so a hotkey
# invocation jumps straight into nav (Spotlight-style). With
# --view=grid it's silently ignored; the overlay is always
# key/active by construction.

# Workspace ops (M5 Phase α)
facet --workspace=N               # switch to workspace N (1-indexed)
facet window --move-to=N          # move focused window to workspace N
facet status                      # snapshot: backend, hide_method,
                                  # workspaces, lastError, timestamp

# Server controls
facet --theme=NAME                # terminal | cute | system
facet --reload                    # re-read config.toml + apply
                                  # (theme / hide_method / [workspaces])
facet --quit                      # terminate the running server
facet --debug                     # verbose log to stderr +
                                  # /tmp/facet.log (server-mode)
facet --resign                    # re-sign Facet.app (after brew install)
facet --help                      # full reference
```

Unknown flag / view / theme names exit `2` with a stderr
message — typos fail loudly rather than silently no-op. Shorthand
(shell aliases / hotkey bindings) is your environment's job, not
facet's.

### Hotkey integration

facet exposes only a CLI surface — pick whatever hotkey tool
you already trust. Quick examples:

**skhd** (`~/.config/skhd/skhdrc`):

```
ctrl + alt - 1          : facet --workspace=1
ctrl + alt - 2          : facet --workspace=2
ctrl + shift + alt - 1  : facet window --move-to=1
ctrl + shift + alt - 2  : facet window --move-to=2
```

**Karabiner-Elements**: bind shell commands via the *Complex
Modifications* JSON (`shell_command`: `/opt/homebrew/bin/facet
--workspace=1`).

**Hammerspoon**: `hs.hotkey.bind({"ctrl","alt"}, "1", function()
hs.execute("/opt/homebrew/bin/facet --workspace=1") end)`.

### Workspace shell helpers

facet itself never writes to your `config.toml`. Repo-local
shell scripts handle the writes atomically (memory contract:
`mktemp` + `mv` so the auto-reloader never sees half-written
state):

```sh
./scripts/add_workspace.sh 1 dev      # adds 1 = "dev" to [workspace]
./scripts/add_workspace.sh 5          # empty name, just creates slot
./scripts/remove_workspace.sh 2       # removes entry 2 (idempotent)
```

facet's `ConfigWatcher` picks up the change automatically;
`facet --reload` is the explicit-trigger alternative if your
script wants a deterministic moment.

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

## Honest limitations

- **Apple Silicon only**. Intel Macs are out of scope.
- **Multi-display layout / preview positioning is lightly tested**
  — the primary dev box is single-display. File issues with repro
  steps if you hit oddness on multi-monitor setups.
- **Window preview is macOS 14+** and needs Screen Recording.
- **Ad-hoc signed builds re-prompt** for Accessibility on every
  rebuild. Run `./setup-signing-cert.sh` once for a persistent
  self-signed identity that keeps the TCC grant stable across
  rebuilds (Homebrew install gets ad-hoc — re-prompts on
  upgrade — because the install subprocess can't reach the
  login keychain).
- **Drop target is by vertical band of a workspace** in the
  tree view; dropping onto an empty workspace works (its header
  band is the target).
- **WS-wide preview** (hovering a workspace header) renders one
  overlay per window in that workspace, captured in parallel —
  cost scales with window count; 10+ windows briefly spike CPU
  on first hover.
- **Tunables live in `Sources/Facet*/Tunables.swift`** per
  module. Prefer adjusting those constants over scattering
  literals.

## Why "facet"

The user views every workspace as **the same data, just shown from
different angles**: a row in a sidebar, a tile in a grid, a chip in
a dock, etc. Each surface is a **facet** of the workspace model.
The architecture mirrors that: one core, many adapters, many views.

## License

[MIT](LICENSE) © akira-toriyama
