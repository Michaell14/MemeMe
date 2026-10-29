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

    func testPagesContinueTheSameOrderAndWrapAround() {
        // Shocked: Surprised Pikachu, then the popular ones.
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .shocked, from: popular, limit: 5, page: 0), [3, 0, 1, 2, 4])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .shocked, from: popular, limit: 5, page: 1), [5, 6, 7, 8, 3])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .shocked, from: popular, limit: 5, page: 2), [0, 1, 2, 4, 5])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .reaction, from: popular, limit: 4, page: 1), [4, 5, 6, 7])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .reaction, from: popular, limit: 4, page: 2), [8, 0, 1, 2])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .shocked, from: popular, limit: 5, page: -1), [3, 0, 1, 2, 4])
        // Fewer templates than a page: every page is all of them.
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .shocked, from: popular, limit: 20, page: 3), [3, 0, 1, 2, 4, 5, 6, 7, 8])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .shocked, from: [], limit: 5, page: 1), [])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .shocked, from: popular, limit: 0, page: 1), [])
    }

    func testPageZeroIsThePick() {
        for mood in [Mood.shocked, .sad, .nervous, .reaction, .tongueOut, .smirk] {
            for limit in [0, 1, 3, 5, 9, 20] {
                XCTAssertEqual(MemeTemplateCatalog.pick(for: mood, from: popular, limit: limit, page: 0),
                               MemeTemplateCatalog.pick(for: mood, from: popular, limit: limit), "\(mood) \(limit)")
            }
        }
    }

    /// Imgflip's order; Spongebob Ight Imma Head Out, Captain Picard Facepalm and Roll Safe share a word with the cues'
    /// phrases ("tongue out", "duck face", "eye roll") but aren't those faces.
    private let cueTemplates = [
        TemplateRef(id: "181913649", name: "Drake Hotline Bling"),
        TemplateRef(id: "102156234", name: "Mocking Spongebob"),
        TemplateRef(id: "89370399", name: "Roll Safe Think About It"),
        TemplateRef(id: "61582", name: "Creepy Condescending Wonka"),
        TemplateRef(id: "61520", name: "Futurama Fry"),
        TemplateRef(id: "16464531", name: "But That's None Of My Business"),
        TemplateRef(id: "405658", name: "Grumpy Cat"),
        TemplateRef(id: "196652226", name: "Spongebob Ight Imma Head Out"),
        TemplateRef(id: "1509839", name: "Captain Picard Facepalm"),
        TemplateRef(id: "97984", name: "Disaster Girl"),
    ]

    func testFaceCueMoodsPutTheirTemplatesFirst() {
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .tongueOut, from: cueTemplates, limit: 3), [1, 0, 2])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .wink, from: cueTemplates, limit: 3), [2, 3, 0])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .raisedEyebrow, from: cueTemplates, limit: 3), [4, 3, 0])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .duckFace, from: cueTemplates, limit: 3), [5, 0, 1])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .smirk, from: cueTemplates, limit: 3), [3, 9, 2])
        XCTAssertEqual(MemeTemplateCatalog.pick(for: .eyeRoll, from: cueTemplates, limit: 3), [6, 0, 1])
    }

    func testTypedFaceCueWordsFindTheirTemplates() {
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["tongue out"], from: cueTemplates, limit: 5), [1])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["blep"], from: cueTemplates, limit: 5), [1])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["Tongue"], from: cueTemplates, limit: 5), [1])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["wink"], from: cueTemplates, limit: 5), [2, 3])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["raised eyebrow"], from: cueTemplates, limit: 5), [3, 4])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["eyebrow"], from: cueTemplates, limit: 5), [3, 4])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["duck face"], from: cueTemplates, limit: 5), [5])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["kissy"], from: cueTemplates, limit: 5), [5])
        // Disaster Girl is also searched by "smirk".
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["smirk"], from: cueTemplates, limit: 5), [9, 3, 2])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["eye roll"], from: cueTemplates, limit: 5), [6])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["Eye", "roll!"], from: cueTemplates, limit: 5), [6])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["eyeroll"], from: cueTemplates, limit: 5), [6])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["rolling eyes"], from: cueTemplates, limit: 5), [6])
        for word in ["tongue", "blep", "wink", "eyebrow", "kissy", "smirk", "eyeroll"] {
            XCTAssertTrue(MemeTemplateCatalog.isMemeWord(word), word)
        }
        for word in ["wonka", "mckayla"] {
            XCTAssertFalse(MemeTemplateCatalog.isMemeWord(word), word)
        }
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

    func testTypedPoseWordsFindTheirTemplates() {
        let templates = [
            TemplateRef(id: "87743020", name: "Two Buttons"),
            TemplateRef(id: "247375501", name: "Buff Doge vs. Cheems"),
            TemplateRef(id: "1", name: "Y U No"),
            TemplateRef(id: "2", name: "One Does Not Simply"),
            TemplateRef(id: "226297822", name: "Panik Kalm Panik"),
        ]
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["flex"], from: templates, limit: 5), [1])
        // The phrase names a mood; its "no" isn't Y U No's, nor its "oh" anyone's.
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["oh no"], from: templates, limit: 5), [4])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["Oh,", "no!"], from: templates, limit: 5), [4])
        // "oh no" ends on a whole word.
        XCTAssertFalse(MemeTemplateCatalog.pick(forTerms: ["oh nothing"], from: templates, limit: 5).contains(4))
        // The other phrases match from the start of a word: "side eyeing" is "side eye".
        XCTAssertTrue(MemeTemplateCatalog.pick(forTerms: ["side eyeing"], from: popular, limit: 5).contains(2))
    }

    func testWordsThatMatchNothingFindNothing() {
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["zzzz"], from: popular, limit: 5), [])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["x"], from: popular, limit: 5), [])
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: [], from: popular, limit: 5), [])
    }

    func testMemeWordsAreToldFromPossibleNames() {
        for word in ["sad", "LOL", "facepalm", "shrug", "cat", "boyfriend", "mind", "blown"] {
            XCTAssertTrue(MemeTemplateCatalog.isMemeWord(word), word)
        }
        // Names, the memes' ones included: a friend called Jordan stays on the Mac while the panel asks.
        for word in ["sam", "maya", "zorblax", "jordan", "tom", "jack", "chloe", "Leo"] {
            XCTAssertFalse(MemeTemplateCatalog.isMemeWord(word), word)
        }
        // They still find their templates.
        XCTAssertEqual(MemeTemplateCatalog.pick(forTerms: ["pikachu"], from: popular, limit: 5), [3])
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
        // Every mood a face can have has templates of its own; poses without a famous template get the popular ones.
        let withoutTemplates: Set<Mood> = [.reaction, .tPose, .dab, .handsOnHips, .armsCrossed, .pickMe, .hello, .peace, .bow]
        for mood in Mood.allCases where !withoutTemplates.contains(mood) {
            XCTAssertTrue(MemeTemplateCatalog.entries.contains { $0.moods.contains(mood) }, "\(mood)")
        }
    }
}
