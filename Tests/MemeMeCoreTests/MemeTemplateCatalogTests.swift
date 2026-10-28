import Foundation
@testable import MemeMeCore
import XCTest

final class MemeTemplateCatalogTests: XCTestCase {
    /// Part of Imgflip's list, most popular first. Gru's Plan carries an id the table doesn't know: it is found by name.
    private let popular = [
        TemplateRef(id: "181913649", name: "Drake Hotline Bling"),
        TemplateRef(id: "87743020", name: "Two Buttons"),
        TemplateRef(id: "112126428", name: "Distracted Boyfriend"),
        TemplateRef(id: "155067746", name: "Surprised Pikachu"),
        TemplateRef(id: "80707627", name: "Sad Pablo Escobar"),
        TemplateRef(id: "27813981", name: "Hide the Pain Harold"),
        TemplateRef(id: "999", name: "Some Unknown Template"),
        TemplateRef(id: "998", name: "Gru's Plan"),
        TemplateRef(id: "259237855", name: "Laughing Leo"),
    ]

    func testAMoodPutsItsTemplatesFirstThenThePopularOnes() {
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .shocked, from: popular, limit: 5), [3, 0, 1, 2, 4])
        // Sad Pablo Escobar is sad first; Hide the Pain Harold is nervous first and sad second.
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .sad, from: popular, limit: 5), [4, 5, 0, 1, 2])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .sideEye, from: popular, limit: 5).first, 2)
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .laughing, from: popular, limit: 5).first, 8)
    }

    func testNoFaceYetIsTheMostPopular() {
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .reaction, from: popular, limit: 5), [0, 1, 2, 3, 4])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .reaction, from: Array(popular.prefix(2)), limit: 5), [0, 1])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .happy, from: popular, limit: 0), [])
    }

    func testTemplatesAreFoundByNameWhenTheIdDiffers() {
        XCTAssertTrue(MemeTemplateCatalog.pick(for: .nervous, from: popular, limit: 5).contains(7))
        XCTAssertEqual(MemeTemplateCatalog.normalized("Gru's Plan"), "grusplan")
        XCTAssertEqual(MemeTemplateCatalog.normalized("  UNO Draw 25 Cards!"), "unodraw25cards")
    }

    func testTypedWordsFindTemplatesByNameSearchWordsAndMood() {
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["sad"], from: popular, limit: 5), [4, 5])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["boyfriend"], from: popular, limit: 5), [2])
        // "the guy looking back": the words people use for it.
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["guy looking back"], from: popular, limit: 5), [2])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["lol"], from: popular, limit: 5), [8])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["Pikachu"], from: popular, limit: 5), [3])
        // Not in the table: only its name can match.
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["unknown"], from: popular, limit: 5), [6])
    }

    func testWordsThatMatchNothingFindNothing() {
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["zzzz"], from: popular, limit: 5), [])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["x"], from: popular, limit: 5), [])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: [], from: popular, limit: 5), [])
    }

    func testMemeWordsAreToldFromPossibleNames() {
        for word in ["sad", "LOL", "facepalm", "shrug", "cat", "boyfriend", "pikachu", "mind", "blown"] {
            XCTAssertTrue(MemeTemplateCatalog.isMemeWord(word), word)
        }
        for word in ["sam", "maya", "zorblax"] {
            XCTAssertFalse(MemeTemplateCatalog.isMemeWord(word), word)
        }
    }

    func testTheTableIsWellFormed() {
        var ids = Set<String>()
        var names = Set<String>()
        for entry in MemeTemplateCatalog.entries {
            XCTAssertFalse(entry.names.isEmpty)
            XCTAssertFalse(entry.moods.isEmpty, "\(entry.names)")
            XCTAssertFalse(entry.moods.contains(.reaction), "\(entry.names)")
            if let id = entry.id {
                XCTAssertTrue(ids.insert(id).inserted, "duplicate id \(id)")
            }
            for name in entry.names {
                XCTAssertTrue(names.insert(MemeTemplateCatalog.normalized(name)).inserted, "duplicate name \(name)")
            }
        }
        // Every mood a face can have has templates of its own.
        for mood in Mood.allCases where mood != .reaction {
            XCTAssertTrue(MemeTemplateCatalog.entries.contains { $0.moods.contains(mood) }, "\(mood)")
        }
    }
}
