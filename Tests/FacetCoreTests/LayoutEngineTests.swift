import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure tests for the stateless layout-engine seam (Theme B). No AX,
/// no AppKit — engines are pure geometry, same playbook as
/// `LayoutTreeTests`. Per-engine geometry lives in the dedicated
/// `*LayoutTests`; this file covers the registry + shared knobs.
final class LayoutEngineTests: XCTestCase {

    // MARK: - Registry

    func testRegistryResolvesCaseInsensitive() {
        XCTAssertEqual(LayoutRegistry.engine(named: "master-left")?.name,
                       "master-left")
        XCTAssertEqual(LayoutRegistry.engine(named: "MASTER-LEFT")?.name,
                       "master-left")
        XCTAssertEqual(LayoutRegistry.engine(named: "Master-Top")?.name,
                       "master-top")
    }

    func testRegistryAdvertisesStatelessEngines() {
        for name in ["master-left", "master-right", "master-top",
                     "master-bottom", "master-center", "grid", "spiral"] {
            XCTAssertTrue(LayoutRegistry.names.contains(name),
                          "registry should advertise \(name)")
        }
    }

    func testMasterEnginesHaveMasterGridSpiralDoNot() {
        for name in ["master-left", "master-right", "master-top",
                     "master-bottom", "master-center"] {
            XCTAssertEqual(LayoutRegistry.engine(named: name)?.hasMaster, true,
                           "\(name) should report a master")
        }
        XCTAssertEqual(LayoutRegistry.engine(named: "grid")?.hasMaster, false)
        XCTAssertEqual(LayoutRegistry.engine(named: "spiral")?.hasMaster, false)
    }

    func testRegistrySkipsStatefulAndUnknownModes() {
        // bsp / stack keep their stateful adapter paths and must NOT
        // resolve here; float + typos are simply absent.
        XCTAssertNil(LayoutRegistry.engine(named: "bsp"))
        XCTAssertNil(LayoutRegistry.engine(named: "stack"))
        XCTAssertNil(LayoutRegistry.engine(named: "float"))
        XCTAssertNil(LayoutRegistry.engine(named: "nope"))
        XCTAssertNil(LayoutRegistry.engine(named: ""))
    }

    func testMonocleRetired() {
        // `monocle` merged into `stack` (full-screen focus); it must no
        // longer resolve as a stateless engine.
        XCTAssertNil(LayoutRegistry.engine(named: "monocle"))
        XCTAssertFalse(LayoutRegistry.names.contains("monocle"))
    }

    func testOldMasterNamesRetired() {
        // M9-2 renamed tall/wide/centered to master-* with no aliases;
        // the old names must no longer resolve (loud-reject at the CLI).
        for old in ["tall", "wide", "centered"] {
            XCTAssertNil(LayoutRegistry.engine(named: old),
                         "\(old) was renamed in M9-2 and must not resolve")
            XCTAssertFalse(LayoutRegistry.names.contains(old))
        }
    }

    // MARK: - LayoutParams clamping

    func testLayoutParamsClampRatioAndCount() {
        XCTAssertEqual(LayoutParams(masterRatio: 2.0).masterRatio, 0.95)
        XCTAssertEqual(LayoutParams(masterRatio: -1.0).masterRatio, 0.05)
        XCTAssertEqual(LayoutParams(masterCount: 0).masterCount, 1)
        XCTAssertEqual(LayoutParams(masterCount: -5).masterCount, 1)
    }

    func testLayoutParamsDefaults() {
        let p = LayoutParams()
        XCTAssertEqual(p.masterRatio, 0.5)
        XCTAssertEqual(p.masterCount, 1)
    }
}
