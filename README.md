# facet

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
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
your workspaces through one of its views — tree, grid, or the rail
overview, each summoned on demand (`facet --view tree|grid|rail`):

- **Tree** — a translucent always-on-top sidebar listing every
  workspace and its windows as a tree. Click rows to focus, drag a
  window row to move it between workspaces, drag a workspace header
  (grip on the left) to swap two workspaces' contents, hover for a
  live on-screen preview.
- **Grid** — a full-screen overview with one cell per workspace,
  real ScreenCaptureKit thumbnails, and DnD between cells: drag a
  window thumb to move it, drag a cell's header to swap whole cells.
  The grid is summoned on demand (`facet --view grid`) and dismissed
  with Esc / backdrop click.
- **Rail** — a full-screen Mission-Control-style workspace switcher: an
  active-centred **carousel** of window-thumbnail mini-screens in a
  strip along one screen edge, with the browsed workspace shown large in
  the centre. The active workspace is pinned to the strip centre and the
  rest fan out around it; the browse arrow keys (←/→ on a top/bottom
  rail, ↑/↓ on a left/right one) **rotate the strip** to bring another
  workspace to the centre, Return or a click switches to the centred one,
  Esc dismisses. Drag a window between workspaces or a header to swap.
  Dock the strip with `--edge top|bottom|left|right` (default bottom).
  The thumbnails are justified to fill the strip with even gaps; `[rail]
  strip` caps their size (a percentage of the short screen edge — the
  hero fills the rest), so the split stays balanced in any orientation or
  on any display size. `[rail] cells` caps how many show at once; past
  that, workspaces rotate through (peeking at both ends). Summoned with
  `facet --view rail`.

Drag-and-drop follows one model across the views: the **grabbed
target decides the action** — drag a window to move it, drag a
workspace header to swap the two workspaces' contents (the workspace
slots themselves don't move, so hotkey numbering is preserved). No
modifier keys.

All views share the same backend and the same theme
(13 built-in themes — terminal, chomp, rainbow, dracula, github-dark,
catppuccin-mocha, … plus `random` — live toggleable).

## Layouts

Each workspace runs a layout, set at runtime with
`facet workspace --layout NAME` (per-WS, never persisted — set a
per-mac-desktop startup layout via a `[[desktop.N.section]]` block in
[`config.toml`](config.toml), e.g. `type = "workspace"` with `layout =
"bsp"`). facet
never hides windows, so a layout only *positions* them and the
focused window is always raised. Diagrams use four windows; **1** is
the master / focus where that matters.

