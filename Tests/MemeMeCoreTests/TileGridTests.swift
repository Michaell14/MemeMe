import Foundation
import XCTest
@testable import MemeMeCore

final class TileGridTests: XCTestCase {
    /// 5 × 2 memes, the classic memes row (slots 10…14) and the GIPHY row (slots 15…19).
    private func grid(own: Int, template: Int = 0, giphy: Int) -> TileGrid {
        TileGrid(columns: 5, ownRows: 2, ownCount: own, giphyCount: giphy, templateCount: template)
    }

    func testTheClassicMemesThenTheGIPHYRowComeAfterTheMemeRows() {
        let all = grid(own: 3, template: 4, giphy: 5)
        XCTAssertEqual(all.webStart, 10)
        XCTAssertEqual(all.templateStart, 10)
        XCTAssertEqual(all.giphyStart, 15)
        XCTAssertTrue(all.isFilled(2))
        XCTAssertFalse(all.isFilled(3))
        XCTAssertTrue(all.isFilled(10))
        XCTAssertTrue(all.isFilled(13))
        XCTAssertFalse(all.isFilled(14))
        XCTAssertTrue(all.isFilled(15))
        XCTAssertTrue(all.isFilled(19))
        XCTAssertFalse(grid(own: 3, giphy: 2).isFilled(17))
    }

    func testFocusStartsOnTheFirstTileTopToBottom() {
        XCTAssertEqual(grid(own: 4, template: 6, giphy: 5).firstSlot, 0)
        XCTAssertEqual(grid(own: 0, template: 2, giphy: 5).firstSlot, 10)
        XCTAssertEqual(grid(own: 0, giphy: 5).firstSlot, 15)
        XCTAssertNil(grid(own: 0, giphy: 0).firstSlot)
        XCTAssertEqual(TileGrid(columns: 6, ownRows: 0, ownCount: 0, giphyCount: 6, templateCount: 3).firstSlot, 0)
    }

    func testMovingAlongARowStopsAtItsLastTile() {
        let full = grid(own: 10, template: 2, giphy: 3)
        XCTAssertEqual(full.move(from: 0, dx: 1, dy: 0), 1)
        XCTAssertNil(full.move(from: 0, dx: -1, dy: 0))
        XCTAssertNil(full.move(from: 4, dx: 1, dy: 0))
        XCTAssertEqual(full.move(from: 10, dx: 1, dy: 0), 11)
        XCTAssertNil(full.move(from: 11, dx: 1, dy: 0))
        XCTAssertEqual(full.move(from: 15, dx: 1, dy: 0), 16)
        XCTAssertNil(full.move(from: 17, dx: 1, dy: 0))
    }

    func testDownGoesFromTheMemesToTheClassicMemesThenTheGIPHYRow() {
        // The panel's shape: one row of 6 memes, the classic memes, the GIFs.
        let panel = TileGrid(columns: 6, ownRows: 1, ownCount: 6, giphyCount: 6, templateCount: 6)
        XCTAssertEqual(panel.section(of: 0), .own)
        XCTAssertEqual(panel.section(of: 5), .own)
        XCTAssertEqual(panel.section(of: 6), .template)
        XCTAssertEqual(panel.section(of: 11), .template)
        XCTAssertEqual(panel.section(of: 12), .giphy)
        XCTAssertEqual(panel.section(of: 17), .giphy)
        XCTAssertEqual(panel.move(from: 3, dx: 0, dy: 1), 9)
        XCTAssertEqual(panel.move(from: 9, dx: 0, dy: 1), 15)
        XCTAssertNil(panel.move(from: 15, dx: 0, dy: 1))
        XCTAssertEqual(panel.move(from: 15, dx: 0, dy: -1), 9)
        XCTAssertEqual(panel.move(from: 9, dx: 0, dy: -1), 3)

        // A shorter row below keeps the focus in its last tile.
        let shortRow = TileGrid(columns: 6, ownRows: 1, ownCount: 6, giphyCount: 6, templateCount: 2)
        XCTAssertEqual(shortRow.move(from: 5, dx: 0, dy: 1), 7)
    }

    func testEmptyRowsAreSkipped() {
        let oneMemeRow = grid(own: 3, giphy: 5)
        // No classic memes: the memes lead straight to the GIFs, and back.
        XCTAssertEqual(oneMemeRow.move(from: 1, dx: 0, dy: 1), 16)
        XCTAssertEqual(oneMemeRow.move(from: 19, dx: 0, dy: -1), 2)

        let noMemes = grid(own: 0, template: 5, giphy: 5)
        XCTAssertNil(noMemes.move(from: 12, dx: 0, dy: -1))
        XCTAssertEqual(noMemes.move(from: 12, dx: -1, dy: 0), 11)
        XCTAssertEqual(noMemes.move(from: 12, dx: 0, dy: 1), 17)
    }

    func testNoGIPHYRowKeepsFocusAboveIt() {
        // No GIPHY key: the memes and the classic memes only.
        let noGIPHY = TileGrid(columns: 5, ownRows: 1, ownCount: 3, giphyCount: 0, templateCount: 5)
        XCTAssertEqual(noGIPHY.move(from: 1, dx: 0, dy: 1), 6)
        XCTAssertNil(noGIPHY.move(from: 6, dx: 0, dy: 1))
        XCTAssertEqual(noGIPHY.move(from: 6, dx: 0, dy: -1), 1)

        let memesOnly = grid(own: 7, giphy: 0)
        XCTAssertEqual(memesOnly.move(from: 3, dx: 0, dy: 1), 6)
        XCTAssertNil(memesOnly.move(from: 6, dx: 0, dy: 1))
        XCTAssertNil(grid(own: 0, giphy: 0).move(from: 0, dx: 1, dy: 0))
    }

    func testCountsAreClampedToTheGrid() {
        let clamped = TileGrid(columns: 5, ownRows: 2, ownCount: 40, giphyCount: 9, templateCount: 7)
        XCTAssertEqual(clamped.ownCount, 10)
        XCTAssertEqual(clamped.giphyCount, 5)
        XCTAssertEqual(clamped.templateCount, 5)
    }
}
