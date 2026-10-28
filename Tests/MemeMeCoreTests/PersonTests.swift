import Foundation
import XCTest
@testable import MemeMeCore

final class PersonTests: XCTestCase {
    func testDisplayName() {
        XCTAssertEqual(Person().displayName, "New face")
        XCTAssertEqual(Person(name: "Maya").displayName, "Maya")
        XCTAssertEqual(Person(name: "  ").displayName, "New face")
    }

    func testAddEmbeddingKeepsTheNewestTwenty() {
        var person = Person()
        for index in 0..<25 {
            person.addEmbedding([Float(index)])
        }
        let first: [Float] = [5]
        let last: [Float] = [24]
        XCTAssertEqual(person.embeddings.count, 20)
        XCTAssertEqual(person.embeddings.first, first)
        XCTAssertEqual(person.embeddings.last, last)
    }

    func testInitializerCapsEmbeddings() {
        let embeddings = (0..<22).map { [Float($0)] }
        let person = Person(embeddings: embeddings)
        XCTAssertEqual(person.embeddings, Array(embeddings.suffix(20)))
    }

    func testCodableStoresEmbeddingsAsBase64() throws {
        let person = Person(name: "Maya", embeddings: [[1, 2], [0.5]], createdAt: TestDates.march15)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(person)

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expectedEmbeddings: [String] = [FloatCoding.encode([1, 2]), FloatCoding.encode([0.5])]
        XCTAssertEqual(object["embeddings"] as? [String], expectedEmbeddings)
        XCTAssertEqual(object["name"] as? String, "Maya")
        XCTAssertEqual(try decoder.decode(Person.self, from: data), person)
    }

    func testDecodingMinimalJSON() throws {
        let id = UUID()
        let json = #"{"id": "\#(id.uuidString)"}"#
        let person = try JSONDecoder().decode(Person.self, from: Data(json.utf8))
        XCTAssertEqual(person.id, id)
        XCTAssertNil(person.name)
        XCTAssertTrue(person.embeddings.isEmpty)
        XCTAssertEqual(person.createdAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(person.displayName, "New face")
    }

    func testConfidentMatch() {
        let maya = Person(name: "Maya", embeddings: [[1, 0, 0]])
        let jordan = Person(name: "Jordan", embeddings: [[0, 1, 0]])
        XCTAssertEqual(FriendMatcher().match([1, 0, 0], among: [jordan, maya]), .confident(maya.id))
        XCTAssertEqual(FriendMatcher().match([0, 2, 0], among: [jordan, maya]), .confident(jordan.id))
    }

    func testLikelyMatchCarriesTheScore() {
        let maya = Person(embeddings: [[1, 0, 0]])
        let result = FriendMatcher().match([1, 0.6, 0], among: [maya])     // cosine ≈ 0.857
        guard case let .likely(id, score) = result else {
            return XCTFail("expected .likely, got \(result)")
        }
        XCTAssertEqual(id, maya.id)
        XCTAssertEqual(score, 1 / 1.36.squareRoot(), accuracy: 1e-6)
    }

    func testNewFaceBelowThresholdsOrWithoutCandidates() {
        let maya = Person(embeddings: [[1, 0, 0]])
        XCTAssertEqual(FriendMatcher().match([0, 0, 1], among: [maya]), .newFace)
        XCTAssertEqual(FriendMatcher().match([1, 0, 0], among: []), .newFace)
        XCTAssertEqual(FriendMatcher().match([1, 0, 0], among: [Person()]), .newFace)
        XCTAssertEqual(FriendMatcher().match([1, 0], among: [maya]), .newFace)      // different embedding size
    }

    func testScoreIsTheMeanOfTheTopThree() {
        let steady = Person(embeddings: [[1, 0], [1, 0], [1, 0], [0, 1]])   // top three: 1, 1, 1
        let mixed = Person(embeddings: [[1, 0], [0, 1]])                     // mean(1, 0) = 0.5
        XCTAssertEqual(FriendMatcher().match([1, 0], among: [mixed, steady]), .confident(steady.id))
        XCTAssertEqual(FriendMatcher().match([1, 0], among: [mixed]), .newFace)
    }

    func testCustomThresholds() {
        let person = Person(embeddings: [[1, 0, 0]])
        let matcher = FriendMatcher(confidentThreshold: 0.99, likelyThreshold: 0.5)
        XCTAssertEqual(matcher.confidentThreshold, 0.99)
        XCTAssertEqual(matcher.likelyThreshold, 0.5)
        let result = matcher.match([1, 1, 0], among: [person])     // cosine ≈ 0.707
        guard case let .likely(id, score) = result else {
            return XCTFail("expected .likely, got \(result)")
        }
        XCTAssertEqual(id, person.id)
        XCTAssertEqual(score, 0.5.squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(FriendMatcher().confidentThreshold, 0.90)
        XCTAssertEqual(FriendMatcher().likelyThreshold, 0.80)
    }
}
