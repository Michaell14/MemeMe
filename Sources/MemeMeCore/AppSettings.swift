import Foundation

/// User preferences and small bits of app state, persisted as settings.json.
public struct AppSettings: Codable, Equatable, Sendable {
    public var hotKeyKeyCode: UInt32 = 46               // kVK_ANSI_M
    public var hotKeyModifiers: UInt32 = 4352           // Carbon controlKey (4096) | cmdKey (256)
    public var openAtLogin: Bool = true
    public var stickerPolicy: StickerPolicy = .automatic
    public var groupFaces: Bool? = nil                  // nil = not asked yet
    public var watchedFolders: [String] = []            // standardized paths
    public var collectingPausedUntil: Date? = nil
    public var webDiscoverEnabled: Bool = true
    public var giphyAPIKey: String? = nil               // overrides Info.plist GiphyAPIKey
    public var hasCompletedFirstRun: Bool = false
    public var libraryOfferDismissals: Int = 0
    public var libraryOfferAccepted: Bool = false
    public var baseline: RestingBaseline = RestingBaseline()

    public init() {}

    // MARK: Codable (every key optional; missing or malformed keys keep their defaults)

    private enum CodingKeys: String, CodingKey {
        case hotKeyKeyCode, hotKeyModifiers, openAtLogin, stickerPolicy, groupFaces, watchedFolders, collectingPausedUntil
        case webDiscoverEnabled, giphyAPIKey, hasCompletedFirstRun, libraryOfferDismissals, libraryOfferAccepted, baseline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        hotKeyKeyCode = container.decodeLenient(UInt32.self, forKey: .hotKeyKeyCode, default: defaults.hotKeyKeyCode)
        hotKeyModifiers = container.decodeLenient(UInt32.self, forKey: .hotKeyModifiers, default: defaults.hotKeyModifiers)
        openAtLogin = container.decodeLenient(Bool.self, forKey: .openAtLogin, default: defaults.openAtLogin)
        stickerPolicy = container.decodeLenient(StickerPolicy.self, forKey: .stickerPolicy, default: defaults.stickerPolicy)
        groupFaces = container.decodeLenientIfPresent(Bool.self, forKey: .groupFaces)
        watchedFolders = container.decodeLenient([String].self, forKey: .watchedFolders, default: defaults.watchedFolders)
        collectingPausedUntil = container.decodeLenientIfPresent(Date.self, forKey: .collectingPausedUntil)
        webDiscoverEnabled = container.decodeLenient(Bool.self, forKey: .webDiscoverEnabled, default: defaults.webDiscoverEnabled)
        giphyAPIKey = container.decodeLenientIfPresent(String.self, forKey: .giphyAPIKey)
        hasCompletedFirstRun = container.decodeLenient(Bool.self, forKey: .hasCompletedFirstRun, default: defaults.hasCompletedFirstRun)
        libraryOfferDismissals = container.decodeLenient(Int.self, forKey: .libraryOfferDismissals, default: defaults.libraryOfferDismissals)
        libraryOfferAccepted = container.decodeLenient(Bool.self, forKey: .libraryOfferAccepted, default: defaults.libraryOfferAccepted)
        baseline = container.decodeLenient(RestingBaseline.self, forKey: .baseline, default: defaults.baseline)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hotKeyKeyCode, forKey: .hotKeyKeyCode)
        try container.encode(hotKeyModifiers, forKey: .hotKeyModifiers)
        try container.encode(openAtLogin, forKey: .openAtLogin)
        try container.encode(stickerPolicy, forKey: .stickerPolicy)
        try container.encodeIfPresent(groupFaces, forKey: .groupFaces)
        try container.encode(watchedFolders, forKey: .watchedFolders)
        try container.encodeIfPresent(collectingPausedUntil, forKey: .collectingPausedUntil)
        try container.encode(webDiscoverEnabled, forKey: .webDiscoverEnabled)
        try container.encodeIfPresent(giphyAPIKey, forKey: .giphyAPIKey)
        try container.encode(hasCompletedFirstRun, forKey: .hasCompletedFirstRun)
        try container.encode(libraryOfferDismissals, forKey: .libraryOfferDismissals)
        try container.encode(libraryOfferAccepted, forKey: .libraryOfferAccepted)
        try container.encode(baseline, forKey: .baseline)
    }
}
