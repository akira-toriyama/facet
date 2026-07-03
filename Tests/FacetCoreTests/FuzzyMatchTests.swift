import Testing
@testable import FacetCore

struct FuzzyMatchTests {

    @Test func emptyQueryMatchesAnything() {
        #expect(fuzzyMatch("", ""))
        #expect(fuzzyMatch("", "anything"))
    }

    @Test func subsequenceMatchesNonContiguously() {
        #expect(fuzzyMatch("frt", "favorite"))   // f-a-v-o-r-i-t-e
        #expect(fuzzyMatch("vsc", "VSCode"))
        #expect(fuzzyMatch("ws", "Workspaces"))
    }

    @Test func caseInsensitive() {
        #expect(fuzzyMatch("CHROME", "chrome window"))
        #expect(fuzzyMatch("chrome", "Google Chrome — Inbox"))
    }

    @Test func returnsFalseWhenCharactersOutOfOrder() {
        #expect(!fuzzyMatch("ec", "code"))       // 'e' comes after 'c' in "code"
        #expect(!fuzzyMatch("xyz", "hello"))
    }

    @Test func emptyHaystackOnlyMatchesEmptyQuery() {
        #expect(fuzzyMatch("", ""))
        #expect(!fuzzyMatch("a", ""))
    }
}
