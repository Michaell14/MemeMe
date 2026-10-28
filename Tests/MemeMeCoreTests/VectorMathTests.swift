import Foundation
import XCTest
@testable import MemeMeCore

final class VectorMathTests: XCTestCase {
    func testFloatCosine() {
        let a: [Float] = [1, 2, 3]
        let parallel: [Float] = [2, 4, 6]
        let opposite: [Float] = [-1, -2, -3]
        let x: [Float] = [1, 0]
        let y: [Float] = [0, 1]
        XCTAssertEqual(VectorMath.cosine(a, parallel), 1, accuracy: 1e-9)
        XCTAssertEqual(VectorMath.cosine(a, opposite), -1, accuracy: 1e-9)
        XCTAssertEqual(VectorMath.cosine(x, y), 0, accuracy: 1e-12)
    }

    func testFloatCosineDegenerateInputsAreZero() {
        let a: [Float] = [1, 2, 3]
        let short: [Float] = [1, 2]
        let zero: [Float] = [0, 0, 0]
        let empty: [Float] = []
        XCTAssertEqual(VectorMath.cosine(a, short), 0)
        XCTAssertEqual(VectorMath.cosine(a, zero), 0)
        XCTAssertEqual(VectorMath.cosine(empty, empty), 0)
    }

    func testDoubleCosine() {
        let a: [Double] = [1, 0]
        let b: [Double] = [1, 1]
        let zero: [Double] = [0, 0]
        let longer: [Double] = [1, 1, 1]
        XCTAssertEqual(VectorMath.cosine(a, b), 1 / 2.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(VectorMath.cosine(a, zero), 0)
        XCTAssertEqual(VectorMath.cosine(a, longer), 0)
    }

    func testNormalized() {
        assertVectorsEqual(VectorMath.normalized([3, 4]), [0.6, 0.8])
        XCTAssertEqual(VectorMath.normalized([0, 0, 0]), [0, 0, 0])
        XCTAssertEqual(VectorMath.normalized([1e-12, 0]), [0, 0])
        XCTAssertEqual(VectorMath.normalized([]), [])
        let unit = VectorMath.normalized([1, 2, 3, 4])
        var length = 0.0
        for value in unit { length += value * value }
        XCTAssertEqual(length, 1, accuracy: 1e-12)
    }

    func testMeanAbsDiff() {
        XCTAssertEqual(VectorMath.meanAbsDiff([1, 2, 3], [2, 2, 5]), 1, accuracy: 1e-12)
        XCTAssertEqual(VectorMath.meanAbsDiff([0.5], [-0.5]), 1, accuracy: 1e-12)
        XCTAssertEqual(VectorMath.meanAbsDiff([], []), 0)
        XCTAssertEqual(VectorMath.meanAbsDiff([1, 2, 3], [1, 2]), 0)
    }
}
