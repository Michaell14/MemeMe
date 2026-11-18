import Foundation

/// One web search result, with the renditions MemeMe uses.
struct WebGIF: Codable, Hashable {
    let id: String
    let title: String
    let stillURL: URL        // GIPHY images.fixed_width_small_still.url; KLIPY file.sm.jpg
    let previewURL: URL?     // small and animated: GIPHY images.fixed_width_small.url; KLIPY file.sm.gif
    let fullURL: URL         // what is copied: GIPHY images.downsized.url (≤ 2 MB); KLIPY file.md.gif
    let width: Int
    let height: Int
    let pageURL: URL?
    let provider: String     // "GIPHY" or "KLIPY" (`WebService.name`)
    /// Who made or uploaded it (GIPHY's user display name, else username); nil when the service doesn't say.
    var creator: String? = nil
}

/// Where web GIFs and stickers come from. Each has its own key, its own rate limit and its own sources.
enum WebService: String, Sendable, Hashable {
    case giphy, klipy

    /// As the service writes its name: "GIPHY", "KLIPY".
    var name: String {
        switch self {
        case .giphy: return "GIPHY"
        case .klipy: return "KLIPY"
        }
    }

    /// The service a result came from, by its `WebGIF.provider`; GIPHY when it says nothing else.
    init(provider: String) {
        self = provider.uppercased() == WebService.klipy.name ? .klipy : .giphy
    }
}

/// What is searched: a service's GIFs or its stickers (animated, on transparent). Both come back in the same shape.
enum WebKind: String, Sendable {
    case gifs, stickers
}

/// A GIF search backend. Only the mood word, the typed words, or the few words naming a pose (made on the Mac) are
/// ever sent.
protocol GIFProvider: Sendable {
    var name: String { get }
    func search(_ query: String, limit: Int) async throws -> [WebGIF]
    /// What's popular on the service right now; nothing about you is sent.
    func trending(limit: Int) async throws -> [WebGIF]
}

/// A web service's API refused or garbled a request.
enum WebAPIError: Error {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)

    /// The HTTP status the service answered with, nil for any other error. A refused key reads as 401.
    static func status(of error: Error) -> Int? {
        if case let .httpStatus(status)? = error as? WebAPIError {
            return status
        }
        return nil
    }
}
