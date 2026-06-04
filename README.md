# facet

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![swift](https://img.shields.io/badge/Swift-6.0-orange)
![license](https://img.shields.io/badge/license-MIT-blue)
![status](https://img.shields.io/badge/status-alpha-orange)

**English** · [日本語](README.ja.md)

A Swift workspace + window manager for macOS. The same workspace
model viewed through pluggable surfaces — a translucent tree
sidebar, a full-screen overview grid, and future docks / hovers /
palettes — all driven by a native AX/CGS backend with no external
dependency. See [docs/architecture.md](docs/architecture.md) for
the layer diagram.

## What it does

facet runs as a menu-bar-less agent (`LSUIElement`) and surfaces
your workspaces through one of its views — tree or grid at startup
via [`config.toml`](config.toml), plus the on-demand rail overview:

- **Tree** — a translucent always-on-top sidebar listing every
  workspace and its windows as a tree. Click rows to focus, drag a
  window row to move it between workspaces, drag a workspace header
  (grip on the left) to swap two workspaces' contents, hover for a
  live on-screen preview.
- **Grid** — a full-screen overview with one cell per workspace,
  real ScreenCaptureKit thumbnails, and DnD between cells: drag a
  window thumb to move it, drag a cell's header to swap whole cells.
  The grid is summoned on demand (`facet --view=grid`) and dismissed
  with Esc / backdrop click.
- **Rail** — a full-screen Mission-Control-style workspace switcher: an
  active-centred **carousel** of window-thumbnail mini-screens in a
  strip along one screen edge, with the browsed workspace shown large in
  the centre. The active workspace is pinned to the strip centre and the
  rest fan out around it; the browse arrow keys (←/→ on a top/bottom
  rail, ↑/↓ on a left/right one) **rotate the strip** to bring another
  workspace to the centre, Return or a click switches to the centred one,
  Esc dismisses. Drag a window between workspaces or a header to swap.
  Dock the strip with `--edge=top|bottom|left|right` (default bottom).
  The thumbnails are justified to fill the strip with even gaps; `[rail]
  strip` caps their size (a percentage of the short screen edge — the
  hero fills the rest), so the split stays balanced in any orientation or
  on any display size. `[rail] cells` caps how many show at once; past
  that, workspaces rotate through (peeking at both ends). Summoned with
  `facet --view=rail`.

Drag-and-drop follows one model across the views: the **grabbed
target decides the action** — drag a window to move it, drag a
workspace header to swap the two workspaces' contents (the workspace
slots themselves don't move, so hotkey numbering is preserved). No
modifier keys.

All views share the same backend and the same theme
(17 built-in themes — terminal, nord, dracula, hacker, catppuccin,
mono-light, … plus `random` — live toggleable).

## Layouts

Each workspace runs a layout, set at runtime with
`facet workspace --layout=NAME` (per-WS, never persisted — set a
per-mac-desktop startup layout via `[desktop.N]` in
[`config.toml`](config.toml), e.g. `1 = { name = "Dev", layout =
"bsp" }`). facet
never hides windows, so a layout only *positions* them and the
focused window is always raised. Diagrams use four windows; **1** is
the master / focus where that matters.

The master sits on any of five edges — pick one directly with
`--layout=master-EDGE`. They share one geometry (opposite edges are
mirror images), differing only in where the master docks.

### `master-left` — master on the left
dwm `tile` / xmonad `Tall`. Master fills the left column (a tunable
fraction of the width); the rest stack as rows on the right. The
ultrawide bread-and-butter.

```
┌────────────┬───────────┐
│            │     2     │
│            ├───────────┤
│     1      │     3     │
│  (master)  ├───────────┤
│            │     4     │
└────────────┴───────────┘
```

### `master-right` — master on the right
`master-left` mirrored: master fills the right column, the stack rows
on the left.

```
┌───────────┬────────────┐
│     2     │            │
├───────────┤            │
│     3     │     1      │
├───────────┤  (master)  │
│     4     │            │
└───────────┴────────────┘
```

### `master-top` — master on top
`master-left` rotated 90°: master is the top row, the rest become
columns below.

```
┌─────────────────────────┐
│        1 (master)       │
├───────┬───────┬─────────┤
│   2   │   3   │    4    │
└───────┴───────┴─────────┘
```

### `master-bottom` — master on the bottom
`master-top` mirrored: master is the bottom row, the stack columns
above.

```
┌───────┬───────┬─────────┐
│   2   │   3   │    4    │
├───────┴───────┴─────────┤
│        1 (master)       │
└─────────────────────────┘
```

### `master-center` — master in the middle
dwm `centeredmaster` / xmonad ThreeColMid. Master centred; the rest
split between the left and right side columns (right fills first).
Built for ultrawide.

```
┌───────┬───────────────┬───────┐
│       │               │   2   │
│   4   │   1 (master)  ├───────┤
│       │               │   3   │
└───────┴───────────────┴───────┘
```

### `grid` — even tiles
awesome `grid`. A near-square grid (`ceil(√N)` columns); the last row
widens to fill.

```
 2 windows         3 windows          4 windows
┌─────┬─────┐    ┌─────┬─────┐      ┌─────┬─────┐
│  1  │  2  │    │  1  │  2  │      │  1  │  2  │
└─────┴─────┘    ├─────┴─────┤      ├─────┼─────┤
                 │     3     │      │  3  │  4  │
                 └───────────┘      └─────┴─────┘
```

### `spiral` — fibonacci
dwm `fibonacci`. Each new window halves the remaining space, winding
clockwise inward.

```
┌────────────┬───────────┐
│            │     2     │
│     1      ├─────┬─────┤
│            │  4  │  3  │
└────────────┴─────┴─────┘
```

### `bsp` — binary splits
bspwm-style. Each new window splits the focused tile in half
(auto-balanced by aspect); `--toggle-orientation` rotates the focused
split.

```
┌────────────┬───────────┐
│            │     2     │
│     1      ├─────┬─────┤
│            │  3  │  4  │
└────────────┴─────┴─────┘
```

### `stack` — full-screen focus
One window fills the screen; the rest are parked off-screen.
`--cycle-stack=next|prev` rotates which one is on top.

```
┌─────────────────────────┐    others (2, 3, 4) parked
│                         │    off-screen; cycle-stack
│       1  (front)        │    brings the next one forward
│                         │
└─────────────────────────┘
```

`float` (the default) applies no layout — windows stay where you put
them.

### Master-stack operations

The `master-*` layouts are adjustable at runtime (per workspace).
**Promote** the focused window to the master slot:

```
  before (focus 3)            after --promote (menu)
┌────────────┬───────┐      ┌────────────┬───────┐
│            │   2   │      │            │   1   │
│     1      ├───────┤  →   │     3      ├───────┤
│  (master)  │   3   │      │  (master)  │   2   │
└────────────┴───────┘      └────────────┴───────┘
```

**Resize** the master (`--grow-master` / `--shrink-master`, ±0.05)
and change **how many** windows share it (`--inc-master` /
`--dec-master`):

```
  --grow-master              --inc-master (2 masters)
┌──────────────┬─────┐      ┌────────────┬───────────┐
│              │  2  │      │     1      │     3     │
│      1       ├─────┤  →   │  (master)  ├───────────┤
│   (master)   │  3  │      │     2      │     4     │
└──────────────┴─────┘      │  (master)  │           │
                            └────────────┴───────────┘
```

## Interactions

| Action | Result |
|---|---|
| Click a window row (tree) | switch to its workspace + focus that exact window |
| Hide a window (⌘H / ⌘M) | tiled neighbours reclaim its slot; it stays in the tree dimmed with a `hidden` badge — click the row to restore it |
| Click a workspace header (tree) | switch to that workspace |
| Drag a window row onto another workspace (tree) | move that window in the background — no switch, focus stays put |
| Drag a workspace header onto another (tree) | swap the two workspaces' contents |
| Drag empty space, or ⌘-drag anywhere (tree) | reposition the panel (session-only — set `[tree]` geometry in config to pin it) |
| Double-click the panel header (tree) | reset position + size to the `[tree]` config geometry (or the built-in default) |
| Right-click (tree) | context menu — window actions / workspace layout picker |
| Hover a window row (tree, macOS 14+) | live preview — small popover next to the row by default; switch to `mirror` in `[tree] preview-mode` for full-size at the would-be on-screen frame |
| Click a cell (grid) | switch to that workspace |
| Click a window thumb (grid) | switch + focus that window |
| Drag a thumb to another cell (grid) | move that window to that workspace |
| Drag a workspace header onto another cell (grid) | swap the entire contents of the two cells |

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
| `Space` | lift the selected row for drag-and-drop — a window row moves, a workspace header swaps; then arrows aim the target workspace, `Return`/`Space` commits, `Esc` cancels |
| `m` | open the selected row's context menu (keyboard-navigable: `↑↓`/`Return`/`Esc`) |
| `Return` | commit a lift, or (not lifting) switch + focus like a click |
| `Esc` | cancel a lift → clear filter → leave keyboard mode (panel stays visible) |

Window titles are resolved via Accessibility (`kAXTitle`, matched
by CGWindowID, short-TTL cached). Rows without a resolvable title
stay compact. Requires Accessibility (same grant as clicks).

### Grid overview keyboard

| Key | Action |
|---|---|
| Arrows | move the cell cursor |
| `Tab` / `⇧Tab` | cycle the cursor through the header + windows of the current cell |
| `Space` | lift the selection for keyboard DnD — a window (move) or the header slot (whole-cell swap); arrows re-aim, `Return`/`Space` commits |
| `Return` | commit a lift / switch when not lifted |
| `Esc` | cancel a lift / dismiss the overlay |

Cells paint with **ScreenCaptureKit thumbnails** (macOS 14+,
Screen Recording grant); a background refresh keeps them warm
so the overlay opens with real screenshots, not icon fallbacks.

### Rail switcher keyboard

The rail takes key focus while it's up. Arrows browse along the
strip axis — `←`/`→` when docked top/bottom, `↑`/`↓` when docked
left/right.

| Key | Action |
|---|---|
| Arrows | rotate the strip — bring the prev/next workspace to the centre (or re-aim the target while carrying a lift) |
| `Tab` / `⇧Tab` | cycle the selection through the centred workspace's header + windows |
| `Space` | lift the selection for keyboard DnD — a window (move) or the header slot (whole-workspace swap); while carrying, `Space` drops |
| `Return` | commit a lift, or switch to the centred workspace |
| `Esc` | cancel a lift, then dismiss the rail |

## Install

```sh
brew install akira-toriyama/tap/facet

# Drop a fully-commented config into place (sane defaults) — do this
# BEFORE the first launch so facet reads it straight away:
curl --create-dirs -o ~/.config/facet/config.toml \
  https://raw.githubusercontent.com/akira-toriyama/facet/main/config.toml

# facet is a GUI agent — installing doesn't launch it. Open the app once:
open "$(brew --prefix)/opt/facet/Facet.app"
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

- `theme` (top-level) — 17 themes: `terminal` (default) / `nord` /
  `dracula` / `gruvbox` / `catppuccin` / `rosepine` / `everforest` /
  `solarized` / `onedark` / `monokai` / `hacker` / `cute` / `paper` /
  `system` / `mono-light` / `mono-dark` / `monotone`, plus `random`
  (picks one at each launch / `--reload`, excluding `system`)
- `default-view` (top-level) — `tree` / `grid`
- `[tree]` table — `preview-mode` (`popover` / `mirror`), plus the
  panel geometry seed `pos-x` / `pos-y` / `width` / `height` (screen
  points, **top-left origin**: 0,0 = top-left of the main screen, y
  down; all four needed). Authoritative each launch / `--reload`;
  drags / CLI geom are session-only, so set it here to pin the panel.
  Same coords as `facet --view=tree --pos-x/...`.
- `[layout]` table — `inner-gap` (space between tiled windows) and
  `outer-gap` (distance from the screen edges), in points. `outer-gap`
  sets all four edges; `outer-gap-top` / `-bottom` / `-left` /
  `-right` override individual edges. All default 0 (flush tiling);
  clamp to [0, 1000]. Applies to every layout; floating windows excluded.
  `smart-gaps` (default `false`) drops the outer gap when a workspace
  holds a single tiled window, so a lone window goes edge-to-edge.
- `[animation]` table — animate transitions instead of snapping.
  `enabled` (default `false` — opt in by setting `true`) is the master
  switch; `curve` picks the feel: `cubic` (default, ease-out), `spring`
  (bouncy), `silky` (smooth, longer), `snappy` (crisp), or `random` (one
  per transition). `duration-ms` overrides the length (clamp [80, 800]);
  unset = each curve's own default. `event-driven` (default `true` when
  the master is on) covers the background open / close reflow — set it
  to `false` to keep WS-switch + user-triggered retile animated but
  snap on background opens / closes. Covers the workspace switch
  (directional filmstrip slide), retile / layout change (in-place
  reflow), stack cycle (old top slides out / next slides in), and
  window open / close (existing tiled windows glide to their new sizes;
  the new window snaps to its tile slot). Pure public AX; macOS
  "Reduce motion" forces instant transitions regardless.
- `[border]` table — a neon border on every view (tree panel, plus a
  screen-edge frame on the grid overview + rail), layered on top of
  `theme`. `effect` = `off` (default) / `neon` / `cyber` /
  `vapor` / `kawaii` / `rainbow` / `random`; `glow` (default `true`)
  toggles the bloom; `width` sets the line width (px, clamp 0.5–30,
  default 1.5).
  The border flashes a neon burst on a workspace switch. `cycle-seconds`
  (clamp 1–120, default 6 — lower is faster) is the period of the
  continuous animation: `rainbow`'s hue rotation, and — when
  `min-width`/`max-width` are both set (max > min, each 0.5–30) — a
  width breath that oscillates the border between them (any effect,
  overriding the fixed `width`). Off shows a plain theme-accent border.
  `active-window = true` (default `false`) also rings the **focused
  window** of any app — managed or not — with this same style, moving +
  flashing as focus changes and hiding while a window is dragged /
  resized.
- `[[exclude]]` rules — keep popups / unnamed / auxiliary windows out
  of the tiling layout. Match by `app` (bundle-id regex), `title`
  (regex; `^$` = unnamed), `role` / `subrole` (exact AX), and/or
  `max_width` / `max_height` (points). Keys within a rule AND; rules
  OR (first match wins). `action = "float"` (default) keeps the window
  tracked but untiled; `"ignore"` drops it entirely. The template
  ships one default that floats tiny unnamed popups. (System sheets /
  dialogs / palettes are auto-floated by AX role regardless.)
- `[desktop.N]` table — per-mac-desktop workspace list. `N` is the
  mac desktop's Mission Control position; each entry is a 1-indexed inline
  table: `1 = { name = "Dev" }` (name only) or
  `1 = { name = "Dev", layout = "bsp" }` (name + startup layout).
  `layout` is optional — when omitted the WS starts at the global
  `[layout] default`. Two modes: **no** `[desktop.N]` anywhere → every
  mac desktop gets the default workspaces automatically; **any**
  `[desktop.N]` present → **opt-in**: facet manages only the mac desktops
  that have a section; a mac desktop without one is left untouched (windows
  as-is, panel hidden there).

## CLI

facet is **CLI-driven**: a small set of flags posts a distributed
notification to the running server. Bind these from whatever
hotkey tool you already use (skhd, Karabiner, Raycast,
Hammerspoon, macOS Shortcuts, …). Full cheatsheet:
`facet --help`.

```sh
# Per-view ops — NAME ∈ tree | grid | rail, required for every op.
facet --view=NAME [--active]      # open NAME (idempotent)
facet --view=rail --edge=left     # dock the rail strip (top|bottom|left|right)
facet --hide=NAME                 # close NAME
facet --toggle=NAME               # toggle NAME

# Tiling (M5 Phase γ)
facet workspace --layout=NAME     # bsp | stack | master-left | master-right | master-top | master-bottom | master-center | grid | spiral | float
facet workspace --retile          # re-apply active WS's layout (any tiling mode)
facet workspace --balance         # reset master ratio / count to the even baseline
facet workspace --rotate=90|180|270        # rotate the bsp tree clockwise (bsp only)
facet workspace --mirror=horizontal|vertical # flip the bsp tree left↔right / top↔bottom
facet window --toggle-float          # flip focused window float flag
facet window --toggle-sticky         # pin it across every workspace (PiP / timer /
                                     # chat); flip off → drops it as a tiled window
                                     # of the workspace you're on. session-only,
                                     # per mac desktop.
facet window --toggle-orientation    # bsp: rotate the focused window's parent split
facet window --cycle-stack=next|prev # rotate stack to next / previous member
facet window --grow-master|--shrink-master   # master width ±0.05 (master-* engines)
facet window --inc-master|--dec-master       # master window count ±1 (master-* engines)

# --active is a modifier — only meaningful with --view=tree.
# Without it the tree panel still gains keyboard nav as soon as
# you click it; --active just takes focus immediately so a hotkey
# invocation jumps straight into nav (Spotlight-style). With
# --view=grid it's silently ignored; the overlay is always
# key/active by construction.

# Workspace ops
facet workspace --focus=N               # switch to workspace N (1-indexed)
facet workspace --focus=NAME            # switch by name (stable across reorder)
facet workspace --focus=next|prev|recent # step (wraps) / return to previous
facet workspace --add                   # append a new workspace
facet workspace --remove[=N]            # remove WS N (or active); windows → neighbour
facet workspace --rename=NAME           # rename the active workspace
facet workspace --move=N                # move active workspace to position N
facet window --move-to=N          # move focused window to workspace N
facet window --move-to=N --follow # …and switch to N too (send-and-follow)
facet window --mark=NAME          # tag the focused window with a mark
facet window --focus-mark=NAME    # jump focus to that window (switches WS)
facet window --unmark=NAME        # remove a mark
                                  # 1:1 — a window holds one mark; reassigning
                                  # a name moves it off the old window.
                                  # session-only, per mac desktop.

# Scratchpad — named hidden shelves (dropdown-terminal / notes pattern)
facet scratchpad --stash=NAME     # park the focused window onto a named
                                  # shelf (hides it off-screen)
facet scratchpad --toggle=NAME    # summon it onto the current workspace as
                                  # a floating overlay — or re-park it to the
                                  # shelf if it's already visible here
facet scratchpad --release=NAME   # drop it off the shelf as a normal tiled
                                  # window of the workspace you're on
                                  # no spawn (existing windows only); 1:1
                                  # name↔window; session-only, per mac desktop.
facet status                      # snapshot: backend, theme, workspaces,
                                  # stashed shelves, lastError, timestamp

# Server controls
facet --theme=NAME                # 17 themes + random (terminal, nord, …, hacker; see config.toml)
facet --reload                    # re-read config.toml + apply
                                  # (theme / preview-mode)
facet --quit                      # terminate the running server
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

**[chord](https://github.com/akira-toriyama/chord)** — sibling
TOML-driven keyboard + mouse hotkey daemon for macOS. Same
hexagonal Swift shape as facet; one config file, no GUI.

```toml
[[bindings]]
name   = "facet workspace 1"
input  = "ctrl + alt - 1"
action-shell = "/opt/homebrew/bin/facet workspace --focus=1"

[[bindings]]
name   = "move focused window to workspace 1"
input  = "ctrl + shift + alt - 1"
action-shell = "/opt/homebrew/bin/facet window --move-to=1"
```

**skhd** (`~/.config/skhd/skhdrc`):

```
ctrl + alt - 1          : facet workspace --focus=1
ctrl + alt - 2          : facet workspace --focus=2
ctrl + shift + alt - 1  : facet window --move-to=1
ctrl + shift + alt - 2  : facet window --move-to=2
```

**Karabiner-Elements**: bind shell commands via the *Complex
Modifications* JSON (`shell_command`: `/opt/homebrew/bin/facet
workspace --focus=1`).

**Hammerspoon**: `hs.hotkey.bind({"ctrl","alt"}, "1", function()
hs.execute("/opt/homebrew/bin/facet workspace --focus=1") end)`.

#### Bonus: a loading skeleton for mac-desktop switches

For the flicker-obsessed — you know who you are. macOS hands out no
"a mac-desktop switch is *about* to start" hook, so facet only hears about
the move *after* the slide — just late enough that the incoming
mac desktop flashes the previous mac desktop's tree for a frame. Not the
fix we'd frame and hang on the wall.

But if that single-frame blink nags at you the way it nagged at us:
have your hotkey tool fire `facet --view=tree --loading=2000` *right
before* the mac-desktop-switch keys. facet lays a skeleton over the tree,
holds it through the slide, and lifts it the instant the new mac
desktop's workspaces load (or at 2 s — whichever comes first). With
[chord](https://github.com/akira-toriyama/chord), `action-shell`
runs first and `action-keys` forwards the real keystroke through:

```toml
[[bindings]]
name         = "space-left + facet tree"
input        = "ctrl + fn - left"
action-shell = "facet --view=tree --loading=2000"
action-keys  = "ctrl + fn - left"
```

A hack? Absolutely. A tiny love letter to everyone who notices
single frames? Also that. 💙

## Debugging

Set `FACET_DEBUG=1` to mirror everything that goes into
`/tmp/facet.log` to stderr as well, and to turn on verbose
tracing (refresh ticks, backend commands, focus retries, grid
DnD events, …). `./run.sh` sets it for you; for a raw binary
prefix the command:

```sh
FACET_DEBUG=1 .build/release/facet              # foreground — events scroll live
FACET_DEBUG=1 .build/release/facet 2>&1 | tee bug.log   # capture for an issue
```

`FACET_DEBUG` is read once at server startup. Without it the app
stays quiet on stderr and `Log.debug` calls are zero-cost — so a
brew-installed `facet` never pollutes your shell. (There is no
`--debug` flag: passing one exits `2` like any unknown flag.)

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
