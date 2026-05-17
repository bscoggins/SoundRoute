import XCTest
@testable import SoundRoute

/// Pure-logic tests for `AudioAnalyzer`. Run anywhere — no audio
/// hardware or virtual devices needed. These exist to catch bugs in
/// the analyzer itself before the Tier 3 integration tests start
/// depending on it; if a routed signal looks wrong, we want to know
/// the problem is in the routing, not in our analysis.
final class AudioAnalyzerTests: XCTestCase {

    // MARK: - Frequency detection

    func testDominantFrequencyDetects1kHz() {
        let samples = AudioAnalyzer.synthesizeSine(
            frequency: 1000,
            sampleRate: 48000,
            amplitude: 0.5,
            duration: 1.0
        )
        let detected = AudioAnalyzer.dominantFrequency(samples: samples, sampleRate: 48000)
        XCTAssertEqual(detected, 1000, accuracy: 1.0, "Should detect 1 kHz within ±1 Hz")
    }

    func testDominantFrequencyDetects440Hz() {
        let samples = AudioAnalyzer.synthesizeSine(
            frequency: 440,
            sampleRate: 48000,
            amplitude: 0.5,
            duration: 1.0
        )
        let detected = AudioAnalyzer.dominantFrequency(samples: samples, sampleRate: 48000)
        XCTAssertEqual(detected, 440, accuracy: 1.0)
    }

    func testDominantFrequencyDetects10kHz() {
        let samples = AudioAnalyzer.synthesizeSine(
            frequency: 10000,
            sampleRate: 48000,
            amplitude: 0.5,
            duration: 0.5
        )
        let detected = AudioAnalyzer.dominantFrequency(samples: samples, sampleRate: 48000)
        XCTAssertEqual(detected, 10000, accuracy: 5.0)
    }

    func testDominantFrequencyOfSilenceIsZero() {
        let silence = [Float](repeating: 0, count: 48000)
        let detected = AudioAnalyzer.dominantFrequency(samples: silence, sampleRate: 48000)
        XCTAssertEqual(detected, 0)
    }

    func testDominantFrequencyOfEmptyIsZero() {
        let detected = AudioAnalyzer.dominantFrequency(samples: [], sampleRate: 48000)
        XCTAssertEqual(detected, 0)
    }

    // MARK: - RMS amplitude

    func testRMSOfFullScaleSineIs1OverSqrt2() {
        // A sine of peak 1.0 has RMS = 1/√2 ≈ 0.7071.
        let samples = AudioAnalyzer.synthesizeSine(
            frequency: 1000,
            sampleRate: 48000,
            amplitude: 1.0,
            duration: 1.0
        )
        let rms = AudioAnalyzer.rmsAmplitude(samples: samples)
        XCTAssertEqual(rms, 1.0 / sqrt(2.0), accuracy: 0.01)
    }

    func testRMSOfHalfAmplitudeSineIsHalfOfFullScale() {
        let samples = AudioAnalyzer.synthesizeSine(
            frequency: 1000,
            sampleRate: 48000,
            amplitude: 0.5,
            duration: 1.0
        )
        let rms = AudioAnalyzer.rmsAmplitude(samples: samples)
        XCTAssertEqual(rms, 0.5 / sqrt(2.0), accuracy: 0.01)
    }

    func testRMSOfSilenceIsZero() {
        let silence = [Float](repeating: 0, count: 48000)
        XCTAssertEqual(AudioAnalyzer.rmsAmplitude(samples: silence), 0)
    }

    func testRMSOfEmptyIsZero() {
        XCTAssertEqual(AudioAnalyzer.rmsAmplitude(samples: []), 0)
    }

    // MARK: - dBFS

    func testDBFSOfFullScaleSineIsAboutMinus3() {
        // RMS of a full-scale sine is 1/√2 ≈ -3.01 dBFS.
        let samples = AudioAnalyzer.synthesizeSine(
            frequency: 1000,
            sampleRate: 48000,
            amplitude: 1.0,
            duration: 1.0
        )
        let db = AudioAnalyzer.dBFS(samples: samples)
        XCTAssertEqual(db, -3.01, accuracy: 0.1)
    }

    func testDBFSOfHalfAmplitudeSineIsAboutMinus9() {
        // RMS of 0.5-amplitude sine = 0.354 → 20·log10(0.354) ≈ -9.03 dBFS.
        let samples = AudioAnalyzer.synthesizeSine(
            frequency: 1000,
            sampleRate: 48000,
            amplitude: 0.5,
            duration: 1.0
        )
        let db = AudioAnalyzer.dBFS(samples: samples)
        XCTAssertEqual(db, -9.03, accuracy: 0.1)
    }

    func testDBFSOfSilenceIsNegativeInfinity() {
        let silence = [Float](repeating: 0, count: 48000)
        XCTAssertEqual(AudioAnalyzer.dBFS(samples: silence), -.infinity)
    }
}
