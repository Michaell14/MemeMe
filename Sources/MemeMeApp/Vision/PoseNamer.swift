import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import MemeMeCore
import os

private let namerLog = Logger(subsystem: "com.mememe.app", category: "namer")

/// Names a described pose in a few GIF-tag words with the on-device model, when there is one.
@MainActor protocol PoseNaming: AnyObject {
    /// True when a name can be asked for now (macOS 26+, Apple silicon, Apple Intelligence on and the model ready).
    var isAvailable: Bool { get }
    /// The answer kept for this description: nil when it was never asked, `.some(nil)` when it was and the model had
    /// no name.
    func cachedName(for description: PoseDescription) -> String??
    /// Loads the model ahead of the first question (cheap no-op when unavailable).
    func prewarm()
    /// The model's name, cleaned by `PoseDescription.cleanName`; nil when unavailable, refused, failed or slower than
    /// `PoseNamer.timeout`. Answers (including nil) are cached by `description.key` (at most 64, oldest dropped); a
    /// second call for a key being asked joins the first.
    func name(_ description: PoseDescription) async -> String?
}

/// Names a described pose with Apple's on-device language model (FoundationModels, macOS 26, text only): the facts of
/// a `PoseDescription` go in ("One arm: at head height, bent sharply, …"), 1–3 GIF-tag words come out ("flexing",
/// "rock on"). The model runs on the Mac; only the name it gives may go on to GIPHY, never the facts.
///
/// Without the model (macOS 14 and 15, Intel Macs, Apple Intelligence off or still downloading) `isAvailable` is false
/// and `name` answers nil at once, so the rule-made phrase stands. Every FoundationModels reference is behind
/// `#if canImport(FoundationModels)` and a macOS 26 availability check, so the framework is weak-linked and the app
/// still launches where it doesn't exist (CI checks the link).
///
/// Greedy sampling and the cache by `description.key` keep the name the same for the same pose, so a pose caught again
/// searches GIPHY for the same words (and finds them in its cache instead of spending a search). Each question gets
/// a new session, as a session keeps its transcript and earlier answers would sway the next; one is kept prewarmed for
/// the next question.
@MainActor final class PoseNamer: PoseNaming {
    /// How long a search waits for a name before it uses the rule's phrase. A later answer is dropped, and that pose
    /// keeps the rule's phrase while its answer (nil) is cached.
    static let timeout: TimeInterval = 2.0
    /// Answers kept, the oldest dropped first.
    static let cacheLimit = 64
    /// Room for a few words: the model stops there, and `cleanName` keeps at most three of them.
    static let maximumResponseTokens = 16
    /// What the model is for. The examples are the kind of words GIPHY tags its GIFs with.
    static let instructions: String = "You name what a person on a webcam is doing, from a description of their arms, "
        + "hands, body and face. Answer with 1 to 3 lowercase words that people would type to find a reaction GIF of "
        + "it — the action or gesture, not the person (for example: flexing, rock on, thinking, salute, shh, finger "
        + "guns, hang loose, fist pump, waving, stretching, praying, mind blown). "
        + "No sentences, no punctuation, no names."
    /// Asked after the facts.
    static let question = "What are they doing?"

    /// Answers by `PoseDescription.key`; nil values are questions the model had no name for.
    private var answers: [String: String?] = [:]
    /// The keys of `answers`, oldest first.
    private var answerOrder: [String] = []
    /// Questions being asked, by key, so a second ask for the same pose joins the first.
    private var asking: [String: Task<String?, Never>] = [:]
    /// The session kept for the next question (a FoundationModels `LanguageModelSession`). Typed `Any` because a stored
    /// property can't be limited to macOS 26, and no FoundationModels type may appear outside the availability checks.
    private var spareSession: Any?

    init() {}

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    func cachedName(for description: PoseDescription) -> String?? {
        answers[description.key]
    }

    func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return }
            nextSession().prewarm()
        }
        #endif
    }

    func name(_ description: PoseDescription) async -> String? {
        let key = description.key
        if let answer = answers[key] {
            return answer
        }
        if let running = asking[key] {
            return await running.value
        }
        guard isAvailable else {
            remember(nil, for: key)
            return nil
        }
        // The task, not the caller, keeps the answer: a caller that stops waiting doesn't lose it for the next one.
        let task = Task<String?, Never> {
            let answer = await self.ask(description)
            self.asking[key] = nil
            self.remember(answer, for: key)
            return answer
        }
        asking[key] = task
        return await task.value
    }

    /// What the model is asked: the facts, one per line, then "What are they doing?".
    static func prompt(for description: PoseDescription) -> String {
        (description.facts + [PoseNamer.question]).joined(separator: "\n")
    }

    /// Keeps an answer (nil too), dropping the oldest beyond `cacheLimit`.
    private func remember(_ answer: String?, for key: String) {
        if answers.index(forKey: key) == nil {
            answerOrder.append(key)
        }
        answers[key] = .some(answer)
        while answerOrder.count > PoseNamer.cacheLimit {
            let oldest = answerOrder.removeFirst()
            answers.removeValue(forKey: oldest)
        }
    }

    /// One question to the model, at most `timeout` long: its answer cleaned by `PoseDescription.cleanName`, or nil.
    private func ask(_ description: PoseDescription) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let prompt = PoseNamer.prompt(for: description)
            let reply = Task<String?, Never> {
                await self.respond(to: prompt)
            }
            let answer = await WebRace.value(of: reply, timeout: PoseNamer.timeout)
            // Too late is no answer: stop the model working on it.
            reply.cancel()
            // A fresh session for the next question, loaded while this pose is shown.
            nextSession().prewarm()
            return answer.flatMap { PoseDescription.cleanName($0) }
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    /// The session kept for the next question, made when there is none.
    @available(macOS 26.0, *)
    private func nextSession() -> LanguageModelSession {
        if let session = spareSession as? LanguageModelSession {
            return session
        }
        let session = LanguageModelSession(instructions: PoseNamer.instructions)
        spareSession = session
        return session
    }

    /// The model's raw answer on the spare session, which this question uses up. nil on any error: the guardrails, a
    /// rate limit, the model going away, an unsupported language, or cancellation.
    @available(macOS 26.0, *)
    private func respond(to prompt: String) async -> String? {
        let session = nextSession()
        spareSession = nil
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: PoseNamer.maximumResponseTokens)
        do {
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        } catch {
            namerLog.debug("No name from the on-device model: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    #endif
}
