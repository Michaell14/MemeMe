import Foundation

/// GIPHY search: `GET https://api.giphy.com/v1/gifs/search?api_key=&q=&limit=&offset=0&rating=&lang=en`.
struct GiphyProvider: GIFProvider {
    private let apiKey: String
    private let rating: String
    private let session: URLSession

    private static let maximumLimit = 50
    private static let requestTimeout: TimeInterval = 10

    init(apiKey: String, rating: String = "pg-13", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.rating = rating
        self.session = session
    }

    var name: String { "GIPHY" }

    /// Decodes `data[]` leniently (numbers arrive as strings) and skips entries without the needed renditions.
    func search(_ query: String, limit: Int) async throws -> [WebGIF] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let clampedLimit = min(GiphyProvider.maximumLimit, max(1, limit))

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.giphy.com"
        components.path = "/v1/gifs/search"
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "q", value: trimmedQuery),
            URLQueryItem(name: "limit", value: String(clampedLimit)),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "rating", value: rating),
            URLQueryItem(name: "lang", value: "en"),
        ]
        guard let url = components.url else { throw GiphyError.invalidRequest }

        var request = URLRequest(url: url)
        request.timeoutInterval = GiphyProvider.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GiphyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw GiphyError.httpStatus(http.statusCode) }

        let decoded = try JSONDecoder().decode(GiphySearchResponse.self, from: data)
        var seenIDs = Set<String>()
        var results: [WebGIF] = []
        for entry in decoded.data {
            guard let gif = makeGIF(from: entry), !seenIDs.contains(gif.id) else { continue }
            seenIDs.insert(gif.id)
            results.append(gif)
        }
        return results
    }

    // MARK: - Mapping

    private func makeGIF(from entry: GiphyEntry) -> WebGIF? {
        let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let smallStill = entry.images["fixed_width_small_still"]
        let wideStill = entry.images["fixed_width_still"]
        let downsized = entry.images["downsized"]
        let original = entry.images["original"]

        var stillRendition: GiphyRendition?
        var stillURL: URL?
        if let url = GiphyProvider.httpsURL(smallStill?.url) {
            stillURL = url
            stillRendition = smallStill
        } else if let url = GiphyProvider.httpsURL(wideStill?.url) {
            stillURL = url
            stillRendition = wideStill
        }

        var fullRendition: GiphyRendition?
        var fullURL: URL?
        if let url = GiphyProvider.httpsURL(downsized?.url) {
            fullURL = url
            fullRendition = downsized
        } else if let url = GiphyProvider.httpsURL(original?.url) {
            fullURL = url
            fullRendition = original
        }

        guard let still = stillURL, let full = fullURL else { return nil }
        let preview = GiphyProvider.httpsURL(entry.images["fixed_width_small"]?.url)

        let width = fullRendition?.width ?? stillRendition?.width ?? 0
        let height = fullRendition?.height ?? stillRendition?.height ?? 0

        return WebGIF(
            id: id,
            title: GiphyProvider.cleanTitle(entry.title),
            stillURL: still,
            previewURL: preview,
            fullURL: full,
            width: max(0, width),
            height: max(0, height),
            pageURL: GiphyProvider.httpsURL(entry.pageURL),
            provider: name,
            creator: entry.creator
        )
    }

    /// Only absolute https URLs are accepted from the response.
    private static func httpsURL(_ string: String?) -> URL? {
        guard let string = string, !string.isEmpty,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    /// "Shocked Oh My God GIF by Some Channel" → "Shocked Oh My God".
    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = title.range(of: " GIF by ", options: [.caseInsensitive, .backwards]) {
            title = String(title[..<range.lowerBound])
        } else if title.lowercased().hasSuffix(" gif") {
            title = String(title.dropLast(4))
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "GIF" : title
    }
}

enum GiphyError: Error {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)

    /// The HTTP status GIPHY answered with, nil for any other error.
    static func status(of error: Error) -> Int? {
        if case let .httpStatus(status)? = error as? GiphyError {
            return status
        }
        return nil
    }
}

// MARK: - Lenient response model

private struct GiphySearchResponse: Decodable {
    let data: [GiphyEntry]

    private enum CodingKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = (try? container.decode([LossyGiphyEntry].self, forKey: .data)) ?? []
        data = entries.compactMap { $0.value }
    }
}

/// Decodes one result without failing the whole array.
private struct LossyGiphyEntry: Decodable {
    let value: GiphyEntry?

    init(from decoder: Decoder) throws {
        value = try? GiphyEntry(from: decoder)
    }
}

private struct GiphyEntry: Decodable {
    let id: String
    let title: String
    let pageURL: String?
    let images: [String: GiphyRendition]
    let creator: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, url, images, user
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else {
            let number = try container.decode(Int.self, forKey: .id)
            id = String(number)
        }
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        pageURL = try? container.decodeIfPresent(String.self, forKey: .url)
        let renditions = (try? container.decodeIfPresent([String: LossyGiphyRendition].self, forKey: .images)) ?? [:]
        var images: [String: GiphyRendition] = [:]
        for (key, rendition) in renditions {
            if let value = rendition.value {
                images[key] = value
            }
        }
        self.images = images
        let user = try? container.decodeIfPresent(GiphyUser.self, forKey: .user)
        creator = user?.name
    }
}

/// The GIF's maker, for attribution.
private struct GiphyUser: Decodable {
    let name: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let names = [CodingKeys.displayName, .username].compactMap { key in
            (try? container.decodeIfPresent(String.self, forKey: key))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        name = names.first { !$0.isEmpty }
    }
}

/// Decodes one rendition without failing the `images` dictionary.
private struct LossyGiphyRendition: Decodable {
    let value: GiphyRendition?

    init(from decoder: Decoder) throws {
        value = try? GiphyRendition(from: decoder)
    }
}

private struct GiphyRendition: Decodable {
    let url: String?
    let width: Int?
    let height: Int?

    private enum CodingKeys: String, CodingKey {
        case url, width, height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        width = GiphyRendition.lenientInt(in: container, forKey: .width)
        height = GiphyRendition.lenientInt(in: container, forKey: .height)
    }

    /// GIPHY sends sizes as strings ("200"); accept plain numbers too.
    private static func lenientInt(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) {
            return number
        }
        if let number = try? container.decodeIfPresent(Double.self, forKey: key), number.isFinite {
            return Int(number)
        }
        return nil
    }
}
