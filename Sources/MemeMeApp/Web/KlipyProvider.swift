import Foundation

/// KLIPY search: `GET https://api.klipy.com/api/v1/{key}/gifs/search?q=&per_page=&page=1&customer_id=&content_filter=`,
/// or `/stickers/search` for KLIPY's stickers. `trending` asks `/gifs/trending` (or `/stickers/trending`) the same way,
/// without a query. The key goes in the path, not the query.
///
/// Results are `data.data[]`, each with `file.{hd,md,sm,xs}.{gif,webp,jpg,png,mp4}` renditions of `url`, `width` and
/// `height`. Ads (`type: "ad"`) are skipped; none are asked for.
struct KlipyProvider: GIFProvider {
    private let apiKey: String
    private let kind: WebKind
    private let contentFilter: String
    private let session: URLSession

    /// KLIPY's `per_page` is 8 to 50.
    private static let minimumLimit = 8
    private static let maximumLimit = 50
    private static let requestTimeout: TimeInterval = 10

    /// KLIPY asks each request for a `customer_id`. This one is random and new each launch: it names no one and
    /// doesn't follow you from one launch to the next.
    static let launchCustomerID = UUID().uuidString.lowercased()

    init(apiKey: String, kind: WebKind = .gifs, contentFilter: String = "medium", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.kind = kind
        self.contentFilter = contentFilter
        self.session = session
    }

    var name: String { WebService.klipy.name }

    func search(_ query: String, limit: Int) async throws -> [WebGIF] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        return try await fetch(endpoint: "search", query: [URLQueryItem(name: "q", value: trimmedQuery)], limit: limit)
    }

    func trending(limit: Int) async throws -> [WebGIF] {
        try await fetch(endpoint: "trending", query: [], limit: limit)
    }

    private func fetch(endpoint: String, query: [URLQueryItem], limit: Int) async throws -> [WebGIF] {
        // The key is a path segment: anything but letters, digits, "-" and "_" would change the path.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy(KlipyProvider.isKeyCharacter) else {
            throw WebAPIError.httpStatus(401)
        }
        let perPage = min(KlipyProvider.maximumLimit, max(KlipyProvider.minimumLimit, limit))

        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.klipy.com"
        components.path = "/api/v1/\(key)/\(kind.rawValue)/\(endpoint)"
        components.queryItems = query + [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "customer_id", value: KlipyProvider.launchCustomerID),
            URLQueryItem(name: "content_filter", value: contentFilter),
        ]
        guard let url = components.url else { throw WebAPIError.invalidRequest }

        var request = URLRequest(url: url)
        request.timeoutInterval = KlipyProvider.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebAPIError.invalidResponse }
        let decoded = try? JSONDecoder().decode(KlipyResponse.self, from: data)
        guard (200..<300).contains(http.statusCode), decoded?.result != false else {
            throw WebAPIError.httpStatus(KlipyProvider.status(http.statusCode, refusal: decoded))
        }
        guard let decoded else { throw WebAPIError.invalidResponse }

        var seenIDs = Set<String>()
        var results: [WebGIF] = []
        for entry in decoded.items {
            guard let gif = makeGIF(from: entry), !seenIDs.contains(gif.id) else { continue }
            seenIDs.insert(gif.id)
            results.append(gif)
        }
        return Array(results.prefix(limit))
    }

    /// KLIPY answers an unknown key with 404 and `"result": false`; that reads as a refused key (401), as GIPHY's
    /// would. A 200 that says `"result": false` reads as a refusal too.
    static func status(_ status: Int, refusal: KlipyResponse?) -> Int {
        switch status {
        case 401, 403, 429: return status
        case 200..<300: return refusal?.mentionsKey == true ? 401 : 502
        case 400..<500 where refusal?.result == false: return 401
        default: return status
        }
    }

    private static func isKeyCharacter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        let value = scalar.value
        return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
            || value == 45 || value == 95
    }

    // MARK: - Mapping

    private func makeGIF(from entry: KlipyEntry) -> WebGIF? {
        guard entry.type?.lowercased() != "ad" else { return nil }
        let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        let hd = entry.file["hd"], md = entry.file["md"], sm = entry.file["sm"], xs = entry.file["xs"]
        // A sticker's still keeps its transparency (no JPEG); a GIF's is the small JPEG.
        let stillFormats = kind == .stickers ? ["png", "webp", "gif"] : ["jpg", "webp", "gif"]
        let still = KlipyProvider.first(in: [sm, xs, md], formats: stillFormats)
        let full = KlipyProvider.first(in: [md, hd, sm], formats: ["gif"])
        guard let stillURL = still?.url, let fullURL = full?.url else { return nil }
        let preview = KlipyProvider.first(in: [sm, xs], formats: ["gif"])

        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return WebGIF(
            id: id,
            title: title.isEmpty ? (kind == .stickers ? "Sticker" : "GIF") : title,
            stillURL: stillURL,
            previewURL: preview?.url,
            fullURL: fullURL,
            width: max(0, full?.width ?? still?.width ?? 0),
            height: max(0, full?.height ?? still?.height ?? 0),
            pageURL: nil,
            provider: name
        )
    }

    /// The first rendition with an https URL: sizes in order, each size's formats in order.
    private static func first(in sizes: [KlipySize?], formats: [String]) -> KlipyRendition? {
        for size in sizes.compactMap({ $0 }) {
            for format in formats {
                if let rendition = size[format], rendition.url != nil {
                    return rendition
                }
            }
        }
        return nil
    }
}

