// swift-tools-version:6.0
//
// facet — Swift workspace + window manager for macOS.
//
// Multi-target layout (see docs/architecture.md):
//
//   FacetCore           pure logic: WS/Window state, focus rules,
//                       layout engines, event types. No AppKit,
//                       no backend. Fully testable.
//
//   FacetAdapterNative  Swift implementation using AX / CGS + the
//                       private `_AXUIElementGetWindow` dlsym.
//                       Sole `WindowBackend` implementation since
//                       Phase ε (v2.0.0) retired the rift adapter.
//
//   FacetAccessibility  AX / CGS helpers (focus, title resolution,
//                       geometry, display change detection).
//                       Originally extracted at M5 to share between
//                       the (then-coexisting) rift and native
//                       adapters; ε kept it as the single home
//                       for AX-touching code outside the adapter
//                       itself.
//
//   FacetView           shared view primitives (theme, palette,
//                       fonts, common key monitor).
//
//   FacetViewTree       sidebar view (translucent tree panel).
//
//   FacetViewGrid       full-screen overview overlay (Mission
//                       Control-style cells with ScreenCaptureKit
//                       thumbnails).
//
//   FacetViewRail       bottom-of-screen workspace rail (compact
//                       Mission-Control-style bar: click a box to
//                       switch, hover for window thumbnails, drag a
//                       window between boxes).
//
//   FacetApp            executable target: @main, CLI argv,
//                       Controller orchestration.
//
// Tests are split per module under Tests/<Module>Tests. GUI
// modules (Views, App) deliberately skipped — pure logic in Core
// + Adapter contract checks is where the value is.

import PackageDescription

