import Foundation

/// latest.json, the update feed CI publishes next to MemeMe.dmg in every GitHub Release.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String                 // marketing version, "1.0"
    public var build: Int                      // CFBundleVersion of the release, ≥ 1
    public var downloadURL: URL                // the release's MemeMe.dmg (tag-specific URL, not /latest/)
    public var sha256: String                  // lowercase hex of the DMG (decode lowercases it)
    public var size: Int?                      // bytes of the DMG
    public var minimumSystemVersion: String?   // "14.0"
    public var notes: [String]                 // one line per change, newest first; [] when missing
    public var releasePageURL: URL?
    public var publishedAt: Date?              // ISO 8601

    public init(version: String, build: Int, downloadURL: URL, sha256: String, size: Int? = nil,
                minimumSystemVersion: String? = nil, notes: [String] = [], releasePageURL: URL? = nil, publishedAt: Date? = nil) {
        self.version = version
        self.build = build
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.size = size
        self.minimumSystemVersion = minimumSystemVersion
        self.notes = notes
        self.releasePageURL = releasePageURL
        self.publishedAt = publishedAt
    }

    /// "1.0 (58)"
    public var displayVersion: String {
        "\(version) (\(build))"
    }

    /// Decodes latest.json. Throws `.malformed` for bad JSON or wrong types, `.invalid(reason)` for an empty
    /// version, build < 1, a sha256 that isn't 64 hex characters, or a size < 1.
    public static func decode(from data: Data) throws -> UpdateManifest {
        do {
            return try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch let error as UpdateManifestError {
            throw error
        } catch {
            throw UpdateManifestError.malformed
        }
    }

    // MARK: Codable (URLs and publishedAt are plain strings, independent of the coder's strategies)

    private enum CodingKeys: String, CodingKey {
        case version, build, downloadURL, sha256, size, minimumSystemVersion, notes, releasePageURL, publishedAt
    }

    /// `version`, `build`, `downloadURL` and `sha256` are required; the other keys are nil or [] when missing or
    /// of the wrong type. Throws `UpdateManifestError.invalid` when a value is out of range.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(String.self, forKey: .version)
        let decodedBuild = try container.decode(Int.self, forKey: .build)
        let downloadString = try container.decode(String.self, forKey: .downloadURL)
        guard let decodedURL = URL(string: downloadString) else {
            throw DecodingError.dataCorruptedError(forKey: .downloadURL, in: container, debugDescription: "Not a URL")
        }
        let decodedSHA = try container.decode(String.self, forKey: .sha256)

        version = decodedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        build = decodedBuild
        downloadURL = decodedURL
        sha256 = decodedSHA.lowercased()
        size = container.decodeLenientIfPresent(Int.self, forKey: .size)
        let minimum = container.decodeLenientIfPresent(String.self, forKey: .minimumSystemVersion)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        minimumSystemVersion = (minimum?.isEmpty ?? true) ? nil : minimum
        notes = container.decodeLenient([String].self, forKey: .notes, default: [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        releasePageURL = container.decodeLenientIfPresent(String.self, forKey: .releasePageURL)
            .flatMap { URL(string: $0) }
        publishedAt = container.decodeLenientIfPresent(String.self, forKey: .publishedAt)
            .flatMap { UpdateManifest.date(fromISO8601: $0) }

        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(build, forKey: .build)
        try container.encode(downloadURL.absoluteString, forKey: .downloadURL)
        try container.encode(sha256, forKey: .sha256)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(minimumSystemVersion, forKey: .minimumSystemVersion)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(releasePageURL?.absoluteString, forKey: .releasePageURL)
        try container.encodeIfPresent(publishedAt.map { UpdateManifest.iso8601String(from: $0) }, forKey: .publishedAt)
    }

    private func validate() throws {
        if version.isEmpty { throw UpdateManifestError.invalid("empty version") }
        if build < 1 { throw UpdateManifestError.invalid("build must be at least 1") }
        if !UpdatePolicy.isValidSHA256(sha256) { throw UpdateManifestError.invalid("sha256 must be 64 hex characters") }
        if let size = size, size < 1 { throw UpdateManifestError.invalid("size must be at least 1") }
    }

    /// "2026-10-27T02:00:00Z", with or without fractional seconds; nil when unparseable.
    private static func date(fromISO8601 string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: trimmed)
    }

    /// Whole seconds unless the date has a fractional part.
    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        let seconds = date.timeIntervalSince1970
        if seconds == seconds.rounded() {
            formatter.formatOptions = [.withInternetDateTime]
        } else {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }
        return formatter.string(from: date)
    }
}

public enum UpdateManifestError: Error, Equatable, Sendable {
    case malformed
    case invalid(String)
}

public enum UpdateDecision: Equatable, Sendable {
    case upToDate
    case available(UpdateManifest)
    case requiresNewerSystem(UpdateManifest)   // newer build, but this macOS is older than its minimumSystemVersion
}

/// When to check, what to offer, and which downloads to trust.
public enum UpdatePolicy {
    public static let checkInterval: TimeInterval = 6 * 3600
    public static let firstCheckDelay: TimeInterval = 20
    /// After wake, check when the last check is older than this.
    public static let wakeCheckAge: TimeInterval = 3600

    /// `.upToDate` unless manifest.build > installedBuild; then `.requiresNewerSystem` when
    /// minimumSystemVersion is set and newer than `systemVersion`, else `.available`.
    public static func decide(installedBuild: Int, manifest: UpdateManifest, systemVersion: OperatingSystemVersion) -> UpdateDecision {
        guard manifest.build > installedBuild else { return .upToDate }
        if let minimum = manifest.minimumSystemVersion, !isSystem(systemVersion, atLeast: minimum) {
            return .requiresNewerSystem(manifest)
        }
        return .available(manifest)
    }

    /// Dotted numeric comparison ("14.0" < "14.2.1"); missing parts count as 0, non-numeric parts as 0.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericParts(lhs)
        let right = numericParts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func isSystem(_ system: OperatingSystemVersion, atLeast minimum: String) -> Bool {
        let current = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        return compareVersions(current, minimum) != .orderedAscending
    }

    /// HTTPS, no user/password, host exactly "github.com" or ending in ".githubusercontent.com" (case-insensitive).
    public static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Exactly 64 characters 0-9a-f (lowercase).
    public static func isValidSHA256(_ hex: String) -> Bool {
        guard hex.utf8.count == 64 else { return false }
        return hex.utf8.allSatisfy { lowercaseHexDigits.contains($0) }
    }

    /// The panel line shows unless this build was dismissed with "Not now".
    public static func shouldOfferInPanel(_ manifest: UpdateManifest, skippedBuild: Int?) -> Bool {
        skippedBuild != manifest.build
    }

    private static let lowercaseHexDigits = Set("0123456789abcdef".utf8)

    private static func numericParts(_ version: String) -> [Int] {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }
}
