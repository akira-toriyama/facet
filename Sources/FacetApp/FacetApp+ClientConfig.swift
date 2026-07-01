// `facet config <flag>` — config-file maintenance one-shots. Each reads
// ~/.config/facet/config.toml directly and exits WITHOUT starting / needing
// the running server (same one-shot shape as `--rescue` / `--resign`):
//
//   --validate     STRICT schema check (exit 0 valid / 1 schema-invalid /
//                  2 unparseable) — the counterpart to the lenient load().
//   --emit-schema  print the Draft-07 JSON Schema to stdout (repo/dev regen
//                  of config.schema.json; not shown in --help).
//
// A new subject (mirrors window / workspace / section / board / query). It
// FOLDS IN the former bare `facet --emit-schema`: no bare alias survives
// (facet's no-alias rule — a bare flag beside a subject is the exact
// "is it bare or scoped?" ambiguity the subject-verb CLI exists to kill).

import ConfigSchema
import FacetCore
import Foundation

extension FacetApp {

    /// Sub-command parser for ``facet config <flag>``. Exactly one action per
    /// invocation; loud-rejects (exit 2) zero / multiple / unknown flags —
    /// the same `requireExactlyOneAction` guard the other subjects use. Each
    /// action is a one-shot that exits, so dispatch runs AFTER the guard.
    static func runConfigCommand(_ args: [String]) -> Never {
        var validate = false
        var emitSchema = false
        var cursor = ArgCursor(args)
        while let a = cursor.next() {
            switch a {
            case "--validate":    validate = true
            case "--emit-schema": emitSchema = true
            default:
                die("unknown `config` flag \"\(a)\" — see `facet --help`")
            }
        }
        requireExactlyOneAction([validate, emitSchema].filter { $0 }.count,
                                subject: "config")
        if validate { runValidate() }
        // emit-schema (the sole remaining action): generated from the same
        // declarative `configSpec` that decodes the config, so schema +
        // decode can't drift. Regenerate the committed sidecar with
        // `facet config --emit-schema > config.schema.json`.
        print(FacetConfig.jsonSchema, terminator: "")
        exit(0)
    }

    /// `facet config --validate` — STRUCTURAL validation of config.toml
    /// against the same `configSpec` that drives decode + `--emit-schema`
    /// (sill 1.29.0 `Spec.validate` bridge, t-0029): the strict counterpart
    /// to the lenient `load()`, which clamps out-of-range values and drops
    /// typo'd keys. Surfaces the type / enum / range / unknown-key mismatches
    /// the loader silently accepts.
    ///
    /// Exit codes: 2 if config.toml isn't parseable TOML at all (syntax
    /// error); 1 if it parses but violates the schema; 0 if structurally
    /// valid — then the lenient `load()` runs so its bespoke clamp /
    /// did-you-mean / geometry-partial warnings (the checks validate does
    /// NOT cover) print too, followed by a one-line parsed summary. No
    /// double-report: an enum typo exits 1 above, before this branch.
    static func runValidate() -> Never {
        let path = FacetConfig.defaultPath

        // Distinguish a MISSING file (→ all defaults, which IS valid) from one
        // that exists but is UNREADABLE (bad perms / non-UTF-8 / I/O error).
        // The lenient `load()` collapses both to defaults, but for a pre-flight
        // check that's a trap: an unreadable file must not masquerade as a
        // clean empty config. So read it here — a real read failure is exit 2
        // (we can't validate what we can't read), not a false "valid".
        let source: String
        if FileManager.default.fileExists(atPath: path) {
            do {
                source = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                die("config.toml: unreadable — \(error)")   // exit 2
            }
        } else {
            source = ""   // no config file = every default = valid
        }

        let errors: [ValidationError]
        do {
            errors = try FacetConfig.validate(source)
        } catch {
            die("config.toml: not parseable — \(error)")   // exit 2
        }
        if !errors.isEmpty {
            // `message` already carries the located one-liner (e.g.
            // "grid.bogus-key: unknown key 'bogus-key'") — print it verbatim.
            for e in errors {
                FileHandle.standardError.write(Data("facet: \(e.message)\n".utf8))
            }
            FileHandle.standardError.write(Data(
                "facet: \(errors.count) validation error(s)\n".utf8))
            exit(1)
        }

        // Structurally valid → build the config from the SAME source we just
        // validated (no second disk read / no TOCTOU) to surface the bespoke
        // loader warnings validate can't (clamp did-you-mean hints,
        // geometry-partial) + a one-line summary. Counts read through the
        // `effective*` accessors (CLAUDE.md: never the raw Optional fields) so
        // boards-win shadowing is reflected.
        let cfg = FacetConfig.load(source: source)
        for w in cfg.unknownValueWarnings() {
            FileHandle.standardError.write(Data("facet: \(w)\n".utf8))
        }
        let desktops = Set(cfg.effectiveMacDesktopSectionConfigs.keys)
            .union(cfg.effectiveMacDesktopTabConfigs.keys).count
        FileHandle.standardError.write(Data((
            "facet: config valid — theme=\(cfg.effectiveTheme), "
            + "layout=\(cfg.effectiveDefaultLayout), "
            + "\(cfg.exclusionRules?.count ?? 0) exclude, "
            + "\(cfg.rules?.count ?? 0) rule, "
            + "\(desktops) configured desktop(s)\n").utf8))
        exit(0)
    }
}
