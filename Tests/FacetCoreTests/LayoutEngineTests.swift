import CoreGraphics
import Testing
@testable import FacetCore

/// Pure tests for the stateless layout-engine seam (Theme B). No AX,
/// no AppKit — engines are pure geometry, same playbook as
/// `LayoutTreeTests`. Per-engine geometry lives in the dedicated
/// `*LayoutTests`; this file covers the registry + shared knobs.
struct LayoutEngineTests {

    // MARK: - Registry

    @Test func registryResolvesCaseInsensitive() {
        #expect(LayoutRegistry.engine(named: "master-left")?.name ==
                "master-left")
        #expect(LayoutRegistry.engine(named: "MASTER-LEFT")?.name ==
                "master-left")
        #expect(LayoutRegistry.engine(named: "Master-Top")?.name ==
                "master-top")
    }

    @Test func registryAdvertisesStatelessEngines() {
        for name in ["master-left", "master-right", "master-top",
                     "master-bottom", "master-center", "grid", "spiral"] {
            #expect(LayoutRegistry.names.contains(name),
                    "registry should advertise \(name)")
        }
    }

    @Test func masterEnginesHaveMasterGridSpiralDoNot() {
        for name in ["master-left", "master-right", "master-top",
                     "master-bottom", "master-center"] {
            #expect(LayoutRegistry.engine(named: name)?.hasMaster == true,
                    "\(name) should report a master")
        }
        #expect(LayoutRegistry.engine(named: "grid")?.hasMaster == false)
        #expect(LayoutRegistry.engine(named: "spiral")?.hasMaster == false)
    }

    @Test func registrySkipsStatefulAndUnknownModes() {
        // bsp / stack keep their stateful adapter paths and must NOT
        // resolve here; float + typos are simply absent.
        #expect(LayoutRegistry.engine(named: "bsp") == nil)
        #expect(LayoutRegistry.engine(named: "stack") == nil)
        #expect(LayoutRegistry.engine(named: "float") == nil)
        #expect(LayoutRegistry.engine(named: "nope") == nil)
        #expect(LayoutRegistry.engine(named: "") == nil)
    }

    @Test func monocleRetired() {
        // `monocle` merged into `stack` (full-screen focus); it must no
        // longer resolve as a stateless engine.
        #expect(LayoutRegistry.engine(named: "monocle") == nil)
        #expect(!LayoutRegistry.names.contains("monocle"))
    }

    @Test func oldMasterNamesRetired() {
        // M9-2 renamed tall/wide/centered to master-* with no aliases;
        // the old names must no longer resolve (loud-reject at the CLI).
        for old in ["tall", "wide", "centered"] {
            #expect(LayoutRegistry.engine(named: old) == nil,
                    "\(old) was renamed in M9-2 and must not resolve")
            #expect(!LayoutRegistry.names.contains(old))
        }
    }

    // MARK: - LayoutParams clamping

    @Test func layoutParamsClampRatioAndCount() {
        #expect(LayoutParams(masterRatio: 2.0).masterRatio == 0.95)
        #expect(LayoutParams(masterRatio: -1.0).masterRatio == 0.05)
        #expect(LayoutParams(masterCount: 0).masterCount == 1)
        #expect(LayoutParams(masterCount: -5).masterCount == 1)
    }

    @Test func layoutParamsDefaults() {
        let p = LayoutParams()
        #expect(p.masterRatio == 0.5)
        #expect(p.masterCount == 1)
    }
}
