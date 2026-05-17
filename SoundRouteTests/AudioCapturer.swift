import Foundation
import CoreAudio
import AudioToolbox

/// Test-only capturer that reads audio from a specified CoreAudio input
/// device into a private buffer. Built on a HAL Output AudioUnit
/// (configured for input) — the same pattern `AudioManager.inputAU` uses
/// — rather than `AVAudioEngine.installTap`.
///
/// **Why HAL Output instead of AVAudioEngine:** When the XCTest bundle
/// runs under the host app's sandbox container,
/// `AVAudioEngine.installTap` silently produces no callbacks for any
/// non-default input device (including BlackHole). The HAL Output unit
/// pattern works correctly under sandbox — verified by diagnostic probes
/// during the Tier 3 audio integrity investigation. Using the same
/// pattern as the production router also gives the test more confidence
/// that the test environment mirrors production.
final class AudioCapturer {
    private var audioUnit: AudioComponentInstance?
    private var captured: [Float] = []
    private let lock = NSLock()

    // Pre-allocated render buffers so the audio thread never allocates.
    private static let maxFramesPerSlice: UInt32 = 4096
    private var leftBuf: UnsafeMutablePointer<Float>?
    private var rightBuf: UnsafeMutablePointer<Float>?
    private var listPtr: UnsafeMutableAudioBufferListPointer?
    private var format = AudioStreamBasicDescription()

    /// Begin capturing from `deviceID`. Samples (channel 0) accumulate
    /// in a private buffer until `stop()` is called.
    func start(deviceID: AudioDeviceID) throws {
        // 48 kHz stereo non-interleaved float — matches AudioManager.
        format = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw NSError(domain: "AudioCapturer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "HAL component not found"])
        }

        var au: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &au)
        guard status == noErr, let unit = au else {
            throw NSError(domain: "AudioCapturer", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create HAL unit"])
        }

        // Enable input scope on bus 1; disable output scope on bus 0.
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1,
                                       &enable, UInt32(MemoryLayout<UInt32>.size)),
                  step: "enable input")
        var disable: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0,
                                       &disable, UInt32(MemoryLayout<UInt32>.size)),
                  step: "disable output")

        var maxFrames = Self.maxFramesPerSlice
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                       kAudioUnitScope_Global, 0,
                                       &maxFrames, UInt32(MemoryLayout<UInt32>.size)),
                  step: "set max frames")

        var dev = deviceID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  step: "set device")

        var fmt = format
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                  step: "set format")

        // Allocate render buffers.
        let n = Int(Self.maxFramesPerSlice)
        let lb = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let rb = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let lp = AudioBufferList.allocate(maximumBuffers: 2)
        leftBuf = lb
        rightBuf = rb
        listPtr = lp

        var cb = AURenderCallbackStruct(
            inputProc: captureCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                       kAudioUnitScope_Global, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  step: "set input callback")

        try check(AudioUnitInitialize(unit), step: "initialize")
        try check(AudioOutputUnitStart(unit), step: "start")

        audioUnit = unit
    }

    /// Stop capturing and return the accumulated channel-0 samples.
    func stop() -> [Float] {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        leftBuf?.deallocate(); leftBuf = nil
        rightBuf?.deallocate(); rightBuf = nil
        listPtr?.unsafeMutablePointer.deallocate(); listPtr = nil
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    /// Audio-thread entry: pull frames from the input AU into our
    /// pre-allocated buffers, snapshot channel 0 onto the heap, then
    /// append under the lock. The audio thread never blocks for long.
    fileprivate func handleCallback(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        ts: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) {
        guard frames <= Self.maxFramesPerSlice,
              let unit = audioUnit,
              let lb = leftBuf, let rb = rightBuf,
              let lp = listPtr else { return }
        let bytes = frames * 4
        lp[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes,
                            mData: UnsafeMutableRawPointer(lb))
        lp[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes,
                            mData: UnsafeMutableRawPointer(rb))
        let status = AudioUnitRender(unit, flags, ts, 1, frames, lp.unsafeMutablePointer)
        guard status == noErr else { return }
        var snap = [Float](repeating: 0, count: Int(frames))
        for i in 0..<Int(frames) { snap[i] = lb[i] }
        lock.lock()
        captured.append(contentsOf: snap)
        lock.unlock()
    }

    private func check(_ status: OSStatus, step: String) throws {
        guard status == noErr else {
            throw NSError(domain: "AudioCapturer", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(step) failed (OSStatus \(status))"])
        }
    }
}

private func captureCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capturer = Unmanaged<AudioCapturer>.fromOpaque(inRefCon).takeUnretainedValue()
    capturer.handleCallback(flags: ioActionFlags, ts: inTimeStamp, frames: inNumberFrames)
    return noErr
}
