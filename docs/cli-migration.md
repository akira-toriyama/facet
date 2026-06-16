# CLI migration — `--flag=VALUE` → `--flag VALUE` (#227)

facet's CLI moved from GNU-style `--flag=VALUE` (equals sign) to
**yabai-style space-separated values** (`--flag VALUE`). This is a
**hard cutover**: the old `=` form is no longer accepted — it exits `2`
with an "unknown flag" error. There is no compatibility shim.

Why: facet's command structure already mirrors yabai's `-m DOMAIN`
(`window` / `workspace` / `lens` / `tag` / `scratchpad`); bare-word
values complete more naturally in a shell; and it matches the family
CLI convention. See [glossary](glossary.md) → *CLI 文法* and
[architecture](architecture.md) → *CLI surface* for the design.

## ⚠️ Silent-break warning for chord / skhd / hammerspoon bindings

A hotkey tool's `action-shell` (chord, skhd) runs the command
**fire-and-forget** — it does not surface a non-zero exit code. So a
stale binding using the old `=` form will **fail silently**: the
command exits `2` and nothing happens, with no visible error. The most
load-bearing case is the loading-skeleton chord
(`facet --view=tree --loading=2000`), which would quietly stop masking
mac-desktop switches. **Re-check every binding** against the table
below.

## Grammar rules (the one model)

- Each value-bearing flag consumes its next token **unconditionally**
  (strict consumption / lookahead-zero). So negative coordinates read
  fine: `--pos-x -1440`.
- `=` is gone. There is no `--` sentinel and no quoting need — names
  forbid the characters that would require escaping.
- **No optional-value flags.** `--loading` and `workspace --remove`
  now take a required argument (see breaking changes).
- A missing value is a loud `exit 2` (`"<flag>: missing argument"`),
  never a silent mis-parse.

## Name policy (tags / marks / scratchpad / workspace names)

Names must be **non-empty**, must **not** start with `-`, and must
**not** contain spaces or any of `:` `=` `,`. Tags additionally strip a
leading `#` and reject a leading `_` (reserved for the `_default`
floor). The GUI tag box and config `[[tag]] name` normalize internal
spaces to `-` (so `"my tag"` → `my-tag`); on the CLI a space inside a
name is impossible (the shell already split it).

## Command translation

The table below is **illustrative, not exhaustive** — *every*
value-bearing flag migrated to the space form, not just the rows shown.

| Old (`=` form) | New (space form) |
|---|---|
| `facet --view=tree --active` | `facet --view tree --active` |
| `facet --hide=grid` | `facet --hide grid` |
| `facet --toggle=rail` | `facet --toggle rail` |
| `facet --view=rail --edge=left` | `facet --view rail --edge left` |
| `facet --view=tree --loading=2000` | `facet --view tree --loading 2000` |
| `facet --view=tree --pos-x=8 --pos-y=8 --width=400 --height=600` | `facet --view tree --pos-x 8 --pos-y 8 --width 400 --height 600` |
| `facet --theme=dracula` | `facet --theme dracula` |
| `facet workspace --focus=2` | `facet workspace --focus 2` |
| `facet workspace --focus=next` | `facet workspace --focus next` |
| `facet workspace --layout=bsp` | `facet workspace --layout bsp` |
| `facet workspace --rotate=90` | `facet workspace --rotate 90` |
| `facet workspace --mirror=horizontal` | `facet workspace --mirror horizontal` |
| `facet workspace --rename=work` | `facet workspace --rename work` |
| `facet workspace --move=3` | `facet workspace --move 3` |
| `facet workspace --remove` (active) | `facet workspace --remove current` |
| `facet workspace --remove=2` | `facet workspace --remove 2` |
| `facet window --move-to=1 --follow` | `facet window --move-to 1 --follow` |
| `facet window --mark=a` | `facet window --mark a` |
| `facet window --focus=left` | `facet window --focus left` |
| `facet window --cycle-stack=next` | `facet window --cycle-stack next` |
| `facet window --tag=#190` | `facet window --tag #190` |
| `facet lens --only=web` | `facet lens --only web` |
| `facet tag --add=web` | `facet tag --add web` |
| `facet tag --rename=old:new` | `facet tag --rename old new` |
| `facet scratchpad --stash=notes` | `facet scratchpad --stash notes` |
| `facet status` | `facet query` |

## Breaking changes beyond the `=` → space mechanics

1. **`facet status` → `facet query`.** The read verb was renamed (the
   snapshot output is identical). A bare `facet status` now exits `2`.
2. **`tag --rename` is two positional arguments**, not one
   colon-joined token: `--rename OLD NEW` (was `--rename=OLD:NEW`). A
   flag-looking `NEW` (e.g. `--add`) is rejected by the name policy — no
   silent mis-rename.
3. **`--loading` requires a value** (`--loading MS`); `0` disables it.
   The bare `--loading` (defaulted to 500 ms) is gone.
4. **`workspace --remove` requires a target**: `current` (the active
   workspace — what bare `--remove` used to mean) or a 1-based index.
   `next` / `prev` / `recent` / name targets are not supported here.
5. **Stricter names.** A leading `-`, an internal space, or any of
   `:` `=` `,` is now rejected for tag / mark / scratchpad / workspace
   names (previously some slipped through).

## Unchanged

- The DNC control strings on the wire (`view:tree+active`,
  `tag-rename:OLD:NEW`, `workspace:name:NAME`, …) are **byte-identical**
  — only the user-facing grammar changed, not the server protocol.
- `--help` / `--version` / `--resign` still work anywhere on the
  command line (global, by convention).
- TOML config keys are unaffected (this migration is CLI-only).
