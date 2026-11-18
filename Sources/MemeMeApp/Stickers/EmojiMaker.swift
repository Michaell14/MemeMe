import AppKit
import CoreGraphics
import Foundation
#if canImport(ImagePlayground)
import ImagePlayground
#endif
import os

private let emojiLog = Logger(subsystem: "com.mememe.app", category: "emoji")

/// Why no emoji came back, worded for the HUD.
enum EmojiMakerError: Error, Equatable {
    /// This Mac can't make images: macOS before 15.4, an Intel Mac, or a region without Apple Intelligence.
    case notSupported
    /// Apple Intelligence is off, or its image model is still downloading.
    case unavailable
    /// The words were refused (a person's name, a language it doesn't know, the guardrails).
    case refused
    /// Anything else: the model failed, or nothing could be cut out of what it made.
    case failed

    var message: String {
        switch self {
        case .notSupported: return "This Mac can’t make emoji (it needs Apple Intelligence)."
        case .unavailable: return "Turn on Apple Intelligence in System Settings to make emoji."
        case .refused: return "Image Playground won’t make that one. Try other words."
        case .failed: return "Couldn’t make that one. Try again."
        }
    }
}

/// Makes a picture from a few words with Apple's on-device image model, when there is one.
@MainActor protocol EmojiMaking: AnyObject {
    /// False once this Mac is known not to make images (macOS before 15.4, no Apple Intelligence). True until then,
    /// including before `prewarm` found out.
    var mayBeAvailable: Bool { get }
    /// Called when `mayBeAvailable` changes (`prewarm` or a picture found out), so the panel redraws its offers.
    var onAvailabilityChange: (() -> Void)? { get set }
    /// Finds out whether images can be made, ahead of the first one (cheap after the first call).
    func prewarm()
    /// One picture for `words`, its background left in.
    func image(for words: String) async throws -> CGImage
    /// Up to `count` pictures for `words`, each as soon as it is made (Make emoji's four options). Ends with an
    /// `EmojiMakerError` when none or only some could be made; cancelling the stream stops the model.
    func images(for words: String, count: Int) -> AsyncThrowingStream<CGImage, Error>
}

/// "Make emoji": a picture for a few words from Image Playground (`ImageCreator`, macOS 15.4, Apple Intelligence),
/// in its Animation style when it has it — the closest to an emoji's round, glossy look. Everything runs on this Mac;
/// the words never leave it.
///
/// Every ImagePlayground reference is behind `#if canImport(ImagePlayground)` and a macOS 15.4 availability check, so
/// the framework is weak-linked and the app still launches on macOS 14 (CI checks the link).
@MainActor final class EmojiMaker: EmojiMaking {
    /// The longest a picture may take before it counts as failed.
    static let timeout: TimeInterval = 60

    /// nil until `prewarm` or the first picture found out.
    private var supported: Bool? {
        didSet {
            if oldValue != supported { onAvailabilityChange?() }
        }
    }
    var onAvailabilityChange: (() -> Void)?
    /// The creator kept between pictures (an `ImageCreator`). Typed `Any` because a stored property can't be limited
    /// to macOS 15.4.
    private var creator: Any?
    private var probing: Task<Void, Never>?

    init() {}

    var mayBeAvailable: Bool {
        guard EmojiMaker.osSupports else { return false }
        return supported != false
    }

    /// Built with an SDK that has ImageCreator, running on macOS 15.4 or later.
    static var osSupports: Bool {
        #if canImport(ImagePlayground)
        if #available(macOS 15.4, *) { return true }
        #endif
        return false
    }

