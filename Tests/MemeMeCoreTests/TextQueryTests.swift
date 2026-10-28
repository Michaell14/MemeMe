import Foundation
import XCTest
@testable import MemeMeCore

final class TextQueryTests: XCTestCase {
    func testParseSplitsTermsFiltersAndPeople() {
        let sam = Person(name: "Sam")
        let query = TextQuery.parse("  Cat MINE gifs Sam stickers!  ", people: [sam])
        XCTAssertEqual(query.terms, ["cat"])
        XCTAssertTrue(query.onlyMine)
        XCTAssertTrue(query.onlyGIFs)
        XCTAssertTrue(query.onlyStickers)
        XCTAssertEqual(query.personIDs, [sam.id])
    }

    func testPlainTermsAreLowercasedAndTrimmedOfPunctuation() {
        let query = TextQuery.parse("OMG, Shocked cat?", people: [])
        XCTAssertEqual(query.terms, ["omg", "shocked", "cat"])
        XCTAssertFalse(query.onlyMine)
        XCTAssertFalse(query.onlyGIFs)
        XCTAssertFalse(query.onlyStickers)
        XCTAssertTrue(query.personIDs.isEmpty)
        XCTAssertTrue(TextQuery.parse("   ", people: []).terms.isEmpty)
    }

    func testSingularAndPluralFilterWords() {
        XCTAssertTrue(TextQuery.parse("gif", people: []).onlyGIFs)
        XCTAssertTrue(TextQuery.parse("GIFS", people: []).onlyGIFs)
        XCTAssertTrue(TextQuery.parse("sticker", people: []).onlyStickers)
        XCTAssertTrue(TextQuery.parse("stickers", people: []).onlyStickers)
        XCTAssertTrue(TextQuery.parse("gif", people: []).terms.isEmpty)
    }

    func testPeopleMatchCaseInsensitivelyAndUnnamedPeopleAreIgnored() {
        let maya = Person(name: "Maya")
        let otherMaya = Person(name: "maya ")
        let unnamed = Person()
        let query = TextQuery.parse("MAYA new", people: [maya, otherMaya, unnamed])
        XCTAssertEqual(query.personIDs, [maya.id, otherMaya.id])
        XCTAssertEqual(query.terms, ["new"])
    }

    func testPossibleName() {
        XCTAssertEqual(TextQuery.parse("Jordan", people: []).possibleName, "jordan")
        XCTAssertEqual(TextQuery.parse("mine Jordan", people: []).possibleName, "jordan")
        XCTAssertNil(TextQuery.parse("Jordan", people: [Person(name: "jordan")]).possibleName)    // matched a person
        XCTAssertNil(TextQuery.parse("al", people: []).possibleName)                              // too short
        XCTAssertNil(TextQuery.parse("r2d2", people: []).possibleName)                            // not alphabetic
        XCTAssertNil(TextQuery.parse("cat dog", people: []).possibleName)                         // two terms
        XCTAssertNil(TextQuery.parse("gifs", people: []).possibleName)                            // only a filter
        XCTAssertNil(TextQuery.parse("", people: []).possibleName)
    }
}
