import Foundation
import XCTest
@testable import MemeMeCore

final class FloatCodingTests: XCTestCase {
    func testRoundTripPreservesEveryBitPattern() throws {
        let values: [Float] = [0, 1, -1.5, Float.pi, Float.greatestFiniteMagnitude, Float.leastNonzeroMagnitude,
                               -Float(0), Float.infinity, -Float.infinity, Float.nan]
        let decoded = try XCTUnwrap(FloatCoding.decode(FloatCoding.encode(values)))
        XCTAssertEqual(decoded.map { $0.bitPattern }, values.map { $0.bitPattern })
    }

    func testEncodingIsBase64OfLittleEndianFloat32() throws {
        XCTAssertEqual(FloatCoding.encode([1]), "AACAPw==")
        XCTAssertEqual(FloatCoding.encode([1, -2, 0.5]), "AACAPwAAAMAAAAA/")
        let bytes = try XCTUnwrap(Data(base64Encoded: FloatCoding.encode([1])))
        XCTAssertEqual([UInt8](bytes), [0x00, 0x00, 0x80, 0x3F])
    }

    func testDecodingKnownBytes() throws {
        let decoded = try XCTUnwrap(FloatCoding.decode("AACAPwAAAMAAAAA/"))
        XCTAssertEqual(decoded, [1, -2, 0.5])
    }

    func testEmptyAndInvalidInput() {
        XCTAssertEqual(FloatCoding.encode([]), "")
        XCTAssertEqual(FloatCoding.decode("")?.count, 0)
        XCTAssertNil(FloatCoding.decode("not base64!"))
        XCTAssertNil(FloatCoding.decode("AAAA"))         // 3 bytes: not a whole Float32
        XCTAssertNil(FloatCoding.decode("AACAPwAA"))     // 6 bytes
    }

    func testLargeVectorRoundTrip() throws {
        let values = (0..<2048).map { Float($0) * 0.001 - 1 }
        let encoded = FloatCoding.encode(values)
        XCTAssertEqual(encoded.count, (2048 * 4 + 2) / 3 * 4)     // base64 length of 8192 bytes
        XCTAssertEqual(try XCTUnwrap(FloatCoding.decode(encoded)), values)
    }
}