// MARK: - Lenient response model

/// `{ "result": true, "data": { "data": [...], "has_next": true } }`, or `{ "result": false, "errors": {...} }`.
struct KlipyResponse: Decodable {
    let result: Bool?
    fileprivate let items: [KlipyEntry]
    /// The refusal's message names the key ("The provided API key is invalid.").
    let mentionsKey: Bool

    private enum CodingKeys: String, CodingKey {
        case result, data, errors
    }

    private enum PageKeys: String, CodingKey {
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try? container.decodeIfPresent(Bool.self, forKey: .result)
        if let page = try? container.nestedContainer(keyedBy: PageKeys.self, forKey: .data),
           let entries = try? page.decode([LossyKlipyEntry].self, forKey: .data) {
            items = entries.compactMap { $0.value }
        } else if let entries = try? container.decode([LossyKlipyEntry].self, forKey: .data) {
            items = entries.compactMap { $0.value }
        } else {
            items = []
        }
        let errors = try? container.decodeIfPresent(KlipyErrors.self, forKey: .errors)
        mentionsKey = errors?.messages.contains { $0.lowercased().contains("key") } ?? false
    }
}

private struct KlipyErrors: Decodable {
    let messages: [String]

    private enum CodingKeys: String, CodingKey {
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([String].self, forKey: .message) {
            messages = list
        } else if let text = try? container.decode(String.self, forKey: .message) {
            messages = [text]
        } else {
            messages = []
        }
    }
}

/// Decodes one result without failing the whole array.
private struct LossyKlipyEntry: Decodable {
    let value: KlipyEntry?

    init(from decoder: Decoder) throws {
        value = try? KlipyEntry(from: decoder)
    }
}

/// One size's renditions by format ("gif", "webp", "jpg", "png", "mp4").
private typealias KlipySize = [String: KlipyRendition]

private struct KlipyEntry: Decodable {
    let id: String
    let title: String
    let type: String?
    /// Sizes ("hd", "md", "sm", "xs") to their renditions.
    let file: [String: KlipySize]

    private enum CodingKeys: String, CodingKey {
        case id, title, type, file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try container.decode(Int.self, forKey: .id))
        }
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        let sizes = (try? container.decodeIfPresent([String: [String: LossyKlipyRendition]].self, forKey: .file)) ?? [:]
        var file: [String: KlipySize] = [:]
        for (size, formats) in sizes {
            var renditions: KlipySize = [:]
            for (format, rendition) in formats {
                if let value = rendition.value { renditions[format] = value }
            }
            if !renditions.isEmpty { file[size] = renditions }
        }
        self.file = file
    }
}

/// Decodes one rendition (or skips a field that isn't one) without failing its size.
private struct LossyKlipyRendition: Decodable {
    let value: KlipyRendition?

    init(from decoder: Decoder) throws {
        value = try? KlipyRendition(from: decoder)
    }
}

private struct KlipyRendition: Decodable {
    /// Only an absolute https URL.
    let url: URL?
    let width: Int?
    let height: Int?

    private enum CodingKeys: String, CodingKey {
        case url, width, height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try? container.decodeIfPresent(String.self, forKey: .url)
        if let text, let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false {
            self.url = url
        } else {
            url = nil
        }
        width = KlipyRendition.lenientInt(in: container, forKey: .width)
        height = KlipyRendition.lenientInt(in: container, forKey: .height)
    }

    private static func lenientInt(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) {
            return number
        }
        if let number = try? container.decodeIfPresent(Double.self, forKey: key), number.isFinite {
            return Int(number)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
