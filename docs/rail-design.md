# rail — summoned WS switcher (the Theme D (ii) design memo)

Status: ✅ **shipped #109 (2026-05-31)** — shipped as `facet --view rail`
(`Sources/FacetViewRail/`, registered in `canonicalViews`). ⚠️ **The
implementation diverged from this memo's original design**: the shipped
version is not "bottom-of-screen chips + a central hover preview" but a
**full-screen backdrop + central HERO (the active WS shown large) + a
bottom row of every WS's window thumbnails** (a grid-leaning overview).
←/→ browses, click switches, window / header drag moves / swaps. The body
below is the **design record from the Theme D (ii) "grill" era**. The code
truth is `Sources/FacetViewRail/` (RailView proper + RailHeader /
RailDrag). The full-screen takeover panel is not rail-specific but
FacetView's shared `OverviewPanel` (merging the old `RailOverlay` /
`GridOverlay`).
Diagram: [`theme-d-rail.excalidraw`](theme-d-rail.excalidraw)
(re-editable in Excalidraw. For Theme D overall see
[architecture.md](architecture.md)'s "Themes A–D")

## What rail is

A **summoned "fast switching" view** showing the WSs in one row (Mission
Control / Win11 task-view style). Like Grid, it overlays the screen
temporarily and closes after the interaction. Not permanent.

- Summon by hotkey → interact → Esc closes (reusing Grid's summon /
  dismiss)
- WSs line up as chips in one row at the bottom of the screen (chip =
  number + app icons)
- **Hover → exactly one large preview at center** (detail is the central
  preview's job, not the chip's)
- Click switches

## Decisions (settling the 6 issues)

| # | Issue | Conclusion |
|---|------|------|
| 1 | A permanent bar competes for screen space (fights tiling) | **Vanished** — it is summoned, so it only overlays temporarily. No tiling-area reservation needed |
| 2 | Reordering shifts hotkey numbers | **A = swap adopted** — dragging is grid's "slots fixed, contents exchange". Preserves Phase α's number-preservation freeze. True reorder (renumbering) rejected |
| 3 | View or dock / lifecycle | Treated as a **summoned view like Grid** (`--view=rail` anticipated). Not a dock |
| 4 | Central-preview placement / multi-display | Minor. Reuse `PreviewOverlayPool` + only the placement logic is new (detail untouched) |
| 5 | Does it duplicate Grid? | **Both are needed** — different roles. rail = fast switching (switcher) / Grid = deliberate management (manager: window moves, cell swaps, overview). Coexistence OK = rail is worth building |
| 6 | Does it steal focus? | Mostly solved. `KeyablePanel`'s inactive pattern (key only during keyboard nav) |

### overflow (when WSs grow)

> ⚠️ **The policy changed twice. Current is 2-b's active-centered
> carousel.**
> ① Originally = no-scroll, shrink→wrap (below — rejected). ② M9-3/M9-4 =
> fixed-size cells + scrolling (clipped-edge peek). ③ **2-b (current) =
> the carousel pinning active to the strip center while the strip
> rotates** (`[rail] cells` cells; overflow rotates instead of shrinking;
> peek at both ends; browse arrows = rotate / Return = switch + close).
> M9-4's scroll machinery was replaced by 2-b
> (`railScrollToShow`→`railCarouselOffsets`). The canonical design is
> memory `[[facet-rail-carousel-decisions]]`. Original plan ① below is a
> historical record.

Original plan (rejected): no scroll (hidden elements defeat
"one glance"). Keep every WS visible by **wrapping**:

1. First shrink the chips (number + icons only, so they tolerate it)
2. Below the floor, wrap to a 2nd row (numeric order kept)
3. Cap the row count too (2-3); beyond that, shrink further

## Implementation estimate

The shared `FacetView` layer's existing parts cover most of it:

| Need | Reused part |
|------|----------|
| Hover → central preview (all of a WS's windows together) | `PreviewOverlayPool` + `PreviewOverlay` |
| Window image capture (TTL cache) | `SCKWindowCapture` (`FacetCapture`, via FacetCore's `WindowCapturing` port) |
| A summoned panel that steals no focus | `KeyablePanel` |
| Colors / theme | `Theme` / `Palette` |

**Only 2 genuinely new pieces**:

1. The one-row layout computation (a pure shrink → wrap function —
   `GridMath`'s analogue → unit-testable in FacetCore)
2. The rail panel's controller (same shape as Tree / Grid's controllers)

DnD / clicks follow the existing "the grabbed target decides the action"
model.

## Untouched / next to pin down

- ~~The summon hotkey / CLI (whether `facet --view=rail` is right)~~ →
  ✅ shipped as `--view rail` (#109, `canonicalViews`). Note there is no
  auto-show at launch (facet always starts agent-only; every view is
  summoned)
- Issue 4's central-preview placement logic and multi-display behavior
  (refinement on the shipped HERO + thumbnail row continues in future
  rail edge / carousel work; scroll was retired by 2-b)
- Pre-work invariants (same as [architecture.md](architecture.md)): don't
  break `facet-buddha-palm-principle` / `facet-scope-exclusions` / the
  `WindowBackend`-protocol-mediated design
