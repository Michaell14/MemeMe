import Foundation
import XCTest
@testable import MemeMeCore

final class TileRowsTests: XCTestCase {
    /// The panel's shape: two rows of 5 (slots 0…4 and 5…9).
    private func panel(_ top: Int, _ bottom: Int) -> TileRows {
        TileRows(columns: 5, counts: [top, bottom])
    }

    func testSlotsAreNumberedRowByRowHoweverFullTheRowsAre() {
        let rows = panel(3, 4)
        XCTAssertEqual(rows.slotCount, 10)
        XCTAssertTrue(rows.isFilled(0))
        XCTAssertTrue(rows.isFilled(2))
        XCTAssertFalse(rows.isFilled(3))
        XCTAssertFalse(rows.isFilled(4))
        XCTAssertTrue(rows.isFilled(5))
        XCTAssertTrue(rows.isFilled(8))
        XCTAssertFalse(rows.isFilled(9))
        XCTAssertFalse(rows.isFilled(-1))
        XCTAssertFalse(rows.isFilled(10))
        XCTAssertEqual(rows.row(of: 4), 0)
        XCTAssertEqual(rows.row(of: 5), 1)
        XCTAssertEqual(rows.row(of: 99), 1, "clamped to the last row")
    }

    func testFocusStartsOnTheFirstTileTopToBottom() {
        XCTAssertEqual(panel(4, 5).firstSlot, 0)
        XCTAssertEqual(panel(0, 5).firstSlot, 5, "nothing on top: the bottom row's first tile")
        XCTAssertNil(panel(0, 0).firstSlot)
        XCTAssertNil(TileRows(columns: 5, counts: []).firstSlot)
        XCTAssertEqual(panel(3, 2).lastSlot(inRow: 0), 2)
        XCTAssertEqual(panel(3, 2).lastSlot(inRow: 1), 6)
        XCTAssertNil(panel(0, 2).lastSlot(inRow: 0))
        XCTAssertNil(panel(3, 2).lastSlot(inRow: 2))
    }

    func testMovingAlongARowStopsAtItsLastTile() {
        let rows = panel(5, 3)
        XCTAssertEqual(rows.move(from: 0, dx: 1, dy: 0), 1)
        XCTAssertNil(rows.move(from: 0, dx: -1, dy: 0))
        XCTAssertNil(rows.move(from: 4, dx: 1, dy: 0), "no wrapping into the next row")
        XCTAssertEqual(rows.move(from: 5, dx: 1, dy: 0), 6)
        XCTAssertNil(rows.move(from: 7, dx: 1, dy: 0))
    }

    func testUpAndDownKeepTheColumnOrGoToTheLastTile() {
        let full = panel(5, 5)
        XCTAssertEqual(full.move(from: 3, dx: 0, dy: 1), 8)
        XCTAssertNil(full.move(from: 8, dx: 0, dy: 1))
        XCTAssertEqual(full.move(from: 8, dx: 0, dy: -1), 3)
        XCTAssertNil(full.move(from: 3, dx: 0, dy: -1))

        // A shorter row below keeps the focus in its last tile.
        XCTAssertEqual(panel(5, 2).move(from: 4, dx: 0, dy: 1), 6)
        XCTAssertEqual(panel(1, 5).move(from: 9, dx: 0, dy: -1), 0)
    }

    func testEmptyRowsAreSkipped() {
        let three = TileRows(columns: 5, counts: [3, 0, 4])
        XCTAssertEqual(three.move(from: 1, dx: 0, dy: 1), 11)
        XCTAssertEqual(three.move(from: 13, dx: 0, dy: -1), 2)
        XCTAssertNil(panel(0, 5).move(from: 7, dx: 0, dy: -1))
        XCTAssertNil(panel(4, 0).move(from: 2, dx: 0, dy: 1))
        XCTAssertNil(panel(0, 0).move(from: 0, dx: 1, dy: 0))
    }

    func testCountsAreClampedToTheRow() {
        let clamped = TileRows(columns: 5, counts: [40, -3])
        XCTAssertEqual(clamped.counts, [5, 0])
        XCTAssertEqual(TileRows(columns: 0, counts: [2]).columns, 1)
    }
}
