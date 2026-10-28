import Foundation
@testable import MemeMeApp
import MemeMeCore
import XCTest

/// File names handed to chat apps must never leak names: only the user's own files keep theirs.
final class ClipboardNamingTests: XCTestCase {
    func testOwnItemsKeepTheirFileName() {
        let gif = LibraryItem(
            fileURL: URL(fileURLWithPath: "/Users/me/Downloads/Shocked cat.gif"),
            displayName: "Shocked cat",
            kind: .mine,
            source: "Downloads",
            contentHash: "own-gif",
            isAnimated: true
        )
        XCTAssertEqual(Clipboard.neutralFileName(for: gif), "Shocked cat.gif")

        let still = LibraryItem(
            fileURL: URL(fileURLWithPath: "/Users/me/Desktop/this is fine.jpeg"),
            displayName: "this is fine",
            kind: .mine,
            source: "Desktop",
            contentHash: "own-still"
        )
        XCTAssertEqual(Clipboard.neutralFileName(for: still), "this is fine.jpeg")
    }

    func testFriendStickersAreAlwaysStickerPNG() {
        let sticker = LibraryItem(
            fileURL: URL(fileURLWithPath: "/Users/me/Library/Application Support/MemeMe/Stickers/sticker-5F1C.png"),
            displayName: "Maya — happy",
            kind: .friend,
            source: "Friend sticker",
            sourceDetail: "IMG_2207.HEIC",
            contentHash: "friend-sticker",
            isSticker: true,
            personID: UUID()
        )
        let name = Clipboard.neutralFileName(for: sticker)
        XCTAssertEqual(name, "sticker.png")
        XCTAssertFalse(name.contains("Maya"))
        XCTAssertFalse(name.contains("IMG_2207"))
    }

    func testWebGIFsAreReactionGIF() {
        let animated = LibraryItem(
            fileURL: URL(fileURLWithPath: "/Users/me/Library/Caches/MemeMe/Web/files/FiGiRei2ICzzG-still.gif"),
            displayName: "Shocked Oh My God",
            kind: .web,
            source: "GIPHY",
            contentHash: "giphy:FiGiRei2ICzzG",
            isAnimated: true,
            remoteURL: URL(string: "https://media2.giphy.com/media/FiGiRei2ICzzG/giphy-downsized.gif"),
            previewURL: URL(string: "https://media2.giphy.com/media/FiGiRei2ICzzG/100w.gif"),
            attribution: "via GIPHY"
        )
        XCTAssertEqual(Clipboard.neutralFileName(for: animated), "reaction.gif")

        // The cached still may be a JPEG; the full rendition that gets copied is a GIF.
        let jpegStill = LibraryItem(
            fileURL: URL(fileURLWithPath: "/Users/me/Library/Caches/MemeMe/Web/files/abc-still.jpg"),
            displayName: "Side eye",
            kind: .web,
            source: "GIPHY",
            contentHash: "giphy:abc",
            remoteURL: URL(string: "https://media1.giphy.com/media/abc/giphy-downsized.gif")
        )
        XCTAssertEqual(Clipboard.neutralFileName(for: jpegStill), "reaction.gif")
    }

    func testWebAndPackStillsAreReactionPNG() {
        let webStill = LibraryItem(
            fileURL: URL(fileURLWithPath: "/Users/me/Library/Caches/MemeMe/Web/files/xyz-still.jpg"),
            displayName: "Unimpressed",
            kind: .web,
            source: "GIPHY",
            contentHash: "giphy:xyz",
            isAnimated: false,
            remoteURL: URL(string: "https://media.example.com/xyz/full.jpg")
        )
        XCTAssertEqual(Clipboard.neutralFileName(for: webStill), "reaction.png")

        let packStill = LibraryItem(
            fileURL: URL(fileURLWithPath: "/Applications/MemeMe.app/Contents/Resources/Pack/distracted boyfriend.png"),
            displayName: "distracted boyfriend",
            kind: .pack,
            source: "Starter pack",
            contentHash: "pack-still"
        )
        XCTAssertEqual(Clipboard.neutralFileName(for: packStill), "reaction.png")
    }
}