    func prewarm() {
        guard EmojiMaker.osSupports, supported == nil, probing == nil else { return }
        probing = Task {
            #if canImport(ImagePlayground)
            if #available(macOS 15.4, *) {
                _ = try? await self.readyCreator()
            }
            #endif
            self.probing = nil
        }
    }

    func image(for words: String) async throws -> CGImage {
        let concept = EmojiMaker.concept(for: words)
        guard !concept.isEmpty else { throw EmojiMakerError.refused }
        #if canImport(ImagePlayground)
        if #available(macOS 15.4, *) {
            do {
                return try await make(concept)
            } catch ImageCreator.Error.backgroundCreationForbidden {
                // MemeMe's panel doesn't activate the app, so the chat stays in front; Image Playground only makes
                // images for the app in front. Come forward and try once more (closing the panel gives the chat
                // its focus back).
                emojiLog.debug("Image Playground wants MemeMe in front; activating")
                NSApp.activate(ignoringOtherApps: true)
                return try await make(concept)
            }
        }
        #endif
        throw EmojiMakerError.notSupported
    }

    func images(for words: String, count: Int) -> AsyncThrowingStream<CGImage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let concept = EmojiMaker.concept(for: words)
                    guard !concept.isEmpty else { throw EmojiMakerError.refused }
                    #if canImport(ImagePlayground)
                    if #available(macOS 15.4, *) {
                        var made = 0
                        do {
                            try await self.stream(concept, count: count) { image in
                                made += 1
                                continuation.yield(image)
                            }
                        } catch ImageCreator.Error.backgroundCreationForbidden where made == 0 {
                            // As in `image(for:)`: come forward and ask once more.
                            NSApp.activate(ignoringOtherApps: true)
                            try await self.stream(concept, count: count) { continuation.yield($0) }
                        }
                        continuation.finish()
                        return
                    }
                    #endif
                    throw EmojiMakerError.notSupported
                } catch {
                    continuation.finish(throwing: (error as? EmojiMakerError) ?? EmojiMakerError.failed)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What Image Playground is asked for: the words, tidied (spaces folded, at most 60 characters).
    nonisolated static func concept(for words: String) -> String {
        let folded = words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(folded.prefix(60))
    }

    #if canImport(ImagePlayground)
    @available(macOS 15.4, *)
    private func readyCreator() async throws -> ImageCreator {
        if let kept = creator as? ImageCreator { return kept }
        do {
            let made = try await ImageCreator()
            creator = made
            supported = true
            return made
        } catch let error as ImageCreator.Error {
            throw mapped(error)
        } catch {
            throw EmojiMakerError.failed
        }
    }

    @available(macOS 15.4, *)
    private func make(_ concept: String) async throws -> CGImage {
        let creator = try await readyCreator()
        let styles = creator.availableStyles
        let preferred: ImagePlaygroundStyle? = styles.contains(.animation) ? .animation : styles.first
        guard let style = preferred else {
            supported = false
            throw EmojiMakerError.notSupported
        }
        let work = Task<CGImage?, Error> {
            for try await created in creator.images(for: [.text(concept)], style: style, limit: 1) {
                return created.cgImage
            }
            return nil
        }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(EmojiMaker.timeout * 1_000_000_000))
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            guard let image = try await work.value else { throw EmojiMakerError.failed }
            return image
        } catch let error as ImageCreator.Error {
            // Passed on as it is: `image(for:)` comes forward and tries again.
            if case .backgroundCreationForbidden = error { throw error }
            throw mapped(error)
        } catch let error as EmojiMakerError {
            throw error
        } catch {
            emojiLog.error("Image Playground failed: \(error.localizedDescription, privacy: .public)")
            throw EmojiMakerError.failed
        }
    }

    /// Up to `count` pictures of `concept`, each handed to `onImage` as it comes.
    @available(macOS 15.4, *)
    private func stream(_ concept: String, count: Int, onImage: (CGImage) -> Void) async throws {
        let creator = try await readyCreator()
        let styles = creator.availableStyles
        let preferred: ImagePlaygroundStyle? = styles.contains(.animation) ? .animation : styles.first
        guard let style = preferred else {
            supported = false
            throw EmojiMakerError.notSupported
        }
        do {
            for try await created in creator.images(for: [.text(concept)], style: style, limit: count) {
                onImage(created.cgImage)
            }
        } catch let error as ImageCreator.Error {
            if case .backgroundCreationForbidden = error { throw error }
            throw mapped(error)
        } catch let error as EmojiMakerError {
            throw error
        } catch {
            emojiLog.error("Image Playground failed: \(error.localizedDescription, privacy: .public)")
            throw EmojiMakerError.failed
        }
    }

    @available(macOS 15.4, *)
    private func mapped(_ error: ImageCreator.Error) -> EmojiMakerError {
        emojiLog.debug("Image Playground: \(String(describing: error), privacy: .public)")
        switch error {
        case .notSupported:
            supported = false
            return .notSupported
        case .unavailable:
            // Apple Intelligence off or still downloading: ask again next time.
            creator = nil
            return .unavailable
        case .unsupportedLanguage, .conceptsRequirePersonIdentity:
            return .refused
        default:
            return .failed
        }
    }
    #endif
}

extension EmojiMaker {
    /// A die-cut sticker of what Image Playground made: its subjects lifted off the background
    /// (`VNGenerateForegroundInstanceMaskRequest`, as the screen cut does), a white outline, at most 512 px, as PNG
    /// data; the whole picture when nothing stands out. Heavy: never on the main thread.
    nonisolated static func stickerPNG(from image: CGImage) throws -> Data {
        let subjects = ScreenSubjects(image: image)
        let piece: ScreenPiece
        if subjects.instanceCount > 0 {
            piece = try subjects.piece(forInstances: IndexSet(integersIn: 1...subjects.instanceCount))
        } else {
            piece = try subjects.piece(inBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return try ScreenSubjects.stickerPNG(of: piece)
    }
}
