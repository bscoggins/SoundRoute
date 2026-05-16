import XCTest
import CoreAudio
import AVFoundation
@testable import SoundRoute

/// Lifecycle smoke tests for the two-AudioUnit routing engine.
///
/// The first three tests run without any permission. The last two exercise
/// real audio routing and require microphone access — they auto-skip via
/// `XCTSkipUnless` when the test runner isn't authorized, so they're honest
/// about what they need instead of hanging on a permission prompt.
final class AudioManagerSmokeTests: XCTestCase {

    // MARK: - No-permission tests

    func testInitialStateIsNotRunning() {
        let manager = AudioManager()
        XCTAssertFalse(manager.isRunning)
        XCTAssertNil(manager.errorMessage)
    }

    func testStopOnFreshInstanceIsNoOp() {
        let manager = AudioManager()
        manager.stop()
        manager.stop()
        XCTAssertFalse(manager.isRunning)
    }

    func testStartWithoutDeviceSelectionReportsError() {
        let manager = AudioManager()
        manager.start()
        XCTAssertFalse(manager.isRunning)
        XCTAssertNotNil(manager.errorMessage)
    }

    // MARK: - Permission-gated tests

    func testStartStopLifecycleWithRealDevices() throws {
        try requireMicrophoneAccess()
        let (input, output) = try requireDefaultDevices()

        let manager = AudioManager()
        manager.setInputDevice(input)
        manager.setOutputDevice(output)
        manager.start()

        XCTAssertTrue(
            manager.isRunning,
            "Failed to start audio routing: \(manager.errorMessage ?? "unknown error")"
        )

        manager.stop()
        XCTAssertFalse(manager.isRunning)
    }

    func testStartStopAcrossMultipleCyclesDoesNotLeak() throws {
        try requireMicrophoneAccess()
        let (input, output) = try requireDefaultDevices()

        let manager = AudioManager()
        manager.setInputDevice(input)
        manager.setOutputDevice(output)

        for cycle in 0..<3 {
            manager.start()
            XCTAssertTrue(
                manager.isRunning,
                "Cycle \(cycle): start failed (\(manager.errorMessage ?? "unknown"))"
            )
            manager.stop()
            XCTAssertFalse(manager.isRunning, "Cycle \(cycle): stop did not clear state")
        }
    }

    // MARK: - Helpers

    private func requireMicrophoneAccess() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        try XCTSkipUnless(
            status == .authorized,
            "Skipping — test runner lacks microphone permission. Grant it in " +
            "System Settings → Privacy & Security → Microphone, then re-run."
        )
    }

    private func requireDefaultDevices() throws -> (AudioDeviceID, AudioDeviceID) {
        let deviceManager = AudioDeviceManager()
        guard let input = deviceManager.getDefaultInputDevice(),
              let output = deviceManager.getDefaultOutputDevice() else {
            throw XCTSkip("No default input/output device available on this machine")
        }
        return (input, output)
    }
}
