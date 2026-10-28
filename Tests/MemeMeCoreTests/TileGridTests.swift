import Foundation
import XCTest
@testable import MemeMeCore

final class TileGridTests: XCTestCase {
    /// 5 × 2 memes and a GIPHY row (slots 10…14).
    private func grid(own: Int, giphy: Int) -> TileGrid {
        TileGrid(columns: 5, ownRows: 2, ownCount: own, giphyCount: giphy)
    }

    func testTheGIPHYRowStartsAfterTheMemeRows() {
        XCTAssertEqual(grid(own: 3, giphy: 5).giphyStart, 10)
        XCTAssertTrue(grid(own: 3, giphy: 5).isFilled(2))
        XCTAssertFalse(grid(own: 3, giphy: 5).isFilled(3))
        XCTAssertTrue(grid(own: 3, giphy: 5).isFilled(10))
        XCTAssertTrue(grid(own: 3, giphy: 5).isFilled(14))
        XCTAssertFalse(grid(own: 3, giphy: 2).isFilled(12))
    }

    func testFocusStartsOnTheFirstMemeElseTheFirstGIPHYTile() {
        XCTAssertEqual(grid(own: 4, giphy: 5).firstSlot, 0)
        XCTAssertEqual(grid(own: 0, giphy: 5).firstSlot, 10)
        XCTAssertNil(grid(own: 0, giphy: 0).firstSlot)
    }

    func testMovingAlongARowStopsAtItsLastTile() {
        let full = grid(own: 10, giphy: 3)
        XCTAssertEqual(full.move(from: 0, dx: 1, dy: 0), 1)
        XCTAssertNil(full.move(from: 0, dx: -1, dy: 0))
        XCTAssertNil(full.move(from: 4, dx: 1, dy: 0))
        XCTAssertEqual(full.move(from: 10, dx: 1, dy: 0), 11)
        XCTAssertNil(full.move(from: 12, dx: 1, dy: 0))
    }

    func testDownGoesFromTheMemesToTheGIPHYRowKeepingTheColumnWhenItCan() {
        let full = grid(own: 10, giphy: 5)
        XCTAssertEqual(full.move(from: 2, dx: 0, dy: 1), 7)
        XCTAssertEqual(full.move(from: 7, dx: 0, dy: 1), 12)
        XCTAssertNil(full.move(from: 12, dx: 0, dy: 1))
        XCTAssertEqual(full.move(from: 12, dx: 0, dy: -1), 7)

        let shortRow = grid(own: 10, giphy: 2)
        XCTAssertEqual(shortRow.move(from: 9, dx: 0, dy: 1), 11)
    }

    func testEmptyMemeRowsAreSkipped() {
        let oneRow = grid(own: 3, giphy: 5)
        XCTAssertEqual(oneRow.move(from: 1, dx: 0, dy: 1), 11)
        XCTAssertEqual(oneRow.move(from: 14, dx: 0, dy: -1), 2)

        let noMemes = grid(own: 0, giphy: 5)
        XCTAssertNil(noMemes.move(from: 12, dx: 0, dy: -1))
        XCTAssertEqual(noMemes.move(from: 12, dx: -1, dy: 0), 11)
    }

    func testNoGIPHYRowKeepsFocusInTheMemes() {
        let memesOnly = grid(own: 7, giphy: 0)
        XCTAssertEqual(memesOnly.move(from: 3, dx: 0, dy: 1), 6)
        XCTAssertNil(memesOnly.move(from: 6, dx: 0, dy: 1))
        XCTAssertNil(grid(own: 0, giphy: 0).move(from: 0, dx: 1, dy: 0))
    }

    func testTheClassicMemesRowComesAfterTheGIPHYRow() {
        let all = TileGrid(columns: 5, ownRows: 2, ownCount: 10, giphyCount: 5, templateCount: 4)
        XCTAssertEqual(all.templateStart, 15)
        XCTAssertTrue(all.isFilled(18))
        XCTAssertFalse(all.isFilled(19))
        XCTAssertEqual(all.move(from: 12, dx: 0, dy: 1), 17)
        XCTAssertEqual(all.move(from: 14, dx: 0, dy: 1), 18)
        XCTAssertEqual(all.move(from: 17, dx: 0, dy: -1), 12)
        XCTAssertNil(all.move(from: 17, dx: 0, dy: 1))
        XCTAssertEqual(all.move(from: 15, dx: 1, dy: 0), 16)

        // No GIPHY row (no key): the memes lead straight to the classic memes.
        let noGIPHY = TileGrid(columns: 5, ownRows: 1, ownCount: 3, giphyCount: 0, templateCount: 5)
        XCTAssertEqual(noGIPHY.move(from: 1, dx: 0, dy: 1), 11)
        XCTAssertEqual(noGIPHY.move(from: 11, dx: 0, dy: -1), 1)

        XCTAssertEqual(TileGrid(columns: 5, ownRows: 0, ownCount: 0, giphyCount: 0, templateCount: 3).firstSlot, 5)
        XCTAssertEqual(TileGrid(columns: 5, ownRows: 2, ownCount: 0, giphyCount: 0, templateCount: 9).templateCount, 5)
    }

    func testCountsAreClampedToTheGrid() {
        let clamped = TileGrid(columns: 5, ownRows: 2, ownCount: 40, giphyCount: 9)
        XCTAssertEqual(clamped.ownCount, 10)
        XCTAssertEqual(clamped.giphyCount, 5)
    }
}
