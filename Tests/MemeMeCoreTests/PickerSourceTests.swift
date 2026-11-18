import Foundation
import XCTest
@testable import MemeMeCore

final class PickerSourceTests: XCTestCase {
    func testSourcesCycleForwardAndBackWrappingAround() {
        XCTAssertEqual(PickerSource.allCases,
                       [.all, .favorites, .onMyMac, .myStickers, .giphyGIFs, .giphyStickers, .klipyGIFs, .klipyStickers,
                        .classicMemes])
        XCTAssertEqual(PickerSource.all.cycled(by: 1), .favorites)
        XCTAssertEqual(PickerSource.classicMemes.cycled(by: 1), .all)
        XCTAssertEqual(PickerSource.all.cycled(by: -1), .classicMemes)
        XCTAssertEqual(PickerSource.onMyMac.cycled(by: -9), .onMyMac)
        XCTAssertEqual(PickerSource.onMyMac.cycled(by: -10), .favorites)
        XCTAssertEqual(PickerSource.all.title, "All Sources")
        XCTAssertEqual(PickerSource.onMyMac.title, "On My Mac")
        XCTAssertEqual(PickerSource.giphyGIFs.title, "GIPHY GIFs")
        XCTAssertEqual(PickerSource.klipyStickers.title, "KLIPY Stickers")
        XCTAssertEqual(PickerSource.allCases.map(\.group), [0, 1, 1, 1, 2, 2, 3, 3, 4])
        XCTAssertEqual(PickerSource.allCases.compactMap(\.letter), ["G", "G", "K", "K"])
    }

    func testEachSourceShowsItsOwnThings() {
        for kind in [TileKind.sticker, .gif, .meme] {
            XCTAssertTrue(PickerSource.all.shows(kind))
            XCTAssertTrue(PickerSource.favorites.shows(kind), "Favorites shows every kind you starred")
            XCTAssertFalse(PickerSource.giphyGIFs.shows(kind), "GIPHY's sources show only GIPHY's")
            XCTAssertFalse(PickerSource.klipyGIFs.shows(kind), "KLIPY's sources show only KLIPY's")
            XCTAssertFalse(PickerSource.klipyStickers.shows(kind))
            XCTAssertFalse(PickerSource.classicMemes.shows(kind))
        }
        XCTAssertTrue(PickerSource.onMyMac.shows(.meme))
        XCTAssertTrue(PickerSource.onMyMac.shows(.gif), "your own GIFs are on your Mac, not in GIPHY GIFs")
        XCTAssertFalse(PickerSource.onMyMac.shows(.sticker))
        XCTAssertTrue(PickerSource.myStickers.shows(.sticker))
        XCTAssertFalse(PickerSource.myStickers.shows(.meme))
        XCTAssertEqual(PickerSource.allCases.filter(\.showsGiphyGIFs), [.all, .giphyGIFs])
        XCTAssertEqual(PickerSource.allCases.filter(\.showsTemplates), [.all, .classicMemes])
        XCTAssertEqual(PickerSource.allCases.filter(\.showsGiphyStickers), [.giphyStickers])
        XCTAssertEqual(PickerSource.allCases.filter(\.showsOwn), [.all, .favorites, .onMyMac, .myStickers])
    }

    func testAnItemsKindIsStickerThenGIFThenMeme() {
        XCTAssertEqual(TileKind(makeItem(isSticker: true, isAnimated: true)), .sticker)
        XCTAssertEqual(TileKind(makeItem(kind: .friend, isSticker: true)), .sticker)
        XCTAssertEqual(TileKind(makeItem(isAnimated: true)), .gif)
        XCTAssertEqual(TileKind(makeItem()), .meme)
    }

    // MARK: All Sources' first row

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

    func testTheHomePageTakesTurnsBetweenYoursTrendingGIFsAndClassicMemes() {
        XCTAssertEqual(HomeMix.picks(own: 2, gifs: 2, templates: 2),
                       [.own(0), .gif(0), .template(0), .own(1), .gif(1), .template(1)])
        // Yours run out first: GIPHY's and the classic memes keep taking turns.
        XCTAssertEqual(HomeMix.picks(own: 1, gifs: 3, templates: 1),
                       [.own(0), .gif(0), .template(0), .gif(1), .gif(2)])
        // First run (nothing of yours) or Web Discover off.
        XCTAssertEqual(HomeMix.picks(own: 0, gifs: 1, templates: 2), [.gif(0), .template(0), .template(1)])
        XCTAssertEqual(HomeMix.picks(own: 3, gifs: 0, templates: 0), [.own(0), .own(1), .own(2)])
        XCTAssertTrue(HomeMix.picks(own: 0, gifs: 0, templates: -1).isEmpty)
    }
}