let package = Package(
    name: "facet",
    // macOS 26 floor (t-tbar family policy): raised from .v15 the moment
    // facet first bumps its sill pin into the 26-floor line (sill v2.0.0+
    // requires macOS 26 for the #17b/Phase-B SwiftUI migration). Spelled as
    // the STRING "26.0" — the only form both toolchains parse (`.v26` is
    // absent from CLT's PackageDescription 6.1, and tools-version 6.2 would
    // break CLT manifest parsing), so tools-version stays 6.0. Dropping
    // macOS <26 is a deliberate breaking change (t-kz0m).
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "facet", targets: ["FacetApp"]),
        .library(name: "FacetCore", targets: ["FacetCore"]),
    ],
    dependencies: [
        // Shared theming foundation (plan atelier). Pinned to a SemVer
        // tag for release/CI reproducibility; `.upToNextMinor` keeps it on
        // a single minor. Floor 3.1.0 = the sill release (PR #109, t-5d5a)
        // that added `ObjectShape.dynamicValue` — a TYPED open-map value
        // schema for dynamic-ordinal tables — so the ONE `configSpec` gives
        // `[desktop.<N>]` field-level completion + strict validation instead
        // of a bare permissive object (t-kz0m; see FacetConfig+Spec.swift
        // `desktop`). This 1.29.0→3.x jump crosses sill 2.0.0/3.0.0, which
        // raised sill's macOS floor to 26 (t-tbar) — hence facet's own
        // `.macOS("26.0")` bump above. The breaking majors touched only
        // ThemeKit/ThemeKitUI/prism (the AppKit ThemedList retirement), none
        // of the modules facet links (Palette / PaletteKit / Effects /
        // ConfigSchema). sill's OWN swift-toml-edit floor stays 2.0.0 (the
        // breaking `Toml.Row`/source-span bump, chord#148) — facet's DIRECT
        // swift-toml-edit 2.x pin below and sill's transitive one resolve to
        // the same 2.x, never a split graph. For local, atomic sill↔facet
        // editing, temporarily swap this for `.package(path: "../sill")`.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "3.5.0")),
        // swift-toml-edit — the family's ONE TOML implementation. It was
        // sill's in-tree `Toml` until sill 0.11.0 moved it into its own repo;
        // FacetCore takes `Toml` (pure, Foundation-only) from here now. The
        // module name is unchanged, so `import Toml` survives. Floor 2.0.0:
        // the family unified on swift-toml-edit 2.x (chord#148). 2.0.0's break
        // — source spans carried on a typed `Toml.Row`, the synthetic
        // `__line__` key dropped — is confined to the STRICT nested `parse` /
        // `Value.arrayOfTables` surface; facet reads only `parseFlat`
        // (`.tables` / `.arrays`, element type unchanged) and the lossless
        // `Toml.Annotated` DOM (board nesting, `parseTOMLNestedTabs`), neither
        // of which 2.0.0 touched — so this is a pin-only bump, no code change.
        // `.upToNextMajor` mirrors sill's own pin for this bedrock dependency.
        // Floor 2.3.0: ConfigSnapshot writes a lens desktop's retargeted
        // `[desktop.N] match=` via the scalar `settingValue(_:atTable:forKey:)`
        // added there (t-sgqk) — an older 2.x has no such symbol.
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git",
                 .upToNextMajor(from: "2.3.0")),
    ],
    targets: [
        // FacetCore links sill's PURE `Palette` module (AppKit-free, so it
        // doesn't break FacetCore's no-AppKit rule) for `canonical(_:)` —
        // the single source of truth for valid `--theme=` names — and the
        // `Toml` module (pure, Foundation-only) for config parsing, now from
        // swift-toml-edit (split out of sill at 0.11.0).
        .target(name: "FacetCore", dependencies: [
            .product(name: "Palette", package: "sill"),
            .product(name: "Toml", package: "swift-toml-edit"),
            // ConfigSchema: one declarative `Spec` drives the config.toml
            // decode, the JSON Schema emitted for taplo completion
            // (`facet config --emit-schema`), AND `facet config --validate`
            // (sill 1.29.0 bridge) — so all three never drift.
            .product(name: "ConfigSchema", package: "sill"),
        ]),
        .target(name: "FacetAccessibility", dependencies: ["FacetCore"]),
        .target(name: "FacetAdapterNative",
                dependencies: ["FacetCore", "FacetAccessibility"]),
        .target(name: "FacetView", dependencies: [
            "FacetCore",
            .product(name: "Palette", package: "sill"),
            .product(name: "PaletteKit", package: "sill"),
            .product(name: "Effects", package: "sill"),
            .product(name: "ThemeKit", package: "sill"),
        ]),
        .target(name: "FacetViewTree", dependencies: [
            "FacetView", "FacetCore",
            .product(name: "ThemeKitUI", package: "sill"),
        ]),
        .target(name: "FacetViewGrid", dependencies: ["FacetView", "FacetCore"]),
        .target(name: "FacetViewRail", dependencies: ["FacetView", "FacetCore"]),
        // Capture adapter: the sole ScreenCaptureKit consumer, behind
        // FacetCore's `WindowCapturing` port (so FacetView stays free of
        // OS-backend imports). Same role as FacetAdapterNative for AX/CGS.
        .target(name: "FacetCapture", dependencies: ["FacetCore"]),
        .executableTarget(
            name: "FacetApp",
            dependencies: [
                "FacetCore",
                "FacetAccessibility",
                "FacetAdapterNative",
                "FacetCapture",
                "FacetView",
                "FacetViewTree",
                "FacetViewGrid",
                "FacetViewRail",
                // ConfigSchema: `facet config --validate` surfaces sill's
                // ValidationError values from FacetConfig.validate (t-0029).
                .product(name: "ConfigSchema", package: "sill"),
            ]),
        .testTarget(name: "FacetCoreTests", dependencies: ["FacetCore"]),
        .testTarget(name: "FacetAdapterNativeTests",
                    dependencies: ["FacetAdapterNative", "FacetCore"]),
        .testTarget(name: "FacetAccessibilityTests",
                    dependencies: ["FacetAccessibility", "FacetCore"]),
        .testTarget(name: "FacetViewTests",
                    dependencies: ["FacetView"]),
        .testTarget(name: "FacetViewGridTests",
                    dependencies: ["FacetViewGrid"]),
        .testTarget(name: "FacetViewTreeTests",
                    dependencies: ["FacetViewTree"]),
    ]
)
