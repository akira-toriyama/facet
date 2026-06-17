import CoreGraphics
import XCTest
@testable import FacetCore

// Parity proof for `TagModel.lensFilter` (pivot Phase 1, #284 PR#4): the
// `facet filter` derived from a tag-mode lens must match a window EXACTLY
// when the AUTHORITATIVE bitmask rule `(window.tags & lens) != 0` does. The
// bitmask stays canon; this proves the filter is a faithful read-only
// projection of it (so Phase 1's projection can read through it). The core
// test sweeps 1000 pseudo-random (mask, lens) pairs. CI-ONLY (CLT cannot
// run `swift test`); the logic was also spot-verified standalone via swiftc.
final class LensFilterParityTests: XCTestCase {

    private let floor = TagModel.defaultBit

    // 8-tag vocabulary on bits 0…7; `eps`/`eta`/`theta` etc. are arbitrary
    // distinct clean names.
    private let model = TagModel(["alpha", "beta", "gamma", "delta",
                                  "eps", "zeta", "eta", "theta"])
    private var userBits: [UInt64] { (0..<8).map { UInt64(1) << UInt64($0) } }

    private func bit(_ name: String) -> UInt64 { model.bit(for: name)! }

    /// A window whose tag-NAME list reflects `mask` under `model`. The
    /// `_default` floor is internal (never a chip), so `names(in:)` drops
    /// it — exactly how the real tag snapshot builds its rows. So `tags` is
    /// the user-tag names only, which is what the `tag` filter field reads.
    private func window(mask: UInt64) -> Window {
        Window(id: .init(serverID: 1), pid: 1, appName: "App", title: "T",
               isFocused: false, isFloating: false, frame: nil,
               isOnscreen: true, isMaster: false, bundleId: nil,
               mark: nil, isSticky: false, scratchpad: nil,
               tags: model.names(in: mask))
    }

    // Deterministic PRNG (SplitMix64) so a failing iteration reproduces.
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - 1000-iteration random parity sweep

    func testRandomMaskLensParity() {
        var rng = RNG(state: 0xF00D_CAFE_1234_5678)
        for i in 0..<1000 {
            // Window mask: a random subset of DEFINED user bits, ALWAYS
            // OR-ed with the floor — the tag-mode invariant that every
            // tracked window carries `_default` (so it is never `0`/lost).
            let r = rng.next()
            var mask = floor
            for (b, ub) in userBits.enumerated() where (r >> b) & 1 == 1 {
                mask |= ub
            }
            // Lens: arbitrary. A random subset of user bits, sometimes the
            // floor, sometimes a stray undefined/high bit (which can never
            // intersect a real mask → no parity impact), sometimes `lensAll`.
            let lr = rng.next()
            var lens: UInt64 = 0
            for (b, ub) in userBits.enumerated() where (lr >> (b + 8)) & 1 == 1 {
                lens |= ub
            }
            if lr & 1 == 1 { lens |= floor }                  // floor sometimes
            if lr & 2 == 2 { lens |= (UInt64(1) << 40) }      // stray hole bit
            if (lr & 0b1100) == 0b1100 {                      // sometimes --all
                lens = model.allMask | floor
            }
            // `setLens` floor-guards 0 → mirror it (a real lens is never 0,
            // an empty user lens collapses to the floor / show-all).
            if lens == 0 { lens = floor }

            let expected = (mask & lens) != 0
            let filter = model.lensFilter(lens)
            let actual = filter.matches(window(mask: mask))
            XCTAssertEqual(actual, expected,
                "iter \(i): mask=\(mask) lens=\(lens) filter=\"\(filter)\"")
        }
    }

    // MARK: - Explicit shape / semantics

    func testFloorOnlyLensIsShowAll() {
        let f = model.lensFilter(floor)
        XCTAssertEqual(f, .all)
        // shows both a tagged and an untagged window
        XCTAssertTrue(f.matches(window(mask: floor | bit("alpha"))))
        XCTAssertTrue(f.matches(window(mask: floor)))
    }

    func testLensAllIsShowAll() {
        XCTAssertEqual(model.lensFilter(model.allMask | floor), .all)
    }

    func testSingleTagLensIsLoneAtom() {
        let f = model.lensFilter(bit("alpha"))
        XCTAssertEqual(f.description, "tag~=alpha s")
        XCTAssertTrue(f.matches(window(mask: floor | bit("alpha"))))
        XCTAssertFalse(f.matches(window(mask: floor | bit("beta"))))
        // untagged window is not in a user lens
        XCTAssertFalse(f.matches(window(mask: floor)))
    }

