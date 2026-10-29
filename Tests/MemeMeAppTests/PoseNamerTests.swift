import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// A stand-in for the on-device model, the way the app's tests use one: names from a table, each pose asked about once.
@MainActor
private final class TablePoseNamer: PoseNaming {
    var isAvailable = true
    var names: [String: String] = [:]
    private(set) var questions = 0
    private(set) var prewarms = 0
    private var answers: [String: String?] = [:]

    func cachedName(for description: PoseDescription) -> String?? {
        answers[description.key]
    }

    func prewarm() {
        prewarms += 1
    }

    func name(_ description: PoseDescription) async -> String? {
        if let answer = answers[description.key] {
            return answer
        }
        questions += 1
        let answer = isAvailable ? names[description.key] : nil
        answers[description.key] = .some(answer)
        return answer
    }
}

/// The namer as far as it can be checked without the on-device model, which isn't tested: CI runs on macOS 15, where
/// there is none. Without it nothing waits, the answer is nil and is kept like a real one (so the rule's phrase stands
/// for that pose), and at most 64 answers are kept. On a Mac where Apple Intelligence is ready those checks are
/// skipped.
final class PoseNamerTests: XCTestCase {
    private static let flexing = PoseDescription(
        facts: [
            "One arm: at head height, bent sharply, upper arm out to the side, forearm up, beside the head.",
            "The other arm hangs at the side.",
            "One hand: a fist.",
        ],
        phrase: "flexing"
    )
    private static let horns = PoseDescription(
        facts: ["One hand: index and little fingers straight, the others curled."],
        phrase: "rock on"
    )
    private static let neverAsked: String?? = nil
    private static let noName: String?? = .some(nil)

    @MainActor
    func testWithoutTheModelTheAnswerIsNilAtOnceAndKept() async throws {
        let namer = PoseNamer()
        let macOS26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(macOS26) {
            XCTAssertFalse(namer.isAvailable, "the on-device model needs macOS 26")
        }
        try XCTSkipIf(namer.isAvailable, "Apple Intelligence is ready on this Mac, and the model itself isn't tested")

        namer.prewarm()
        XCTAssertEqual(namer.cachedName(for: PoseNamerTests.flexing), PoseNamerTests.neverAsked)
        let start = Date()
        let name = await namer.name(PoseNamerTests.flexing)
        let waited = Date().timeIntervalSince(start)
        XCTAssertNil(name)
        XCTAssertLessThan(waited, PoseNamer.timeout / 2, "without the model nothing waits for it")
        XCTAssertEqual(namer.cachedName(for: PoseNamerTests.flexing), PoseNamerTests.noName,
                       "asked, and no name: the search uses the rule's phrase at once next time too")
        XCTAssertEqual(namer.cachedName(for: PoseNamerTests.horns), PoseNamerTests.neverAsked,
                       "answers are kept per pose")
        let again = await namer.name(PoseNamerTests.flexing)
        XCTAssertNil(again)
    }

    @MainActor
    func testAtMostSixtyFourAnswersAreKeptTheOldestDroppedFirst() async throws {
        let namer = PoseNamer()
        try XCTSkipIf(namer.isAvailable, "Apple Intelligence is ready on this Mac, and the model itself isn't tested")
        XCTAssertEqual(PoseNamer.cacheLimit, 64)

        let poses = (0...PoseNamer.cacheLimit).map { number in
            PoseDescription(facts: ["One arm: pose \(number)."], phrase: "strike a pose")
        }
        for pose in poses {
            _ = await namer.name(pose)
        }
        XCTAssertEqual(namer.cachedName(for: poses[0]), PoseNamerTests.neverAsked, "the oldest answer made room")
        XCTAssertEqual(namer.cachedName(for: poses[1]), PoseNamerTests.noName)
        XCTAssertEqual(namer.cachedName(for: poses[PoseNamer.cacheLimit]), PoseNamerTests.noName)
    }

    @MainActor
    func testTheModelIsAskedTheFactsThenTheQuestion() {
        let prompt = PoseNamer.prompt(for: PoseNamerTests.flexing)
        let expected: String = "One arm: at head height, bent sharply, upper arm out to the side, forearm up, "
            + "beside the head.\nThe other arm hangs at the side.\nOne hand: a fist.\nWhat are they doing?"
        XCTAssertEqual(prompt, expected, "the facts, one per line, then the question")
        XCTAssertFalse(prompt.contains("flexing"), "the rule's phrase isn't put in the model's mouth")
    }

    @MainActor
    func testAStandInNamesThroughTheProtocolAndKeepsItsAnswers() async {
        let table = TablePoseNamer()
        table.names[PoseNamerTests.horns.key] = "devil horns"
        let namer: PoseNaming = table

        namer.prewarm()
        XCTAssertTrue(namer.isAvailable)
        XCTAssertEqual(namer.cachedName(for: PoseNamerTests.horns), PoseNamerTests.neverAsked)
        let first = await namer.name(PoseNamerTests.horns)
        let second = await namer.name(PoseNamerTests.horns)
        let unnamed = await namer.name(PoseNamerTests.flexing)

        XCTAssertEqual(first, "devil horns")
        XCTAssertEqual(second, "devil horns")
        XCTAssertNil(unnamed)
        let named: String?? = .some("devil horns")
        XCTAssertEqual(namer.cachedName(for: PoseNamerTests.horns), named)
        XCTAssertEqual(namer.cachedName(for: PoseNamerTests.flexing), PoseNamerTests.noName)
        XCTAssertEqual(table.questions, 2, "a pose is asked about once")
        XCTAssertEqual(table.prewarms, 1)
    }
}
