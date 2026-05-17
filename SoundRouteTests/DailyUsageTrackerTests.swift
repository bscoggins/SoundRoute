import XCTest
@testable import SoundRoute

/// Tests for the daily-budget tracker that drives SoundRoute's free
/// tier. Uses an isolated `UserDefaults` suite and an injected date
/// provider so each test is hermetic — no cross-test pollution, no
/// waiting for actual midnight.
final class DailyUsageTrackerTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "DailyUsageTrackerTests.\(UUID().uuidString)"

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: - Initial state

    func testFreshInstanceHasZeroUsage() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        XCTAssertEqual(tracker.secondsUsedToday, 0)
        XCTAssertEqual(tracker.remainingSecondsToday, DailyUsageTracker.dailyLimitSeconds)
        XCTAssertFalse(tracker.isLimitReached)
    }

    func testDailyLimitConstantIs30Minutes() {
        // Locks the published daily cap. If this changes, the App Review
        // Information note and listing copy must follow.
        XCTAssertEqual(DailyUsageTracker.dailyLimitSeconds, 30 * 60)
    }

    // MARK: - Tick path (production)

    func testTickIncrementsByOneSecond() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.tick()
        XCTAssertEqual(tracker.secondsUsedToday, 1)
        tracker.tick()
        tracker.tick()
        XCTAssertEqual(tracker.secondsUsedToday, 3)
    }

    func testTickPersistsAfterEachIncrement() {
        let first = DailyUsageTracker(userDefaults: defaults)
        for _ in 0..<5 { first.tick() }

        // A fresh instance picks up the same count from disk.
        let second = DailyUsageTracker(userDefaults: defaults)
        XCTAssertEqual(second.secondsUsedToday, 5)
    }

    // MARK: - Bulk record (test convenience)

    func testRecordUsageAccumulates() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: 60)
        XCTAssertEqual(tracker.secondsUsedToday, 60)
        tracker.recordUsage(seconds: 90)
        XCTAssertEqual(tracker.secondsUsedToday, 150)
    }

    func testRecordUsageCapsAtDailyLimit() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: 25 * 60)
        tracker.recordUsage(seconds: 10 * 60) // would overshoot to 35 min
        XCTAssertEqual(tracker.secondsUsedToday, DailyUsageTracker.dailyLimitSeconds)
        XCTAssertTrue(tracker.isLimitReached)
        XCTAssertEqual(tracker.remainingSecondsToday, 0)
    }

    func testRecordUsageIgnoresZeroAndNegative() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: 0)
        tracker.recordUsage(seconds: -100)
        XCTAssertEqual(tracker.secondsUsedToday, 0)
    }

    // MARK: - start / stop and the limit callback

    func testStartFiresLimitCallbackImmediatelyWhenAlreadyExhausted() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: DailyUsageTracker.dailyLimitSeconds)
        var fired = false
        tracker.start { fired = true }
        XCTAssertTrue(fired, "start() with budget already at zero must fire callback synchronously")
    }

    func testStartDoesNotFireCallbackWhenBudgetRemains() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.start { XCTFail("Callback should not fire while budget remains") }
        tracker.stop()
    }

    func testTickFiresCallbackExactlyOnceWhenLimitReached() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        // Prime the counter so a single tick crosses the boundary.
        tracker.recordUsage(seconds: DailyUsageTracker.dailyLimitSeconds - 1)

        var callCount = 0
        tracker.start { callCount += 1 }
        tracker.tick() // crosses to limit, fires callback, self-stops

        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(tracker.isLimitReached)

        // Subsequent ticks must not re-fire — tracker self-stopped on first.
        tracker.tick()
        tracker.tick()
        XCTAssertEqual(callCount, 1)
    }

    func testStopPreventsCallback() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: DailyUsageTracker.dailyLimitSeconds - 1)
        tracker.start { XCTFail("Callback should not fire after stop") }
        tracker.stop()
        tracker.tick() // would cross the limit if running, but tracker was stopped
    }

    func testStopIsIdempotent() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.stop()
        tracker.stop()
        XCTAssertEqual(tracker.secondsUsedToday, 0)
    }

    // MARK: - Persistence + midnight rollover

    func testUsagePersistsAcrossInstancesSameDay() {
        var today = Date()
        let providerToday: () -> Date = { today }

        let first = DailyUsageTracker(userDefaults: defaults, dateProvider: providerToday)
        first.recordUsage(seconds: 300)
        XCTAssertEqual(first.secondsUsedToday, 300)

        let second = DailyUsageTracker(userDefaults: defaults, dateProvider: providerToday)
        XCTAssertEqual(second.secondsUsedToday, 300)
    }

    func testCounterResetsOnNextCalendarDay() {
        var clock = Date()
        let tracker = DailyUsageTracker(userDefaults: defaults) { clock }
        tracker.recordUsage(seconds: 500)
        XCTAssertEqual(tracker.secondsUsedToday, 500)

        // Advance 25 hours — guarantees a calendar-day boundary regardless
        // of where in the day we started.
        clock = clock.addingTimeInterval(25 * 60 * 60)

        tracker.recordUsage(seconds: 60)
        XCTAssertEqual(
            tracker.secondsUsedToday, 60,
            "Crossing midnight should zero the counter before accumulating the new value"
        )
    }

    func testRolloverPersistsResetAcrossInstances() {
        var clock = Date()
        let first = DailyUsageTracker(userDefaults: defaults) { clock }
        first.recordUsage(seconds: 800)

        clock = clock.addingTimeInterval(25 * 60 * 60)

        // A fresh instance after the day boundary sees zero usage, not
        // the persisted value from yesterday.
        let second = DailyUsageTracker(userDefaults: defaults) { clock }
        XCTAssertEqual(second.secondsUsedToday, 0)
        XCTAssertEqual(second.remainingSecondsToday, DailyUsageTracker.dailyLimitSeconds)
    }

    // MARK: - Limit detection

    func testIsLimitReachedFlipsAtCap() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: DailyUsageTracker.dailyLimitSeconds - 1)
        XCTAssertFalse(tracker.isLimitReached)
        tracker.recordUsage(seconds: 1)
        XCTAssertTrue(tracker.isLimitReached)
    }
}
