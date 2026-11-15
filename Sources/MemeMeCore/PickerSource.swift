import Foundation

/// Where the panel's results come from: the source menu beside the search field. All Sources mixes everything and
/// is what the panel opens on; the others show one place each: your favorites, what MemeMe found on this Mac, your
/// stickers, GIPHY's GIFs or stickers, or the classic memes.
public enum PickerSource: String, CaseIterable, Sendable {
    case all, favorites, onMyMac, myStickers, giphyGIFs, giphyStickers, classicMemes

    public var title: String {
        switch self {
        case .all: return "All Sources"
        case .favorites: return "Favorites"
        case .onMyMac: return "On My Mac"
        case .myStickers: return "My Stickers"
        case .giphyGIFs: return "GIPHY GIFs"
        case .giphyStickers: return "GIPHY Stickers"
        case .classicMemes: return "Classic Memes"
        }
    }

    /// The menu's groups, separated by a line: everything; yours; GIPHY's; the classic memes.
    public var group: Int {
        switch self {
        case .all: return 0
        case .favorites, .onMyMac, .myStickers: return 1
        case .giphyGIFs, .giphyStickers: return 2
        case .classicMemes: return 3
        }
    }

    /// The source `offset` places along, wrapping around (Tab and Shift-Tab).
    public func cycled(by offset: Int) -> PickerSource {
        let all = PickerSource.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        let count = all.count
        return all[((index + offset) % count + count) % count]
    }

    /// Whether the source shows your things of `kind`: every kind in All Sources and Favorites (which shows only what
    /// you starred); On My Mac your images and GIFs; My Stickers your stickers and your friends'; none on the web's.
    public func shows(_ kind: TileKind) -> Bool {
        switch self {
        case .all, .favorites: return true
        case .onMyMac: return kind != .sticker
        case .myStickers: return kind == .sticker
        case .giphyGIFs, .giphyStickers, .classicMemes: return false
        }
    }

    /// Shows any of your own things.
    public var showsOwn: Bool {
        switch self {
        case .all, .favorites, .onMyMac, .myStickers: return true
        case .giphyGIFs, .giphyStickers, .classicMemes: return false
        }
    }

    /// One of GIPHY's: its glyph is GIPHY's letter.
    public var isGiphy: Bool { self == .giphyGIFs || self == .giphyStickers }

    public var showsGiphyGIFs: Bool { self == .all || self == .giphyGIFs }
    public var showsGiphyStickers: Bool { self == .giphyStickers }
    public var showsTemplates: Bool { self == .all || self == .classicMemes }
}

/// What one of your things is, for the sources: a sticker (cut out), a GIF (animated) or a meme (a still image).
public enum TileKind: Equatable, Sendable {
    case sticker, gif, meme

    public init(_ item: LibraryItem) {
        if item.isSticker {
            self = .sticker
        } else if item.isAnimated {
            self = .gif
        } else {
            self = .meme
        }
    }
}

/// All Sources' first row: your things mixed with the classic memes.
public enum ForYouMix {
    public enum Pick: Equatable, Sendable {
        /// An index into your ranked things.
        case own(Int)
        /// An index into the classic memes, in their order.
        case template(Int)
    }

    /// `slots` tiles from your things (`own`: their kinds, best match first) and the classic memes (`templates` of
    /// them). Your best match comes first and the rest keep their rank, but a sticker and a meme are among them when
    /// your things have one (the lowest-ranked of a kind shown twice makes room); the last slot is a classic meme
    /// when your things would fill the row; classic memes fill what your things don't.
    public static func row(own: [TileKind], templates: Int, slots: Int) -> [Pick] {
        guard slots > 0 else { return [] }
        // Your best match always leads, so a lone slot is never a classic meme's.
        let reserved = templates > 0 && slots > 1 && own.count >= slots ? 1 : 0
        var chosen = Array(0..<min(own.count, slots - reserved))
        for wanted in [TileKind.sticker, .meme] {
            guard !chosen.contains(where: { own[$0] == wanted }),
                  let candidate = own.indices.first(where: { own[$0] == wanted && !chosen.contains($0) }),
                  let victim = chosen.indices.dropFirst().reversed().first(where: { position in
                      let kind = own[chosen[position]]
                      return chosen.filter { own[$0] == kind }.count > 1
                  }) else { continue }
            chosen[victim] = candidate
            chosen.sort()
        }
        let fill = min(max(0, slots - chosen.count), max(0, templates))
        return chosen.map { Pick.own($0) } + (0..<fill).map { Pick.template($0) }
    }
}
