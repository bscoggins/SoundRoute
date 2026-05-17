import XCTest
import CoreAudio
import AVFoundation
@testable import SoundRoute

/// Integration tests for the AudioManager + DailyUsageTracker + unlock
/// snapshot wiring in v1.1. Most tests require microphone permission
/// since they exercise real audio routing; auto-skip via `XCTSkipUnless`
/// when unauthorized.
final class AudioManagerDailyLimitTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "AudioManagerDailyLimitTests.\(UUID().uuidString)"

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    // MARK: - No-permission tests

    func testHandleUnlockStateChangeIsSafeWithoutTracker() {
        let manager = AudioManager()
        manager.handleUnlockStateChange(unlocked: true)
        manager.handleUnlockStateChange(unlocked: false)
    }

    func testDailyLimitReachedFlagDefaultsFalse() {
        let manager = AudioManager()
        XCTAssertFalse(manager.dailyLimitReached)
    }

    func testUnlockClearsStaleDailyLimitErrorMessage() {
        // After hitting the daily limit, the user purchases via the
        // paywall. The unlock event must clear the stale "free routing
        // time used up" error message and the dailyLimitReached flag —
        // otherwise the red error persists in the UI until the user
        // clicks Start again. Caught in v1.1 smoke testing.
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: DailyUsageTracker.dailyLimitSeconds)

        let manager = AudioManager()
        manager.dailyUsageTracker = tracker
        manager.handleUnlockStateChange(unlocked: false)
        manager.setInputDevice(1) // dummy IDs — start hits the limit gate first
        manager.setOutputDevice(2)
        manager.start()

        XCTAssertTrue(manager.dailyLimitReached, "Precondition: limit hit")
        XCTAssertNotNil(manager.errorMessage, "Precondition: error message set")

        // User completes purchase — view layer fires this on the unlock.
        manager.handleUnlockStateChange(unlocked: true)

        XCTAssertFalse(manager.dailyLimitReached, "Unlock must clear stale daily-limit flag")
        XCTAssertNil(manager.errorMessage, "Unlock must clear stale daily-limit error message")
    }

    func testStartIsBlockedWhenDailyLimitReached() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: DailyUsageTracker.dailyLimitSeconds)

        let manager = AudioManager()
        manager.dailyUsageTracker = tracker
        manager.handleUnlockStateChange(unlocked: false)
        manager.setInputDevice(1) // dummy IDs — start() returns before touching audio
        manager.setOutputDevice(2)

        manager.start()

        XCTAssertFalse(manager.isRunning, "Start must not begin routing when daily budget is exhausted")
        XCTAssertTrue(manager.dailyLimitReached, "View needs the flag to auto-present the paywall")
        XCTAssertNotNil(manager.errorMessage)
    }

    func testUnlockedUserBypassesDailyLimitGate() {
        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: DailyUsageTracker.dailyLimitSeconds)

        let manager = AudioManager()
        manager.dailyUsageTracker = tracker
        manager.handleUnlockStateChange(unlocked: true)
        // No devices set, so start() should fail at the device-check stage
        // — but critically, NOT at the daily-limit gate.
        manager.start()

        XCTAssertFalse(manager.dailyLimitReached, "Unlocked users should not trip the daily-limit flag")
    }

    // MARK: - Permission-gated integration tests

    func testFreeUserDailyTrackerStartsOnRouting() throws {
        try requireMicrophone()
        let (input, output) = try requireDefaultDevices()

        let tracker = DailyUsageTracker(userDefaults: defaults)
        let manager = AudioManager()
        manager.dailyUsageTracker = tracker
        manager.handleUnlockStateChange(unlocked: false)
        manager.setInputDevice(input)
        manager.setOutputDevice(output)

        manager.start()
        XCTAssertTrue(
            manager.isRunning,
            "Failed to start: \(manager.errorMessage ?? "unknown")"
        )

        manager.stop()
    }

    func testStopCleansUpDailyTracker() throws {
        try requireMicrophone()
        let (input, output) = try requireDefaultDevices()

        let tracker = DailyUsageTracker(userDefaults: defaults)
        let manager = AudioManager()
        manager.dailyUsageTracker = tracker
        manager.handleUnlockStateChange(unlocked: false)
        manager.setInputDevice(input)
        manager.setOutputDevice(output)

        manager.start()
        XCTAssertTrue(manager.isRunning)
        manager.stop()
        XCTAssertFalse(manager.isRunning)
        // Subsequent calls to stop should remain no-ops.
        manager.stop()
        XCTAssertFalse(manager.isRunning)
    }

    func testUnlockingMidSessionPreservesRouting() throws {
        try requireMicrophone()
        let (input, output) = try requireDefaultDevices()

        let tracker = DailyUsageTracker(userDefaults: defaults)
        let manager = AudioManager()
        manager.dailyUsageTracker = tracker
        manager.handleUnlockStateChange(unlocked: false)
        manager.setInputDevice(input)
        manager.setOutputDevice(output)

        manager.start()
        XCTAssertTrue(manager.isRunning)

        // Simulate the user purchasing mid-session — what ContentView
        // does when StoreManager.isUnlocked flips to true.
        manager.handleUnlockStateChange(unlocked: true)
        XCTAssertTrue(manager.isRunning, "Routing must continue uninterrupted on unlock")

        manager.stop()
    }

    func testRefundMidSessionWithBudgetRemainingKeepsRouting() throws {
        try requireMicrophone()
        let (input, output) = try requireDefaultDevices()

        let tracker = DailyUsageTracker(userDefaults: defaults)
        let manager = AudioManager()
        manager.dailyUsageTracker = tracker
        // User starts session already unlocked (purchased earlier).
        manager.handleUnlockStateChange(unlocked: true)
        manager.setInputDevice(input)
        manager.setOutputDevice(output)

        manager.start()
        XCTAssertTrue(manager.isRunning)

        // Refund hits mid-session. Routing should continue because there
        // is still free-tier budget available, but the tracker must now
        // be engaged so future seconds count against the daily cap.
        manager.handleUnlockStateChange(unlocked: false)
        XCTAssertTrue(
            manager.isRunning,
            "Routing must continue when there is still free-tier budget"
        )
        XCTAssertFalse(
            manager.dailyLimitReached,
            "Daily limit must not be marked reached with budget remaining"
        )

        manager.stop()
    }

    func testRefundMidSessionWithExhaustedBudgetStopsRouting() throws {
        // Worst case: user was routing under an unlock, refund hits, and
        // they have zero free-tier seconds left today. Routing must
        // terminate cleanly and the paywall flag must flip so the view
        // can re-present the paywall on the next snapshot change.
        try requireMicrophone()
        let (input, output) = try requireDefaultDevices()

        let tracker = DailyUsageTracker(userDefaults: defaults)
        tracker.recordUsage(seconds: DailyUsageTracker.dailyLimitSeconds)

        let manager = AudioManager()
        manager.dailyUsageTracker = tracker
        // Start unlocked — bypasses the daily-limit gate even though
        // the tracker is already at the cap.
        manager.handleUnlockStateChange(unlocked: true)
        manager.setInputDevice(input)
        manager.setOutputDevice(output)
        manager.start()
        XCTAssertTrue(manager.isRunning, "Unlocked start must succeed regardless of tracker state")
        XCTAssertFalse(manager.dailyLimitReached)

        // Refund hits. handleUnlockStateChange re-engages the tracker,
        // which fires its limit callback immediately because the cap is
        // already exhausted.
        manager.handleUnlockStateChange(unlocked: false)

        XCTAssertFalse(manager.isRunning, "Routing must stop when budget is exhausted at refund time")
        XCTAssertTrue(manager.dailyLimitReached, "Paywall flag must flip on exhausted-refund")
    }

    // MARK: - Helpers

    private func requireMicrophone() throws {
        try XCTSkipUnless(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "Requires microphone permission for the test runner"
        )
    }

    private func requireDefaultDevices() throws -> (AudioDeviceID, AudioDeviceID) {
        let deviceManager = AudioDeviceManager()
        guard let input = deviceManager.getDefaultInputDevice(),
              let output = deviceManager.getDefaultOutputDevice() else {
            throw XCTSkip("No default audio devices available")
        }
        return (input, output)
    }
}
