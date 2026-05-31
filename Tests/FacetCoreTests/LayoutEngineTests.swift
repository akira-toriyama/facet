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
        XCTAssertEqual(LayoutRegistry.engine(named: "tall")?.name, "tall")
        XCTAssertEqual(LayoutRegistry.engine(named: "TALL")?.name, "tall")
        XCTAssertEqual(LayoutRegistry.engine(named: "Wide")?.name, "wide")
    }

    func testRegistryAdvertisesStatelessEngines() {
        for name in ["tall", "wide", "centered", "grid", "spiral"] {
            XCTAssertTrue(LayoutRegistry.names.contains(name),
                          "registry should advertise \(name)")
        }
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
