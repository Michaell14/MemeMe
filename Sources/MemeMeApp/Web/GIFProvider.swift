import Foundation

/// One web search result, with the renditions MemeMe uses.
struct WebGIF: Codable, Hashable {
    let id: String
    let title: String
    let stillURL: URL        // GIPHY images.fixed_width_small_still.url (fallback fixed_width_still)
    let previewURL: URL?     // images.fixed_width_small.url (animated, small)
    let fullURL: URL         // images.downsized.url (≤ 2 MB), fallback original
    let width: Int
    let height: Int
    let pageURL: URL?
    let provider: String     // "GIPHY"
    /// Who made or uploaded it (GIPHY's user display name, else username); nil when GIPHY doesn't say.
    var creator: String? = nil
}

/// A GIF search backend. Only the mood word, or the typed words, are ever sent.
protocol GIFProvider: Sendable {
    var name: String { get }
    func search(_ query: String, limit: Int) async throws -> [WebGIF]
}
