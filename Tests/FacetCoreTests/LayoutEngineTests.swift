import CoreGraphics
import XCTest
@testable import FacetCore

/// Pure tests for the stateless layout-engine seam (Theme B). No AX,
/// no AppKit — engines are pure geometry, same playbook as
/// `LayoutTreeTests`.
final class LayoutEngineTests: XCTestCase {

    private func wid(_ n: Int) -> WindowID { WindowID(serverID: n) }
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    // MARK: - Monocle

    func testMonocleFillsRectForEveryWindow() {
        let order = [wid(1), wid(2), wid(3)]
        let f = MonocleLayout().frames(
            order: order, focused: wid(2),
            params: LayoutParams(), in: screen)
        XCTAssertEqual(f.count, 3)
        for w in order { XCTAssertEqual(f[w], screen) }
    }

    func testMonocleSingleWindow() {
        let f = MonocleLayout().frames(
            order: [wid(7)], focused: nil,
            params: LayoutParams(), in: screen)
        XCTAssertEqual(f, [wid(7): screen])
    }

    func testMonocleEmptyOrderEmptyFrames() {
        XCTAssertTrue(MonocleLayout().frames(
            order: [], focused: nil,
            params: LayoutParams(), in: screen).isEmpty)
    }

    func testMonocleIgnoresFocusAndParams() {
        // Frame output must not depend on which window is focused or
        // on the knobs (monocle reads neither).
        let order = [wid(1), wid(2)]
        let a = MonocleLayout().frames(
            order: order, focused: wid(1),
            params: LayoutParams(masterRatio: 0.3, masterCount: 3),
            in: screen)
        let b = MonocleLayout().frames(
            order: order, focused: wid(2),
            params: LayoutParams(), in: screen)
        XCTAssertEqual(a, b)
    }

    // MARK: - Registry

    func testRegistryResolvesMonocleCaseInsensitive() {
        XCTAssertEqual(LayoutRegistry.engine(named: "monocle")?.name,
                       "monocle")
        XCTAssertEqual(LayoutRegistry.engine(named: "MONOCLE")?.name,
                       "monocle")
        XCTAssertEqual(LayoutRegistry.engine(named: "Monocle")?.name,
                       "monocle")
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

    func testRegistryNamesAdvertiseMonocle() {
        XCTAssertTrue(LayoutRegistry.names.contains("monocle"))
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
