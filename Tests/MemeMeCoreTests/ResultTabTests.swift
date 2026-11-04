import Foundation
import XCTest
@testable import MemeMeCore

final class ResultTabTests: XCTestCase {
    func testTabCyclesForwardAndBackWrappingAround() {
        XCTAssertEqual(ResultTab.allCases, [.forYou, .gifs, .stickers, .memes])
        XCTAssertEqual(ResultTab.forYou.cycled(by: 1), .gifs)
        XCTAssertEqual(ResultTab.memes.cycled(by: 1), .forYou)
        XCTAssertEqual(ResultTab.forYou.cycled(by: -1), .memes)
        XCTAssertEqual(ResultTab.stickers.cycled(by: -5), .gifs)
        XCTAssertEqual(ResultTab.forYou.title, "For You")
        XCTAssertEqual(ResultTab.gifs.title, "GIFs")
    }

    func testEachTabShowsItsKindAndForYouShowsAll() {
        for kind in [TileKind.sticker, .gif, .meme] {
            XCTAssertTrue(ResultTab.forYou.shows(kind))
        }
        XCTAssertTrue(ResultTab.gifs.shows(.gif))
        XCTAssertFalse(ResultTab.gifs.shows(.meme))
        XCTAssertTrue(ResultTab.stickers.shows(.sticker))
        XCTAssertFalse(ResultTab.stickers.shows(.gif))
        XCTAssertTrue(ResultTab.memes.shows(.meme))
        XCTAssertFalse(ResultTab.memes.shows(.sticker))
    }

    func testAnItemsKindIsStickerThenGIFThenMeme() {
        XCTAssertEqual(TileKind(makeItem(isSticker: true, isAnimated: true)), .sticker)
        XCTAssertEqual(TileKind(makeItem(kind: .friend, isSticker: true)), .sticker)
        XCTAssertEqual(TileKind(makeItem(isAnimated: true)), .gif)
        XCTAssertEqual(TileKind(makeItem()), .meme)
    }

    // MARK: For You

    func testYourBestMatchLeadsAndAClassicMemeEndsAFullRow() {
        let row = ForYouMix.row(own: [.meme, .sticker, .meme, .gif, .meme, .sticker], templates: 3, slots: 5)
        XCTAssertEqual(row, [.own(0), .own(1), .own(2), .own(3), .template(0)])
    }

    func testAStickerAndAMemeAreBroughtUpWhenTheRowHasNone() {
        // Four memes would fill the row: the best sticker takes the last meme's place.
        let memes = ForYouMix.row(own: [.meme, .meme, .meme, .meme, .meme, .sticker], templates: 3, slots: 5)
        XCTAssertEqual(memes, [.own(0), .own(1), .own(2), .own(5), .template(0)])

        // GIFs only on top: the sticker and the meme each take a GIF's place, lowest-ranked first.
        let gifs = ForYouMix.row(own: [.gif, .gif, .gif, .gif, .gif, .sticker, .meme], templates: 2, slots: 5)
        XCTAssertEqual(gifs, [.own(0), .own(1), .own(5), .own(6), .template(0)])
    }

    func testTheOnlyOneOfAKindIsNeverPushedOut() {
        // A sticker leads; the meme replaces the lower of the two GIFs, not the sticker.
        let row = ForYouMix.row(own: [.sticker, .gif, .gif, .meme], templates: 0, slots: 3)
        XCTAssertEqual(row, [.own(0), .own(1), .own(3)])
        // One slot: just the best match.
        XCTAssertEqual(ForYouMix.row(own: [.gif, .sticker], templates: 4, slots: 1), [.own(0)])
    }

    func testClassicMemesFillWhatYourThingsDont() {
        XCTAssertEqual(ForYouMix.row(own: [.meme], templates: 9, slots: 5),
                       [.own(0), .template(0), .template(1), .template(2), .template(3)])
        XCTAssertEqual(ForYouMix.row(own: [], templates: 2, slots: 5), [.template(0), .template(1)])
        XCTAssertEqual(ForYouMix.row(own: [.sticker, .sticker, .sticker, .sticker, .sticker], templates: 0, slots: 5),
                       [.own(0), .own(1), .own(2), .own(3), .own(4)], "no memes and no classic memes: stickers only")
        XCTAssertTrue(ForYouMix.row(own: [.meme], templates: 3, slots: 0).isEmpty)
    }
}