    func testMultiTagLensIsOr() {
        // declaration order: alpha (bit0) before gamma (bit2)
        let f = model.lensFilter(bit("gamma") | bit("alpha"))
        XCTAssertEqual(f.description, "tag~=alpha s or tag~=gamma s")
        XCTAssertTrue(f.matches(window(mask: floor | bit("alpha"))))
        XCTAssertTrue(f.matches(window(mask: floor | bit("gamma"))))
        XCTAssertFalse(f.matches(window(mask: floor | bit("beta"))))
    }

    func testCaseSensitivityKeepsParityForCaseCollidingTags() {
        // "Web" and "web" are DISTINCT bits; a case-insensitive `~=` would
        // fuse them. The ` s` flag keeps each lens bit name-exact.
        let m = TagModel(["Web", "web"])
        let webBit = m.bit(for: "web")!
        let f = m.lensFilter(webBit)
        XCTAssertEqual(f.description, "tag~=web s")
        let lowerOnly = Window(id: .init(serverID: 1), pid: 1, appName: "A",
            title: "T", isFocused: false, isFloating: false, frame: nil,
            isOnscreen: true, isMaster: false, bundleId: nil, mark: nil,
            isSticky: false, scratchpad: nil, tags: ["web"])
        let upperOnly = Window(id: .init(serverID: 1), pid: 1, appName: "A",
            title: "T", isFocused: false, isFloating: false, frame: nil,
            isOnscreen: true, isMaster: false, bundleId: nil, mark: nil,
            isSticky: false, scratchpad: nil, tags: ["Web"])
        XCTAssertTrue(f.matches(lowerOnly))
        XCTAssertFalse(f.matches(upperOnly))   // would be true if insensitive
    }

    func testEmptyUndefinedLensMatchesNothing() {
        // Unreachable for a real lens, but `lensFilter` must be total: a
        // lens of only undefined bits resolves to "match nothing".
        let f = model.lensFilter(UInt64(1) << 40)
        XCTAssertEqual(f, .not(.all))
        XCTAssertFalse(f.matches(window(mask: floor | bit("alpha"))))
        XCTAssertFalse(f.matches(window(mask: floor)))
    }

    // MARK: - `not tag` is the untagged floor's filter form (glossary claim)

    func testUntaggedWindowIsNotTag() {
        switch FacetFilter.parse("not tag") {
        case .success(let f):
            XCTAssertTrue(f.matches(window(mask: floor)))            // untagged
            XCTAssertFalse(f.matches(window(mask: floor | bit("alpha"))))
        case .failure(let e):
            XCTFail("parse failed: \(e.message)")
        }
    }

    // MARK: - description ↔ parse round-trip

    func testDescriptionRoundTrips() {
        func atom(_ field: String, _ op: FacetFilter.Op, _ v: String,
                  _ cs: Bool = false) -> FacetFilter {
            .atom(.init(field: field, kind: .compare(op: op, value: v, caseSensitive: cs)))
        }
        let presence = FacetFilter.atom(.init(field: "tag", kind: .presence))
        let cases: [FacetFilter] = [
            .all,                                               // ""
            presence,                                           // tag
            .not(presence),                                     // not tag
            model.lensFilter(floor),                            // .all → ""
            model.lensFilter(bit("alpha")),                     // tag~=alpha s
            model.lensFilter(bit("alpha") | bit("beta")),       // or
            atom("app", .equals, "Safari"),                     // app=Safari
            atom("title", .substring, "a b"),                   // title*="a b" (quoted)
            atom("title", .equals, "2*3"),                      // title="2*3" (quoted: op-lead)
            atom("app", .equals, "Mail", true),                 // app=Mail s
            .and([atom("tag", .contains, "web"), .not(atom("floating", .equals, "true"))]),
            .or([atom("tag", .contains, "a"),
                 .and([atom("tag", .contains, "b"), atom("app", .equals, "X")])]),
            .not(.or([presence, atom("app", .equals, "X")])),   // not (tag or app=X)
        ]
        for f in cases {
            switch FacetFilter.parse(f.description) {
            case .success(let round):
                XCTAssertEqual(round, f,
                    "round-trip mismatch: \"\(f.description)\" → \(round) ≠ \(f)")
            case .failure(let e):
                XCTFail("re-parse of \"\(f.description)\" failed: \(e.message)")
            }
        }
    }
}
