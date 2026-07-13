// How a mac desktop composes its tree — the one-desktop-one-type question,
// asked once. Lives beside `DesktopMeta` (the typed `[desktop.N]` table) rather
// than in the config accessors, because it is a MODEL fact, not a config knob.

/// How the tree for one mac desktop is composed. Three cases — and that is the
/// point.
///
/// The retired board / section-lens era had a two-world question ("is the
/// section model on?"), which `FacetConfig.isSectionModelActive` still answers.
/// Under **one mac desktop = one type** that question is not enough: a **lens
/// desktop** renders sections yet authors no `[[desktop.N.section]]` cell, so
/// it is `false` there. Every caller that meant "does this desktop render
/// sections?" had to spell it `isSectionModelActive(…) || isIsolateDesktop` — and
/// the ones that forgot silently lost function on an isolate desktop (the tag
/// entry points did, which is what made tagging dead on the one kind of desktop
/// whose membership a tag can define).
///
/// So: ask `FacetConfig.desktopRenderMode(ordinal:)` and switch. The shape
/// makes the isolate desktop case impossible to forget.
public enum DesktopRenderMode: Sendable, Equatable {
    /// A **workspace desktop** with ≥1 authored `[[desktop.N.section]]` spatial
    /// cell: the tree renders those cells, and they seed the workspace count.
    case sections

    /// A **workspace desktop** with no authored cells: the tree falls back to
    /// the by-workspace view over `defaultWorkspaceCount` unnamed slots. Also
    /// the answer for an unresolvable ordinal (SkyLight unavailable).
    case degrade

    /// An **isolate desktop** (`[desktop.N] type = "isolate"`): the tree renders
    /// the 1–2 sections synthesized from `match` (matched, plus the holding
    /// section when `show-non-matching`). Flat — exactly ONE workspace is seeded.
    case isolate

    /// Whether the tree renders SECTIONS (as opposed to the by-workspace
    /// degrade). True for both a section-configured workspace desktop and an
    /// isolate desktop — the distinction they share is that a projection runs.
    public var rendersSections: Bool { self != .degrade }
}
