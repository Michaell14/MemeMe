import Foundation

/// Decides when the mood of an expression that is still being held is clear enough to start its web
/// search, so results are ready by the time the hold completes (0.3 s; for a new expression 0.6 s, or
/// 1 s with a gesture, unless the face relaxed in between).
///
/// A mood counts as clear once every frame for `settleTime` reads the same; it fires once per streak.
/// Frames with no expression being held (`nil`) end the streak.
public struct EarlyMoodTrigger: Sendable {
    public var settleTime: TimeInterval

    private var mood: Mood?
    private var since: TimeInterval = 0
    private var fired = false

    public init(settleTime: TimeInterval = 0.2) {
        self.settleTime = settleTime
    }

    /// Feed the candidate's mood for every frame. Returns the mood the moment it becomes clear, else nil.
    public mutating func observe(_ candidateMood: Mood?, at timestamp: TimeInterval) -> Mood? {
        guard let candidateMood, candidateMood != .reaction else {
            reset()
            return nil
        }
        if candidateMood != mood {
            mood = candidateMood
            since = timestamp
            fired = false
        }
        guard !fired, timestamp - since >= settleTime - 1e-9 else { return nil }
        fired = true
        return candidateMood
    }

    public mutating func reset() {
        mood = nil
        fired = false
    }
}
