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

    // MARK: Described poses

    /// Imgflip's order, with the templates a described pose's words could wrongly find first: The Rock ("rock on"), One
    /// Does Not Simply and Bernie's "Once" ("on"), Epic Handshake ("hand"), The Rock Eyebrow Raise ("raise hand"; found
    /// by name) and Spongebob Ight Imma Head Out ("head").
    private let poseTemplates = [
        TemplateRef(id: "21735", name: "The Rock Driving"),
        TemplateRef(id: "61579", name: "One Does Not Simply"),
        TemplateRef(id: "135256802", name: "Epic Handshake"),
        TemplateRef(id: "777", name: "The Rock Eyebrow Raise"),
        TemplateRef(id: "222403160", name: "Bernie I Am Once Again Asking For Your Support"),
        TemplateRef(id: "196652226", name: "Spongebob Ight Imma Head Out"),
        TemplateRef(id: "89370399", name: "Roll Safe Think About It"),
        TemplateRef(id: "247375501", name: "Buff Doge vs. Cheems"),
        TemplateRef(id: "61544", name: "Success Kid"),
        TemplateRef(id: "61516", name: "Philosoraptor"),
        TemplateRef(id: "110163934", name: "I Bet He's Thinking About Other Women"),
        TemplateRef(id: "100777631", name: "Is This A Pigeon"),
        TemplateRef(id: "155067746", name: "Surprised Pikachu"),
        TemplateRef(id: "999", name: "Some Unknown Template"),
    ]

    func testRockOnIsExcitedNotTheRock() {
        // Excited or celebrating: Buff Doge and Success Kid (first), Epic Handshake (second); then the popular rest,
        // The Rock and One Does Not Simply among them.
        let rockOn = MemeTemplateCatalog.pick(forDescription: "rock on", mood: .reaction, from: poseTemplates, limit: 6)
        XCTAssertEqual(rockOn, [7, 8, 2, 0, 1, 3])
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "Rock on!", mood: .reaction, from: poseTemplates, limit: 6),
                       rockOn)
    }

    func testStopwordsAndBodyWordsFindNothing() {
        // "on" and "one" aren't One Does Not Simply or Bernie's "Once", "hand" isn't Epic Handshake, "head" isn't Ight
        // Imma Head Out: alone they fall back to the mood's order.
        for phrase in ["on", "one", "hand", "hands", "head", "the left arm", "strike a pose", ""] {
            XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: phrase, mood: .reaction, from: poseTemplates, limit: 5),
                           MemeTemplateCatalog.pick(for: .reaction, from: poseTemplates, limit: 5), phrase)
        }
        // A pose's phrase names its moods, not the names starting with its words: "hand on chin" is confused
        // (Philosoraptor, Is This A Pigeon), not Epic Handshake; "raise hand" has no template of its own, and isn't The
        // Rock Eyebrow Raise.
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "hand on chin", mood: .reaction, from: poseTemplates, limit: 3),
                       [9, 11, 0])
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "raise hand", mood: .reaction, from: poseTemplates, limit: 5),
                       MemeTemplateCatalog.pick(for: .reaction, from: poseTemplates, limit: 5))
    }

    func testADescribedPosesWordsPutItsTemplatesFirst() {
        // "thinking": Philosoraptor (searched by it, and confused first), I Bet He's Thinking (in its name), Roll Safe
        // (searched by it), Is This A Pigeon (confused first); then shocked's order: Surprised Pikachu, The Rock Driving.
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "thinking", mood: .shocked, from: poseTemplates, limit: 6),
                       [9, 10, 6, 11, 12, 0])
        // "flexing" is flex: Buff Doge, then shocked's.
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "flexing", mood: .shocked, from: poseTemplates, limit: 3),
                       [7, 12, 0])
        for phrase in ["flex", "Flexing!", "muscles", "bicep"] {
            XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: phrase, mood: .reaction, from: poseTemplates, limit: 1),
                           [7], phrase)
        }
        for word in ["horns", "flexing", "bicep", "salute", "pondering"] {
            XCTAssertTrue(MemeTemplateCatalog.isMemeWord(word), word)
        }
    }

    func testAnUnknownPhraseFallsBackToTheMoodsOrder() {
        for page in 0..<4 {
            XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "strike a pose", mood: .shocked, from: poseTemplates,
                                                    limit: 5, page: page),
                           MemeTemplateCatalog.pick(for: .shocked, from: poseTemplates, limit: 5, page: page), "page \(page)")
            XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "zzzz", mood: .reaction, from: popular, limit: 5, page: page),
                           MemeTemplateCatalog.pick(for: .reaction, from: popular, limit: 5, page: page), "page \(page)")
        }
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "strike a pose", mood: .sad, from: popular, limit: 5),
                       [4, 5, 0, 1, 2])
        // Never empty while there are templates; nothing to pick from, or no room, is nothing.
        for phrase in ["strike a pose", "rock on", "", "!!"] {
            for mood in [Mood.reaction, .sad, .flex] {
                XCTAssertFalse(MemeTemplateCatalog.pick(forDescription: phrase, mood: mood, from: popular, limit: 1).isEmpty,
                               "\(phrase) \(mood)")
            }
        }
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "rock on", mood: .excited, from: [], limit: 5), [])
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "rock on", mood: .excited, from: popular, limit: 0), [])
    }

    func testDescribedPagesWrapAroundWithoutRepeats() {
        // Buff Doge, then shocked's (Surprised Pikachu, The Rock Driving), then the popular rest: all 14, each once.
        let order = [7, 12, 0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 13]
        func flexing(page: Int, limit: Int = 6) -> [Int] {
            MemeTemplateCatalog.pick(forDescription: "flexing", mood: .shocked, from: self.poseTemplates, limit: limit,
                                     page: page)
        }
        XCTAssertEqual(MemeTemplateCatalog.pick(forDescription: "flexing", mood: .shocked, from: poseTemplates, limit: 6),
                       flexing(page: 0))
        XCTAssertEqual(flexing(page: 0), Array(order[0..<6]))
        XCTAssertEqual(flexing(page: 1), Array(order[6..<12]))
        XCTAssertEqual(flexing(page: 2), [11, 13, 7, 12, 0, 1])
        XCTAssertEqual(flexing(page: -1), flexing(page: 0))
        XCTAssertEqual(flexing(page: 3, limit: 20), order, "fewer templates than a page: every page is all of them")
        for page in 0..<order.count {
            let shown = flexing(page: page)
            XCTAssertEqual(Set(shown).count, 6, "page \(page) repeats a template")
            // The same wrap as a mood's pages: the page'th group of 6 from the order.
            XCTAssertEqual(shown, (0..<6).map { order[(page * 6 + $0) % order.count] }, "page \(page)")
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
        // Every mood a face can have has templates of its own; poses without a famous template get the popular ones.
        let withoutTemplates: Set<Mood> = [.reaction, .tPose, .dab, .handsOnHips, .armsCrossed, .pickMe, .hello, .peace, .bow]
        for mood in Mood.allCases where !withoutTemplates.contains(mood) {
            XCTAssertTrue(MemeTemplateCatalog.entries.contains { $0.moods.contains(mood) }, "\(mood)")
        }
        // A described pose's words: lowercase, one space apart, naming moods (each once) other than no face at all.
        for (phrase, moods) in MemeTemplateCatalog.describedPoses {
            XCTAssertEqual(phrase, phrase.lowercased().split(separator: " ").joined(separator: " "), phrase)
            XCTAssertFalse(moods.isEmpty, phrase)
            XCTAssertFalse(moods.contains(.reaction), phrase)
            XCTAssertEqual(Set(moods).count, moods.count, phrase)
        }
    }
}
