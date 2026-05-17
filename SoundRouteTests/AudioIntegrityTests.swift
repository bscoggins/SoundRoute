import XCTest
import CoreAudio
@testable import SoundRoute

/// Tier 3 audio-integrity tests. Run the routed audio through a virtual
/// loopback pipeline (BlackHole 2ch → SoundRoute → BlackHole 16ch) and
/// verify the captured signal matches what was generated.
///
/// Prerequisites on the dev machine:
/// ```
/// brew install --cask blackhole-2ch blackhole-16ch
/// ```
///
/// Tests auto-skip when BlackHole devices aren't detected — these stay
/// developer-machine-only and don't gate CI.
///
/// **Status:** harness scaffolding is in place; the
/// `SineWaveGenerator` / `AudioCapturer` / analyzer implementations are
/// the next focused work item and live alongside this file under
/// `SoundRouteTests/AudioTestHarness/`. Until those land the tests
/// here are gated behind `XCTSkip`. Plan details:
/// `IMPLEMENTATION_PLAN_v1.1.md` § "Testing additions — Tier 3."
final class AudioIntegrityTests: XCTestCase {

    private static let blackHole2chName = "BlackHole 2ch"
    private static let blackHole16chName = "BlackHole 16ch"

    private var blackHole2chID: AudioDeviceID = 0
    private var blackHole16chID: AudioDeviceID = 0

    override func setUpWithError() throws {
        let manager = AudioDeviceManager()

        guard let inputBH2 = manager.inputDevices.first(where: { $0.name.contains(Self.blackHole2chName) }),
              let outputBH16 = manager.outputDevices.first(where: { $0.name.contains(Self.blackHole16chName) }) else {
            throw XCTSkip(
                """
                BlackHole virtual devices not detected. Install with:
                  brew install --cask blackhole-2ch blackhole-16ch
                Tier 3 audio-integrity tests only run on machines that have
                both BlackHole 2ch and BlackHole 16ch present.
                """
            )
        }
        blackHole2chID = inputBH2.id
        blackHole16chID = outputBH16.id

        // Until the harness implementation lands, skip the actual roundtrip
        // tests. Removing this skip is gated on the SineWaveGenerator /
        // AudioCapturer / AudioAnalyzer files being added.
        throw XCTSkip("Tier 3 harness implementation pending — see test file header.")
    }

    func testRouteSineWavePreservesFrequencyAt1kHz() throws {
        // Pseudocode the test will execute once the harness lands:
        //   1. Start SineWaveGenerator at 1 kHz / 48 kHz / 0.5 amplitude
        //      → BlackHole 2ch.
        //   2. Start AudioManager routing BlackHole 2ch → BlackHole 16ch.
        //   3. Start AudioCapturer reading from BlackHole 16ch for 1.5 s.
        //   4. Stop everything.
        //   5. Measure dominant frequency in captured samples via
        //      zero-crossing detection (simpler than FFT, sufficient for
        //      clean sine waves).
        //   6. Assert within ±5 Hz of 1000 Hz.
        XCTFail("Test body pending harness implementation")
    }

    func testRouteSineWavePreservesAmplitudeWithin3dB() throws {
        // 1. Generate -6 dBFS sine.
        // 2. Route via AudioManager.
        // 3. Capture and compute RMS.
        // 4. Assert within ±3 dB of source amplitude (HAL conversion adds
        //    minimal loss for in-range signals).
        XCTFail("Test body pending harness implementation")
    }

    func testRouteHandles44_1kHzSourceCleanly() throws {
        // Confirms the HAL Output unit's sample-rate conversion path —
        // most common consumer hardware is 44.1 kHz native and we route
        // through 48 kHz internally.
        XCTFail("Test body pending harness implementation")
    }
}
