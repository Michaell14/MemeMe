import Foundation
import XCTest
@testable import MemeMeCore

final class HeldFaceReadingTests: XCTestCase {
    private let baseline = RestingBaseline()

    func testARestingFaceReadsNothingButKeepsTheListsLength() {
        let cues = HeldFaceReading.cues(face: TestFaces.neutral, baseline: baseline)
        XCTAssertEqual(cues.map(\.label), ["Brows up", "Eyes wide", "Mouth open", "Smile"])
        XCTAssertTrue(cues.allSatisfy { $0.level == 0 })
        XCTAssertTrue(HeldFaceReading.glow(of: cues).isEmpty, "nothing glows")
    }

    func testSurpriseReadsBrowsEyesAndMouthStrongestFirst() {
        // Brows and eyes +0.2 (of 0.3), mouth open +0.6 (of 0.4).
        let cues = HeldFaceReading.cues(face: TestFaces.surprise, baseline: baseline)
        XCTAssertEqual(cues.first, HeldFaceReading.Cue(label: "Mouth open", region: .mouth, level: 5))
        XCTAssertEqual(Array(cues.dropFirst().prefix(2)), [
            HeldFaceReading.Cue(label: "Brows up", region: .brows, level: 3),
            HeldFaceReading.Cue(label: "Eyes wide", region: .eyes, level: 3),
        ])
        XCTAssertEqual(HeldFaceReading.glow(of: cues), [.mouth: 5, .brows: 3, .eyes: 3])
    }

    func testEachChangeReadsItsOwnWay() {
        let frown = makeFace(brow: 0.3, eye: 0.3, smile: 0.3)
        let labels = HeldFaceReading.cues(face: frown, baseline: baseline, limit: 7).map(\.label)
        XCTAssertEqual(Array(labels.prefix(3)), ["Frown", "Brows down", "Eyes narrowed"])
        XCTAssertFalse(labels.contains("Smile"))
        // A mouth more closed than at rest isn't a cue of its own.
        let closed = HeldFaceReading.cues(face: makeFace(mouth: 0), baseline: baseline, limit: 7)
        XCTAssertEqual(closed.first(where: { $0.label == "Mouth open" })?.level, 0)
    }

    func testAClearCueFromTheShapeIsNamed() {
        let rest = FaceShape(leftEyeOpen: 0.25, rightEyeOpen: 0.25)
        let reading = RestingBaseline(restShape: rest)
        let wink = FaceShape(leftEyeOpen: 0.05, rightEyeOpen: 0.26)
        let cues = HeldFaceReading.cues(face: TestFaces.neutral, shape: wink, baseline: reading)
        XCTAssertEqual(cues.first?.label, "Wink")
        XCTAssertEqual(cues.first?.region, .eyes)
        XCTAssertGreaterThan(cues.first?.level ?? 0, 2)
    }

    func testLevelsStayWithinFive() {
        XCTAssertEqual(HeldFaceReading.Cue(label: "x", region: nil, level: 9).level, 5)
        XCTAssertEqual(HeldFaceReading.Cue(label: "x", region: nil, level: -2).level, 0)
        XCTAssertTrue(HeldFaceReading.cues(face: TestFaces.surprise, baseline: baseline, limit: 0).isEmpty)
    }
}
