import Foundation

/// The panel's tabs. For You mixes everything: your things in the top row, GIPHY's GIFs under them. GIFs, Stickers and
/// Memes show one kind of thing each; Saved, the things of yours you starred.
public enum ResultTab: String, CaseIterable, Sendable {
    case forYou, gifs, stickers, memes, saved

    public var title: String {
        switch self {
        case .forYou: return "For You"
        case .gifs: return "GIFs"
        case .stickers: return "Stickers"
        case .memes: return "Memes"
        case .saved: return "Saved"
        }
    }

    /// The tab `offset` places along, wrapping around (Tab and Shift-Tab).
    public func cycled(by offset: Int) -> ResultTab {
        let all = ResultTab.allCases
        guard let index = all.firstIndex(of: self) else { return self }
        let count = all.count
        return all[((index + offset) % count + count) % count]
    }

    /// Whether the tab shows your things of `kind`: all of them in For You and Saved (which shows only what you saved),
    /// else its own kind.
    public func shows(_ kind: TileKind) -> Bool {
        switch self {
        case .forYou, .saved: return true
        case .gifs: return kind == .gif
        case .stickers: return kind == .sticker
        case .memes: return kind == .meme
        }
    }
}

/// What one of your things is, for the tabs: a sticker (cut out), a GIF (animated) or a meme (a still image).
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

/// The For You tab's top row: your things mixed with the classic memes.
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
