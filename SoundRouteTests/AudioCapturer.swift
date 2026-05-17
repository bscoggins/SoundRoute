import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Test-only AVAudioEngine that captures samples from a specified
/// CoreAudio input device. Used in Tier 3 audio-integrity tests to
/// read whatever SoundRoute wrote to a BlackHole virtual device's
/// output side, so the test can verify the routed signal.
final class AudioCapturer {
    private let engine = AVAudioEngine()
    private var captured: [Float] = []
    private let lock = NSLock()

    /// Begin capturing from `deviceID`. Samples accumulate in a private
    /// buffer until `stop()` is called.
    func start(deviceID: AudioDeviceID) throws {
        try setInputDevice(deviceID)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        try engine.start()
    }

    /// Stop capturing and return the accumulated samples (channel 0).
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channel0 = channelData[0]
        // Snapshot off the audio thread before grabbing the lock so we
        // hold the lock for as short a window as possible.
        var snapshot = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            snapshot[i] = channel0[i]
        }
        lock.lock()
        defer { lock.unlock() }
        captured.append(contentsOf: snapshot)
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) throws {
        var id = deviceID
        guard let inputAU = engine.inputNode.audioUnit else {
            throw NSError(
                domain: "AudioCapturer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Input node has no underlying AudioUnit"]
            )
        }
        let status = AudioUnitSetProperty(
            inputAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(
                domain: "AudioCapturer",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not set input device (OSStatus \(status))"]
            )
        }
    }
}
