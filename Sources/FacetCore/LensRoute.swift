// `facet lens` mode routing (tag-unification Phase 1) — the PURE decision of
// what an already-parsed `lens` action does under the active `[grouping]`.
//
// Phase 1 collapsed the two mode-specific verb families into ONE surface that
// ADAPTS to the grouping. The CLI parser (`FacetApp.runLensCommand`) validates
// each name's SHAPE and maps argv to a `LensAction`; this maps
// `(action, grouping)` to an abstract `LensEffect` or a loud `LensRouteError`.
// Keeping it here — pure, total, backend- and AppKit-free — makes the routing
// table the single tested source of truth (the DNC wire strings stay in
// FacetApp, which translates each effect into a `postLens` / `postControl`).
//
// The rules:
//   • NAME (positional) and --clear ADAPT to the mode (work in both):
//       NAME  → tag: show exactly these tag(s); section: activate that lens.
//               A comma in a section NAME is rejected — CSV is tag-mode-only.
//       --clear → tag: the `_default` floor = show every window (the same
//                 result as --all); section: clear the active section-lens.
//   • --add / --remove / --toggle / --all are TAG-ONLY (the section model gets
//       multi-lens union + a cross-workspace All selector in a later phase);
//       in section mode they are a loud route error.

/// A parsed `facet lens` action, carrying each name already SHAPE-validated by
/// the FacetApp parser (tag CSV via `parseTagList`, a section label via
/// `parseLensSectionLabel`). Exactly one per invocation.
public enum LensAction: Sendable, Equatable {
    case name(String)        // positional NAME: tag CSV (only) / section label
    case add(String)
    case remove(String)
    case toggle(String)
    case all
    case clear
}

/// The abstract outcome of routing — what the lens command should DO,
/// independent of the DNC wire encoding (FacetApp maps these to payloads).
public enum LensEffect: Sendable, Equatable {
    case showTags(String)         // tag mode: show exactly these (CSV)
    case addTags(String)          // tag mode: union into the shown set
    case removeTags(String)       // tag mode: drop from the shown set
    case toggleTags(String)       // tag mode: flip each in / out
    case showAll                  // tag mode: floor → show every window
    case activateSection(String)  // section mode: activate the lens by label
    case clearSection             // section mode: clear the active lens
}

/// Why a `(action, grouping)` pair is rejected (exit 2 in the CLI).
public enum LensRouteError: Error, Sendable, Equatable {
    /// A tag-composition verb / `--all` used under `by="workspace"`. `verb` is
    /// the user-facing spelling (e.g. `--all`, `--add/--remove/--toggle`).
    case tagOnlyVerb(verb: String)
    /// A comma in a positional NAME under `by="workspace"` — the section model
    /// takes one label, CSV is tag-mode-only. `name` is the offending value.
    case csvInSectionName(name: String)
}

/// Route a parsed `lens` action under the active grouping. Pure + total.
public func routeLens(_ action: LensAction, grouping: Grouping)
    -> Result<LensEffect, LensRouteError> {
    switch (action, grouping) {
    // Positional NAME — adapts to the mode.
    case let (.name(n), .tag):
        return .success(.showTags(n))
    case let (.name(n), .workspace):
        // CSV is tag-mode-only; a section takes exactly one label.
        return n.contains(",")
            ? .failure(.csvInSectionName(name: n))
            : .success(.activateSection(n))

    // --clear — the universal reset, both modes.
    case (.clear, .tag):       return .success(.showAll)
    case (.clear, .workspace): return .success(.clearSection)

    // Tag-only composition verbs + --all.
    case let (.add(n), .tag):    return .success(.addTags(n))
    case let (.remove(n), .tag): return .success(.removeTags(n))
    case let (.toggle(n), .tag): return .success(.toggleTags(n))
    case (.all, .tag):           return .success(.showAll)
    case (.add, .workspace), (.remove, .workspace), (.toggle, .workspace):
        return .failure(.tagOnlyVerb(verb: "--add/--remove/--toggle"))
    case (.all, .workspace):
        return .failure(.tagOnlyVerb(verb: "--all"))
    }
}
