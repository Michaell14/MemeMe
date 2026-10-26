import Foundation
import XCTest
@testable import MemeMeCore

final class ResultMergerTests: XCTestCase {
    private func result(_ name: String, kind: ItemKind = .mine, score: Double = 0.5) -> RankedResult {
        RankedResult(item: makeItem(name: name, kind: kind), score: score)
    }

    private func names(_ results: [RankedResult]) -> [String] {
        results.map { $0.item.displayName }
    }

    func testKeepsTheLockedPrefixAndFillsWithoutDuplicates() {
        let a = result("a"), b = result("b"), c = result("c"), d = result("d")
        let x = result("x"), y = result("y"), z = result("z")
        let merged = ResultMerger.merge(current: [a, b, c, d], incoming: [x, b, y, z], lockedCount: 2, limit: 5)
        XCTAssertEqual(names(merged), ["a", "b", "x", "y", "z"])
    }

    func testLockedResultsStayInPlaceEvenWhenIncomingRanksThemLower() {
        let a = result("a"), b = result("b"), c = result("c")
        let merged = ResultMerger.merge(current: [a, b, c], incoming: [c, b, a], lockedCount: 1, limit: 3)
        XCTAssertEqual(names(merged), ["a", "c", "b"])
    }

    func testNoLockTakesIncomingUpToTheLimit() {
        let merged = ResultMerger.merge(current: [result("a"), result("b")],
                                        incoming: [result("x"), result("y"), result("z")],
                                        lockedCount: 0, limit: 2)
        XCTAssertEqual(names(merged), ["x", "y"])
    }

    func testLockLargerThanTheCurrentGrid() {
        let merged = ResultMerger.merge(current: [result("a")], incoming: [result("x"), result("y")],
                                        lockedCount: 5, limit: 3)
        XCTAssertEqual(names(merged), ["a", "x", "y"])
    }

    func testLimitCapsTheLockedPrefix() {
        let merged = ResultMerger.merge(current: [result("a"), result("b"), result("c")], incoming: [result("x")],
                                        lockedCount: 3, limit: 2)
        XCTAssertEqual(names(merged), ["a", "b"])
    }

    func testDuplicateIncomingResultsAreSkipped() {
        let x = result("x"), y = result("y")
        let merged = ResultMerger.merge(current: [], incoming: [x, x, y], lockedCount: 0, limit: 5)
        XCTAssertEqual(names(merged), ["x", "y"])
    }

    func testNonPositiveLimitOrNegativeLock() {
        XCTAssertTrue(ResultMerger.merge(current: [result("a")], incoming: [result("x")], lockedCount: 1, limit: 0).isEmpty)
        let merged = ResultMerger.merge(current: [result("a")], incoming: [result("x")], lockedCount: -1, limit: 1)
        XCTAssertEqual(names(merged), ["x"])
    }

    func testStrongOwnPrefix() {
        let results = [result("own", score: 0.8), result("friend", kind: .friend, score: 0.7),
                       result("web", kind: .web, score: 0.9), result("own2", score: 0.9)]
        XCTAssertEqual(ResultMerger.strongOwnPrefix(results), 2)
        XCTAssertEqual(ResultMerger.strongOwnPrefix([result("weak", score: 0.5), result("strong", score: 0.9)]), 0)
        XCTAssertEqual(ResultMerger.strongOwnPrefix([]), 0)
        XCTAssertEqual(ResultMerger.strongOwnPrefix([result("edge", score: 0.6)]), 1)
        let lowBar = [result("a", score: 0.5), result("b", score: 0.45), result("pack", kind: .pack, score: 0.9)]
        XCTAssertEqual(ResultMerger.strongOwnPrefix(lowBar, threshold: 0.4), 2)
    }
}
