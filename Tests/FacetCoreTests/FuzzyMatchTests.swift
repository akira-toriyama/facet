import XCTest
@testable import FacetCore

final class FuzzyMatchTests: XCTestCase {

    func testEmptyQueryMatchesAnything() {
        XCTAssertTrue(fuzzyMatch("", ""))
        XCTAssertTrue(fuzzyMatch("", "anything"))
    }

    func testSubsequenceMatchesNonContiguously() {
        XCTAssertTrue(fuzzyMatch("frt", "favorite"))   // f-a-v-o-r-i-t-e
        XCTAssertTrue(fuzzyMatch("vsc", "VSCode"))
        XCTAssertTrue(fuzzyMatch("ws", "Workspaces"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(fuzzyMatch("CHROME", "chrome window"))
        XCTAssertTrue(fuzzyMatch("chrome", "Google Chrome — Inbox"))
    }

    func testReturnsFalseWhenCharactersOutOfOrder() {
        XCTAssertFalse(fuzzyMatch("ec", "code"))       // 'e' comes after 'c' in "code"
        XCTAssertFalse(fuzzyMatch("xyz", "hello"))
    }

    func testEmptyHaystackOnlyMatchesEmptyQuery() {
        XCTAssertTrue(fuzzyMatch("", ""))
        XCTAssertFalse(fuzzyMatch("a", ""))
    }
}
