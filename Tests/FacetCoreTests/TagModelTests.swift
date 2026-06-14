import CoreGraphics
import XCTest
@testable import FacetCore

final class TagModelTests: XCTestCase {

    private let model = TagModel(["work", "web", "media"])

    // MARK: - TagModel bit mapping

    func testBitByDeclarationOrder() {
        XCTAssertEqual(model.bit(for: "work"), 0b001)
        XCTAssertEqual(model.bit(for: "web"), 0b010)
        XCTAssertEqual(model.bit(for: "media"), 0b100)
        XCTAssertNil(model.bit(for: "nope"))
    }

    func testMaskUnionsKnownNamesAndIgnoresUnknown() {
        XCTAssertEqual(model.mask(for: ["work", "media"]), 0b101)
        XCTAssertEqual(model.mask(for: ["web", "ghost"]), 0b010)
        XCTAssertEqual(model.mask(for: []), 0)
    }

    func testAllMask() {
        XCTAssertEqual(model.mask(for: model.names), model.allMask)
        XCTAssertEqual(model.allMask, 0b111)
        XCTAssertEqual(TagModel([]).allMask, 0)
        XCTAssertEqual(TagModel(["a"]).allMask, 0b1)
    }

    func testFirstBit() {
        XCTAssertEqual(model.firstBit, 0b001)
        XCTAssertNil(TagModel([]).firstBit)
    }

    func testNamesInMaskAreDeclarationOrder() {
        XCTAssertEqual(model.names(in: 0b101), ["work", "media"])
        XCTAssertEqual(model.names(in: 0b111), ["work", "web", "media"])
        XCTAssertEqual(model.names(in: 0), [])
    }

    func testEmptyModel() {
        let m = TagModel([])
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.count, 0)
        XCTAssertNil(m.firstBit)
    }

    func testReservesTopBitForDefaultFloor() {
        XCTAssertEqual(TagModel.defaultBit, UInt64(1) << 63)
        XCTAssertEqual(TagModel.maxUserTags, 63)
        let many = (0..<100).map { "t\($0)" }
        let m = TagModel(many)
        XCTAssertEqual(m.count, 63)                 // bit 63 reserved
        XCTAssertEqual(m.bit(for: "t0"), 1)
        XCTAssertEqual(m.bit(for: "t62"), UInt64(1) << 62)
        XCTAssertNil(m.bit(for: "t63"))             // dropped (reserved)
        // allMask is the user-tag union (bits 0...62) — never the floor.
        XCTAssertEqual(m.allMask, TagModel.defaultBit - 1)
        XCTAssertEqual(m.allMask & TagModel.defaultBit, 0)
    }

    // MARK: - Runtime vocabulary mutation (#191 PR-3, sparse + free-list)

    func testAddAppendsThenIsIdempotent() {
        var m = TagModel(["work", "web", "media"])
        XCTAssertEqual(m.add("work"), 0b001)   // defined → its bit (idempotent)
        XCTAssertEqual(m.count, 3)             // no growth
        XCTAssertEqual(m.add("ext"), 0b1000)   // new → next free bit (idx 3)
        XCTAssertEqual(m.count, 4)
        XCTAssertNil(m.add("_default"))        // reserved → nil, no growth
        XCTAssertEqual(m.count, 4)
    }

    func testRemoveFreesBitWithoutCompacting() {
        var m = TagModel(["work", "web", "media"])
        XCTAssertEqual(m.remove("web"), 0b010) // freed bit returned
        XCTAssertNil(m.bit(for: "web"))        // gone
        XCTAssertEqual(m.bit(for: "media"), 0b100)  // UNCHANGED (no shift down)
        XCTAssertEqual(m.names, ["work", "media"])  // hole skipped
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m.allMask, 0b101)       // union of populated slots
    }

    func testAddReusesLowestHole() {
        var m = TagModel(["work", "web", "media"])
        _ = m.remove("web")                    // free bit 1 (a middle hole)
        XCTAssertEqual(m.add("ext"), 0b010)    // reuses bit 1, not bit 3
        XCTAssertEqual(m.bit(for: "media"), 0b100)  // media still bit 2
        XCTAssertEqual(m.names, ["work", "ext", "media"])
    }

    func testRemoveTrailingTagTrimsThenReappends() {
        var m = TagModel(["work", "web", "media"])
        XCTAssertEqual(m.remove("media"), 0b100)  // trailing → trimmed away
        XCTAssertEqual(m.add("ext"), 0b100)       // appends back at bit 2
        XCTAssertEqual(m.names, ["work", "web", "ext"])
    }

    func testRemoveUnknownOrReservedNoChange() {
        var m = TagModel(["work", "web"])
        XCTAssertNil(m.remove("ghost"))
        XCTAssertNil(m.remove("_default"))
        XCTAssertEqual(m.names, ["work", "web"])  // untouched
    }

    func testRenameInPlaceKeepsBit() {
        var m = TagModel(["work", "web", "media"])
        XCTAssertEqual(m.rename("web", to: "social"), .renamed(0b010))
        XCTAssertNil(m.bit(for: "web"))
        XCTAssertEqual(m.bit(for: "social"), 0b010)   // SAME bit
        XCTAssertEqual(m.names, ["work", "social", "media"])
    }

    func testRenameRejectsCollisionUnknownReservedAndIsIdempotent() {
        var m = TagModel(["work", "web"])
        XCTAssertEqual(m.rename("work", to: "web"), .collision)       // taken
        XCTAssertEqual(m.rename("ghost", to: "x"), .unknownOld)       // no old
        XCTAssertEqual(m.rename("work", to: "_default"), .collision)  // reserved
        XCTAssertEqual(m.rename("work", to: "work"), .renamed(0b001)) // no-op
        XCTAssertEqual(m.names, ["work", "web"])  // unchanged by the rejects
    }

    func testHoleAtBitZeroShiftsFirstBit() {
        var m = TagModel(["work", "web", "media"])
        _ = m.remove("work")                   // free bit 0 (the lowest)
        XCTAssertEqual(m.firstBit, 0b010)      // lowest DEFINED is now web
        XCTAssertNil(m.bit(for: "work"))       // bit 0 is a freed hole
        XCTAssertEqual(m.names(in: 0b111), ["web", "media"])  // hole dropped
    }

    func testRemovingEveryTagEmptiesTheModel() {
        var m = TagModel(["only"])
        XCTAssertEqual(m.remove("only"), 0b001)
        XCTAssertTrue(m.isEmpty)
        XCTAssertEqual(m.count, 0)
        XCTAssertNil(m.firstBit)
        XCTAssertEqual(m.allMask, 0)
    }

}