The master sits on any of five edges — pick one directly with
`--layout master-EDGE`. They share one geometry (opposite edges are
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
`--cycle-stack next|prev` rotates which one is on top.

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
| Right-click (tree) | context menu, by target: window row → actions · workspace header → layout picker · `Desktop N` band → Search (the `s` mode) |
| Hover a window row (tree) | live preview — small popover next to the row by default; switch to `mirror` in `[tree] preview-mode` for full-size at the would-be on-screen frame |
| Click a cell (grid) | switch to that workspace |
| Click a window thumb (grid) | switch + focus that window |
| Drag a thumb to another cell (grid) | move that window to that workspace |
| Drag a workspace header onto another cell (grid) | swap the entire contents of the two cells |

Show / hide / toggle and keyboard mode are driven entirely from
the CLI — see [CLI](#cli) below.

### Keyboard navigation

The tree opens directly in keyboard nav — facet takes key focus
the moment it appears (Spotlight-style), so the arrow keys,
`Return` and search (`s`) work right away.
Trade-off: facet briefly becomes the active app (Dock + Cmd-Tab)
while the panel is up. Acting on a window — click a row or press
`Return` on a selection — hands key **back** first, so focusing a
same-app window still works; facet then drops to the background.
`Esc` backs out of search / the context menu but **stays in the
tree**.

You can also **right-click the `Desktop N` header** for a menu with
**Search** (`s`).

| Key | Action |
|---|---|
| `↓`/`↑`, `Ctrl-N`/`Ctrl-P`, `j`/`k` | move between rows |
| `Tab`/`⇧Tab`, `→`/`←`, `l`/`h` | jump to the prev/next workspace |
| `s` | type-to-filter: fuzzy-search windows across all workspaces (real text field, IME works) |
| `Space` | lift the selected row for drag-and-drop — a window row moves, a workspace header swaps; then arrows aim the target workspace, `Return`/`Space` commits, `Esc` cancels |
| `m` | open the selected row's context menu (keyboard-navigable: `↑↓`/`Return`/`Esc`) |
| `Return` | commit a lift, or (not lifting) switch + focus like a click |
| `Esc` | back out one level — cancel a lift, else clear the filter, else exit search to nav; never leaves the tree (click away / `Return` on a window to leave nav) |

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

Cells paint with **ScreenCaptureKit thumbnails** (Screen Recording
grant); a background refresh keeps them warm
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
(`facet --theme dracula` etc.) apply for the current session only;
edit the file to make a change stick.

Frequently-touched keys:

- `[theme] name` — 13 themes: `terminal` (default) / `chomp` /
  `rainbow` / `cobalt2` / `shades-of-purple` / `tokyo-hack` /
  `github-dark` / `dracula` / `catppuccin-mocha` / `gruvbox` /
  `github-light` / `catppuccin-latte` / `system`, plus `random`
  (picks one at each launch / `--reload`, excluding `system`)
- `[tree]` table — `preview-mode` (`popover` / `mirror`), plus the
  panel geometry seed `pos-x` / `pos-y` / `width` / `height` (screen
  points, **top-left origin**: 0,0 = top-left of the main screen, y
  down; all four needed). Authoritative each launch / `--reload`;
  drags / CLI geom are session-only, so set it here to pin the panel.
  Same coords as `facet --view tree --pos-x/...`. Also `line-pets` —
  opt-in arcade sprites (`chomp` / `ghost`) that walk the **tree panel's
  outer border** (riding a transparent overlay just in front of the
  frame); a shared decoration from the sill theming library (the same
  pets ride halo's focus ring). Tune with `pet-scale` (default 0.9) and
  `pet-lap-seconds` (default 8). Empty = off.
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
  `vapor` / `kawaii` / `chomp` / `rainbow` / `random`; `glow` (default `true`)
  toggles the bloom; `width` sets the line width (px, clamp 0.5–30,
  default 1.5).
  The border flashes a neon burst on a workspace switch. `color-cycle-ms`
  (clamp 1000–120000, default 6000 — lower is faster) is the period of the
  continuous animation: `rainbow`'s hue rotation, and — when
  `min-width`/`max-width` are both set (max > min, each 0.5–30) — a
  width breath that oscillates the border between them (any effect,
  overriding the fixed `width`). Off shows a plain theme-accent border.
- `[window]` table — `raise-on-open` controls how a freshly-opened
  **floating** window (a sheet / dialog / palette, an
  `[[exclude]]`-floated window, or any window facet auto-floats) is
  surfaced on first sight, since it can be born *under* the tiled
  layout. A one-shot nudge on the window's open, not a continuous pin
  (a pre-existing float isn't touched on a desktop switch): `raise`
  (default) lifts it to the front of its own app's window stack without
  stealing focus; `activate` brings the owning app frontmost on
  every fresh float (this *does* steal focus each time — pick it when
  `raise` can't surface floats that open under a different app); `off`
  leaves it where the app placed it. Only floating windows are touched;
  read at launch (restart to change).
- `[[exclude]]` rules — keep popups / unnamed / auxiliary windows out
  of the tiling layout. Match by `app` (bundle-id regex), `title`
  (regex; `^$` = unnamed), `role` / `subrole` (exact AX), and/or
  `max-width` / `max-height` (points). Keys within a rule AND; rules
  OR (first match wins). `action = "float"` (default) keeps the window
  tracked but untiled; `"ignore"` drops it entirely; `"manage"`
  force-tiles a window the allowlist floated / ignored (the escape
  hatch for an app that mislabels a real window with a non-standard
  subrole). The template ships one default that floats tiny unnamed
  popups. (System sheets / dialogs / palettes are auto-floated by AX
  role regardless.)
- `[[rule]]` adopt-rules — set facets on a window the moment facet
  adopts it. Each rule is a `match` (a facet filter WHERE-clause, e.g.
  `app=Safari and not floating`) plus the facets to set: `workspace`
  (move to a named workspace), `tags`, and `floating` / `sticky` /
  `master`. A global, top-level block like `[[exclude]]` (fires on
  every mac desktop), evaluated in declaration order; a window picks up
  every matching rule's facets. The declarative successor to the
  retired `[[assign]]`. A malformed `match` is loud + non-fatal (that
  rule is skipped; the rest still run).
- `[[desktop.N.section]]` blocks — the per-mac-desktop section model
  (`N` = the mac desktop's Mission Control position). An ordered list of
  sections describes that desktop; each has a required `type`:
  `"workspace"` (a spatial cell named by an optional `label`, else an
  auto-named emoji, with an optional `layout` seed; the count of these is
  that desktop's workspace count),
  `"lens"` (a saved visibility filter — `label` + `match` + optional
  `layout` + `apply`; activate it with `facet lens NAME` to anchor-park
  every non-matching window across **every** workspace — cross-workspace
  exclusive — and union-tile the matches; switching to any workspace clears
  the lens, `facet lens --clear` lifts it and restores the parked windows;
  **dragging a window onto a lens relocates it out of its workspace** — it now
  lives only via the lens, becoming a 迷子 (orphan) when no matching lens is
  active). A window can thus belong to **no** workspace; orphans are
  invisible-but-logged (never auto-homed). Surface them with a 迷子 receptacle —
  a `type = "lens"` section whose `match = 'not workspace'` (recommended: keep
  one per desktop). **A workspace is named by its optional `label`** (else
  an auto-named emoji); `facet workspace --rename` overrides at runtime.
  Two modes: **no**
  `[[desktop.N.section]]` anywhere → every mac desktop gets the default
  workspaces automatically; **any** present → **opt-in**: facet manages
  only the mac desktops that have a section block; a mac desktop without
  one is left untouched (windows as-is, panel hidden there). All three views
  render the same section list — lens sections appear as cells in the tree,
  grid, **and** rail, with exactly one section highlighted; on the rail the
  active section is the centre hero (an active lens shows its union there).
- **Per-window tags** carry no config — they are free-form strings
  attached at **runtime** (session-only) with `facet window --tag NAME`
  (and `--untag` / `--toggle-tag` / `--retag`). A `type = "lens"` section
  whose `match` contains `tag~=NAME` shows every window carrying NAME;
  `facet query --tags` lists every tag currently in use.

## CLI

facet is **CLI-driven**: a small set of flags posts a distributed
notification to the running server. Bind these from whatever
hotkey tool you already use (skhd, Karabiner, Raycast,
Hammerspoon, macOS Shortcuts, …). Full cheatsheet:
`facet --help`.

```sh
# Per-view ops — NAME ∈ tree | grid | rail, required for every op.
facet --view NAME                 # open NAME (idempotent)
facet --view rail --edge left     # dock the rail strip (top|bottom|left|right)
facet --hide NAME                 # close NAME
facet --toggle NAME               # toggle NAME

# Tiling (M5 Phase γ)
facet workspace --layout NAME     # bsp | stack | master-left | master-right | master-top | master-bottom | master-center | grid | spiral | float
facet workspace --retile          # re-apply active WS's layout (any tiling mode)
facet workspace --balance         # reset master ratio / count to the even baseline
facet workspace --rotate 90|180|270        # rotate the bsp tree clockwise (bsp only)
facet workspace --mirror horizontal|vertical # flip the bsp tree left↔right / top↔bottom
facet window --toggle-float          # flip focused window float flag
facet window --toggle-sticky         # pin it across every workspace (PiP / timer /
                                     # chat); flip off → drops it as a tiled window
                                     # of the workspace you're on. session-only,
                                     # per mac desktop.
facet window --toggle-orientation    # bsp: rotate the focused window's parent split
facet window --cycle-stack next|prev # rotate stack to next / previous member
facet window --grow-master|--shrink-master   # master width ±0.05 (master-* engines)
facet window --inc-master|--dec-master       # master window count ±1 (master-* engines)

# --view tree opens directly in keyboard nav: facet takes focus
# immediately (Spotlight-style) so the arrows / Return / search (s)
# work at once. Acting on a window (click a row or Return) hands key
# back first, so same-app focus still works. You can also right-click
# the "Desktop N" header for Search. (grid is always key/active by
# construction; rail is passive.)

# Workspace ops
facet workspace --focus N               # switch to workspace N (1-indexed)
facet workspace --focus NAME            # switch by name (stable across reorder)
facet workspace --focus next|prev|recent # step (wraps) / return to previous
facet workspace --add                   # append a new workspace
facet workspace --remove TARGET         # remove WS (current | index N); windows → neighbour
facet workspace --rename NAME           # rename the active workspace
facet workspace --move N                # move active workspace to position N
facet window --move-to N          # move focused window to workspace N
facet window --move-to N --follow # …and switch to N too (send-and-follow)
facet window --mark NAME          # tag the focused window with a mark
facet window --focus-mark NAME    # jump focus to that window (switches WS)
facet window --unmark NAME        # remove a mark
                                  # 1:1 — a window holds one mark; reassigning
                                  # a name moves it off the old window.
                                  # session-only, per mac desktop.

# Lens (section model) — activate a type="lens" [[desktop.N.section]] by its
# label; non-matching windows are anchor-parked across EVERY workspace
# (cross-workspace exclusive — a real hide) and the matches union-tile.
# Switching to any workspace clears the lens. Persists across mac-desktop swaps.
facet lens "Web"                  # activate the lens labelled Web
facet lens --clear                # lift the active lens (parked windows return)

# Scratchpad — named hidden shelves (dropdown-terminal / notes pattern)
facet scratchpad --stash NAME     # park the focused window onto a named
                                  # shelf (hides it off-screen)
facet scratchpad --toggle NAME    # summon it onto the current workspace as
                                  # a floating overlay — or re-park it to the
                                  # shelf if it's already visible here
facet scratchpad --release NAME   # drop it off the shelf as a normal tiled
                                  # window of the workspace you're on
                                  # no spawn (existing windows only); 1:1
                                  # name↔window; session-only, per mac desktop.
facet query                       # snapshot: backend, theme, workspaces,
                                  # stashed shelves, lastError, timestamp
facet query --windows             # every window as flat JSON (all mac
                                  # desktops) — raw props + per-window
                                  # facet state, or null when unmanaged.
                                  # Filter with jq:
                                  #   facet query --windows \
                                  #     | jq '.[] | select(.facet.tags[]? == "190")'
facet query --windows --filter EXPR  # post-filter that array with a
                                  # facet filter expr (a WHERE clause):
                                  # field op value (= ~= ^= $= *= |=) +
                                  # bare presence (tag/floating/…) joined
                                  # by and/or/not/(). Bad expr is loud-
                                  # but-non-fatal: caret to stderr, shows
                                  # all windows (exit 0). e.g.:
                                  #   facet query --windows \
                                  #     --filter 'tag~=web and not floating'
facet query --tags                # every tag currently in use, as a sorted
                                  # JSON array ([] until a window is tagged)

# Server controls
facet --theme NAME                # 13 themes + random (terminal, chomp, …, catppuccin-latte; see config.toml)
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

### Window tags

A window can carry any number of **free-form string tags** — created
on first use, session-only, attached live from the CLI. They feed lens
filters: a `type = "lens"` section whose `match` contains `tag~=NAME`
(see [Configuration](#configuration)) shows every window carrying NAME.

```sh
facet window --tag NAME           # add a tag to the focused window
facet window --untag NAME         # remove a tag from the focused window
facet window --toggle-tag NAME    # flip a tag on the focused window
facet window --retag OLD NEW      # replace one tag with another on it
facet query --tags                # every tag currently in use (sorted JSON)
```

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
action-shell = "/opt/homebrew/bin/facet workspace --focus 1"

[[bindings]]
name   = "move focused window to workspace 1"
input  = "ctrl + shift + alt - 1"
action-shell = "/opt/homebrew/bin/facet window --move-to 1"
```

**skhd** (`~/.config/skhd/skhdrc`):

```
ctrl + alt - 1          : facet workspace --focus 1
ctrl + alt - 2          : facet workspace --focus 2
ctrl + shift + alt - 1  : facet window --move-to 1
ctrl + shift + alt - 2  : facet window --move-to 2
```

**Karabiner-Elements**: bind shell commands via the *Complex
Modifications* JSON (`shell_command`: `/opt/homebrew/bin/facet
workspace --focus 1`).

**Hammerspoon**: `hs.hotkey.bind({"ctrl","alt"}, "1", function()
hs.execute("/opt/homebrew/bin/facet workspace --focus 1") end)`.

#### Bonus: a loading skeleton for mac-desktop switches

For the flicker-obsessed — you know who you are. macOS hands out no
"a mac-desktop switch is *about* to start" hook, so facet only hears about
the move *after* the slide — just late enough that the incoming
mac desktop flashes the previous mac desktop's tree for a frame. Not the
fix we'd frame and hang on the wall.

But if that single-frame blink nags at you the way it nagged at us:
have your hotkey tool fire `facet --view tree --loading 2000` *right
before* the mac-desktop-switch keys. facet lays a skeleton over the tree,
holds it through the slide, and lifts it the instant the new mac
desktop's workspaces load (or at 2 s — whichever comes first). With
[chord](https://github.com/akira-toriyama/chord), `action-shell`
runs first and `action-keys` forwards the real keystroke through:

```toml
[[bindings]]
name         = "space-left + facet tree"
input        = "ctrl + fn - left"
action-shell = "facet --view tree --loading 2000"
action-keys  = "ctrl + fn - left"
```

> **Upgrading from a pre-2.x grammar?** facet now takes space-separated
> values (`--flag VALUE`), and the old `--flag=VALUE` form is a hard
> error (`exit 2`). A chord / skhd `action-shell` swallows that exit
> code silently, so a stale `facet --view=tree --loading=2000` binding
> would quietly stop painting the skeleton with no visible failure.
> Re-check your bindings against the new grammar — see
> [docs/cli-migration.md](docs/cli-migration.md).

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

Launching the bundle doesn't put the `facet` CLI on your PATH
(`zsh: command not found: facet` — the Homebrew install handles
this for you; a source build doesn't). Piggyback an alias on
the rebuild loop — from the repo root:

```sh
./run.sh && alias facet="$PWD/.build/release/facet"
```

Session-scoped by design: no rc file is touched, a new tab just
re-runs the line above, and anywhere the alias isn't defined a
plain `facet` still resolves to the Homebrew install. The alias
stores the build *path*, so rebuilding refreshes what it runs.

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
- **Window preview** needs Screen Recording.
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
