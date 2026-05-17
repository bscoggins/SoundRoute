import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Test-only AVAudioEngine that pushes a continuous sine wave to a
/// specified CoreAudio output device. Used in Tier 3 audio-integrity
/// tests to drive a known signal through SoundRoute's routing pipeline
/// (via BlackHole virtual loopback) and verify the captured output.
final class SineWaveGenerator {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var phase: Float = 0

    /// Begin generating. `deviceID` is the CoreAudio device the engine
    /// writes to — typically a BlackHole virtual device whose output
    /// loops back to its own input side, which is then read by the
    /// system under test.
    func start(
        frequency: Float,
        sampleRate: Double,
        amplitude: Float,
        deviceID: AudioDeviceID
    ) throws {
        try setOutputDevice(deviceID)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        )!

        let phaseIncrement = 2 * Float.pi * frequency / Float(sampleRate)
        phase = 0

        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let sample = sin(self.phase) * amplitude
                self.phase += phaseIncrement
                if self.phase > 2 * .pi { self.phase -= 2 * .pi }
                for buffer in ablPointer {
                    guard let buf = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    buf[frame] = sample
                }
            }
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        sourceNode = source

        try engine.start()
    }

    func stop() {
        engine.stop()
        if let source = sourceNode {
            engine.detach(source)
            sourceNode = nil
        }
    }

    private func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        var id = deviceID
        guard let outputAU = engine.outputNode.audioUnit else {
            throw NSError(
                domain: "SineWaveGenerator",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Output node has no underlying AudioUnit"]
            )
        }
        let status = AudioUnitSetProperty(
            outputAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(
                domain: "SineWaveGenerator",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not set output device (OSStatus \(status))"]
            )
        }
    }
}
