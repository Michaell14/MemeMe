import Foundation
import XCTest
@testable import MemeMeCore

final class EarlyMoodTriggerTests: XCTestCase {
    func testFiresOnceTheMoodHasHeldForTheSettleTime() {
        var trigger = EarlyMoodTrigger()
        XCTAssertNil(trigger.observe(.shocked, at: 0.0))
        XCTAssertNil(trigger.observe(.shocked, at: 0.1))
        XCTAssertEqual(trigger.observe(.shocked, at: 0.2), .shocked)
        // Once per streak.
        XCTAssertNil(trigger.observe(.shocked, at: 0.3))
        XCTAssertNil(trigger.observe(.shocked, at: 0.4))
    }

    func testAChangedMoodRestartsTheClock() {
        var trigger = EarlyMoodTrigger()
        XCTAssertNil(trigger.observe(.happy, at: 0.0))
        XCTAssertNil(trigger.observe(.happy, at: 0.1))
        XCTAssertNil(trigger.observe(.laughing, at: 0.15))
        XCTAssertNil(trigger.observe(.laughing, at: 0.3))
        XCTAssertEqual(trigger.observe(.laughing, at: 0.35), .laughing)
    }

    func testNoCandidateEndsTheStreakAndAReturningMoodFiresAgain() {
        var trigger = EarlyMoodTrigger()
        _ = trigger.observe(.smug, at: 0.0)
        XCTAssertEqual(trigger.observe(.smug, at: 0.2), .smug)
        XCTAssertNil(trigger.observe(nil, at: 0.3))
        XCTAssertNil(trigger.observe(.smug, at: 0.4))
        XCTAssertEqual(trigger.observe(.smug, at: 0.6), .smug)
    }

    func testReactionNeverFires() {
        var trigger = EarlyMoodTrigger()
        for step in 0...10 {
            XCTAssertNil(trigger.observe(.reaction, at: Double(step) / 10))
        }
    }

    func testResetForgetsTheStreak() {
        var trigger = EarlyMoodTrigger(settleTime: 0.1)
        _ = trigger.observe(.angry, at: 0.0)
        trigger.reset()
        XCTAssertNil(trigger.observe(.angry, at: 0.05))
        XCTAssertEqual(trigger.observe(.angry, at: 0.15), .angry)
    }
}
