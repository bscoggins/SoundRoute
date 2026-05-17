import Foundation

/// Pure-function analysis of captured audio samples. Used by Tier 3
/// integrity tests to verify a routed signal matches what was sent.
///
/// Uses zero-crossing detection instead of FFT — simpler, more robust
/// for clean sine inputs, and avoids the pointer choreography of
/// `vDSP_fft_zrip`. Acceptable accuracy is ±sampleRate/(2 × N) Hz where
/// N is the sample count; for 1 second of 48 kHz audio that's
/// ±0.01 Hz under ideal conditions, ±a few Hz with typical capture
/// noise — well within our test tolerances.
enum AudioAnalyzer {
    /// Detect the dominant frequency in Hz via zero-crossing counting.
    /// Reliable for clean periodic signals; less so for complex spectra.
    static func dominantFrequency(samples: [Float], sampleRate: Double) -> Float {
        guard samples.count > 1, sampleRate > 0 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let curr = samples[i]
            if (prev < 0 && curr >= 0) || (prev >= 0 && curr < 0) {
                crossings += 1
            }
        }
        let duration = Double(samples.count) / sampleRate
        // Two zero-crossings per full cycle (one up, one down).
        return Float(Double(crossings) / (2.0 * duration))
    }

    /// Root-mean-square amplitude of the signal. Returns 0 for empty
    /// input. For a pure sine of peak amplitude A, RMS is A/√2 ≈ 0.707·A.
    static func rmsAmplitude(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }

    /// RMS amplitude converted to dBFS (decibels relative to full scale).
    /// Returns -infinity for silence.
    static func dBFS(samples: [Float]) -> Float {
        let rms = rmsAmplitude(samples: samples)
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }

    /// Synthesize a sine wave for analyzer self-tests. Frame count is
    /// `Int(sampleRate * duration)`. Amplitude is the peak value (so a
    /// 0.5-amplitude wave has RMS ≈ 0.354).
    static func synthesizeSine(
        frequency: Float,
        sampleRate: Double,
        amplitude: Float,
        duration: TimeInterval
    ) -> [Float] {
        let frameCount = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: frameCount)
        let phaseIncrement = 2 * Float.pi * frequency / Float(sampleRate)
        var phase: Float = 0
        for i in 0..<frameCount {
            samples[i] = sin(phase) * amplitude
            phase += phaseIncrement
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
        return samples
    }
}
