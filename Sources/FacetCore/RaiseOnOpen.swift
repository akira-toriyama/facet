// How facet surfaces a freshly-opened floating window — pure config
// vocabulary, unit-testable.
//
// A floating window (sheet / dialog / palette, or one a user
// `[[exclude]]` rule floats) is born wherever the app put it, which
// can be *under* the tiled layout. `[window] raise-on-open` decides
// the one-shot nudge facet gives it on first sight (never a
// continuous pin — it fires once, when the window is first classified):
//
//   - `raise`    (default): `kAXRaiseAction` only — lift it to the
//                front of its app's window stack WITHOUT taking keyboard
//                focus. Honours facet's never-steal-focus contract.
//   - `activate`: bring the owning app frontmost on every fresh float
//                (this *does* steal focus, each time). Pick it when
//                `raise` (z-order within one app) can't surface floats
//                that open under a *different* app — it fronts the app
//                for any fresh float, not only buried ones.
//   - `off`:     do nothing — leave it where the app placed it.
//
// An unknown value clamps to `raise` (the default), like every other
// TOML key — a typo never breaks the layout.

/// How a freshly-opened floating window is surfaced (`[window]
/// raise-on-open`). Read via `FacetConfig.effectiveRaiseOnOpen`.
public enum RaiseOnOpen: String, Sendable, Equatable, CaseIterable {
    case raise
    case activate
    case off
}
