import XCTest
import CoreAudio
import AVFoundation
@testable import SoundRoute

/// Tier 3 audio-integrity tests. Run a known sine wave through the
/// full SoundRoute routing pipeline via BlackHole virtual loopback
/// devices and verify the captured signal matches what was sent.
///
/// Topology:
/// ```
/// [SineWaveGenerator] → BlackHole 2ch (out)
///                                ↓  (loops back through the virtual device)
///                       BlackHole 2ch (in)
///                                ↓
///                       [SoundRoute AudioManager]
///                                ↓
///                       BlackHole 16ch (out)
///                                ↓  (loops back)
///                       BlackHole 16ch (in)
///                                ↓
///                       [AudioCapturer] → analyzer
/// ```
///
/// Prerequisites on the dev machine:
/// ```
/// brew install --cask blackhole-2ch blackhole-16ch
/// ```
///
/// Tests auto-skip when BlackHole devices aren't detected. Microphone
/// permission is also required because the AudioCapturer reads from
/// an input device.
final class AudioIntegrityTests: XCTestCase {

    private static let blackHole2chName = "BlackHole 2ch"
    private static let blackHole16chName = "BlackHole 16ch"
    private static let sampleRate: Double = 48000

    private var blackHole2chInputID: AudioDeviceID = 0
    private var blackHole16chOutputID: AudioDeviceID = 0
    private var blackHole16chInputID: AudioDeviceID = 0

    override func setUpWithError() throws {
        // Microphone permission is required by the AudioCapturer.
        try XCTSkipUnless(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "Tier 3 tests require microphone permission for the test runner"
        )

        let manager = AudioDeviceManager()
        guard let inputBH2 = manager.inputDevices.first(where: { $0.name.contains(Self.blackHole2chName) }),
              let outputBH16 = manager.outputDevices.first(where: { $0.name.contains(Self.blackHole16chName) }),
              let inputBH16 = manager.inputDevices.first(where: { $0.name.contains(Self.blackHole16chName) }) else {
            throw XCTSkip(
                """
                BlackHole virtual devices not detected. Install with:
                  brew install --cask blackhole-2ch blackhole-16ch
                Then restart the test runner so CoreAudio picks them up.
                """
            )
        }
        blackHole2chInputID = inputBH2.id
        blackHole16chOutputID = outputBH16.id
        blackHole16chInputID = inputBH16.id
    }

    // MARK: - Frequency preservation

    func testRouteSineWavePreservesFrequencyAt1kHz() throws {
        let detected = try routeAndMeasureFrequency(
            inputFrequency: 1000,
            sourceSampleRate: Self.sampleRate
        )
        XCTAssertEqual(detected, 1000, accuracy: 5.0,
                       "Routed 1 kHz should arrive within ±5 Hz")
    }

    func testRouteSineWavePreservesFrequencyAt440Hz() throws {
        let detected = try routeAndMeasureFrequency(
            inputFrequency: 440,
            sourceSampleRate: Self.sampleRate
        )
        XCTAssertEqual(detected, 440, accuracy: 5.0)
    }

    func testRouteHandles44_1kHzSourceCleanly() throws {
        // SoundRoute's HAL Output unit should up-rate the 44.1 kHz source
        // to 48 kHz internally and downstream cleanly.
        let detected = try routeAndMeasureFrequency(
            inputFrequency: 1000,
            sourceSampleRate: 44100
        )
        XCTAssertEqual(detected, 1000, accuracy: 10.0,
                       "Sample-rate conversion should preserve frequency within ±10 Hz")
    }

    // MARK: - Helpers

    /// Stand up generator → AudioManager → capturer, run for `duration`,
    /// tear everything down, and return the dominant frequency in the
    /// captured signal. Discards the first 250 ms of capture to skip
    /// engine-startup transients.
    private func routeAndMeasureFrequency(
        inputFrequency: Float,
        sourceSampleRate: Double,
        amplitude: Float = 0.5,
        duration: TimeInterval = 1.5
    ) throws -> Float {
        let generator = SineWaveGenerator()
        let capturer = AudioCapturer()
        let router = AudioManager()
        router.setInputDevice(blackHole2chInputID)
        router.setOutputDevice(blackHole16chOutputID)

        // Order matters: start the sink first so we don't miss the first
        // samples, then the routing engine, then the source.
        try capturer.start(deviceID: blackHole16chInputID)
        router.start()
        XCTAssertTrue(router.isRunning, "Router failed to start: \(router.errorMessage ?? "unknown")")
        try generator.start(
            frequency: inputFrequency,
            sampleRate: sourceSampleRate,
            amplitude: amplitude,
            deviceID: blackHole2chInputID
        )

        // Let the loop stabilize and accumulate samples.
        Thread.sleep(forTimeInterval: duration)

        generator.stop()
        router.stop()
        let capturedSamples = capturer.stop()

        // Skip the first 250 ms — engine startup, ramp-up, and any
        // pre-loop silence shouldn't influence the measurement.
        let skipFrames = Int(0.25 * Self.sampleRate)
        guard capturedSamples.count > skipFrames + Int(Self.sampleRate * 0.5) else {
            XCTFail("Insufficient captured samples (\(capturedSamples.count)) — pipeline may not have flowed")
            return 0
        }
        let analysisSlice = Array(capturedSamples[skipFrames...])

        return AudioAnalyzer.dominantFrequency(
            samples: analysisSlice,
            sampleRate: Self.sampleRate
        )
    }
}
