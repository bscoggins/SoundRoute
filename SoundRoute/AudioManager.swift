import Foundation
import AudioToolbox
import CoreAudio
import AppKit
import AVFoundation

class AudioManager: ObservableObject {
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var isMicrophoneDenied = false

    private var inputDeviceID: AudioDeviceID?
    private var outputDeviceID: AudioDeviceID?

    // Two HAL Output AudioUnits — one configured for input, one for output —
    // bridged by a ring buffer.
    private var inputAU: AudioComponentInstance?
    private var outputAU: AudioComponentInstance?

    private var ringBuffer: RingBuffer?
    private var bufferFormat = AudioStreamBasicDescription()

    // Pre-allocated render buffers used inside the input callback so the
    // audio thread never has to allocate. Sized to maxFramesPerSlice; the
    // unit is told to never deliver more than that many frames per call.
    private static let maxFramesPerSlice: UInt32 = 4096

    // Ring buffer capacity in frames (~170 ms at 48 kHz) — generous slack to
    // absorb device clock drift between input and output.
    private static let ringBufferCapacityFrames: Int = 8192

    private var inputBuffers: PreallocatedInputBuffers?

    private var willTerminateObserver: NSObjectProtocol?

    init() {
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
    }

    deinit {
        if let token = willTerminateObserver {
            NotificationCenter.default.removeObserver(token)
        }
        stop()
    }

    func setInputDevice(_ deviceID: AudioDeviceID) {
        inputDeviceID = deviceID
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        outputDeviceID = deviceID
    }

    func start() {
        guard let inputID = inputDeviceID, let outputID = outputDeviceID else {
            errorMessage = "Please select both input and output devices"
            return
        }

        // Mic permission gates audio input. Detect explicitly so we can show
        // a useful message + Open-Settings affordance instead of an opaque
        // OSStatus when the user has previously denied.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.start()
                    } else {
                        self?.isMicrophoneDenied = true
                        self?.errorMessage = "SoundRoute needs microphone access to read from input devices."
                    }
                }
            }
            return
        case .denied, .restricted:
            isMicrophoneDenied = true
            errorMessage = "Microphone access is off. Open System Settings to grant SoundRoute access."
            return
        @unknown default:
            errorMessage = "Microphone permission state is unknown."
            return
        }

        stop()
        errorMessage = nil
        isMicrophoneDenied = false

        // Hardcoded to 48 kHz stereo non-interleaved float. The HAL Output
        // unit handles sample-rate and channel-count conversion to/from the
        // device's native format, so this works for ~all consumer hardware.
        // Mono-only devices may require explicit format negotiation; deferred.
        bufferFormat = AudioStreamBasicDescription(
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

        ringBuffer = RingBuffer(channelCount: 2, capacityFrames: Self.ringBufferCapacityFrames)
        inputBuffers = PreallocatedInputBuffers(maxFrames: Int(Self.maxFramesPerSlice))

        guard let inputUnit = createInputUnit(deviceID: inputID) else {
            cleanup()
            return
        }
        inputAU = inputUnit

        guard let outputUnit = createOutputUnit(deviceID: outputID) else {
            cleanup()
            return
        }
        outputAU = outputUnit

        var status = AudioOutputUnitStart(inputUnit)
        if status != noErr {
            errorMessage = "Could not start input unit (error: \(status))"
            cleanup()
            return
        }

        status = AudioOutputUnitStart(outputUnit)
        if status != noErr {
            errorMessage = "Could not start output unit (error: \(status))"
            cleanup()
            return
        }

        isRunning = true
    }

    private func createInputUnit(deviceID: AudioDeviceID) -> AudioComponentInstance? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            errorMessage = "Could not find HAL component"
            return nil
        }

        var au: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &au)
        guard status == noErr, let audioUnit = au else {
            errorMessage = "Could not create input unit (error: \(status))"
            return nil
        }

        // Enable input
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            errorMessage = "Could not enable input (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        // Disable output on input unit
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                      kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            errorMessage = "Could not disable output on input unit (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        // Bound the per-callback frame count so our pre-allocated buffers fit.
        var maxFrames = Self.maxFramesPerSlice
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            errorMessage = "Could not set max frames (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        var deviceIDVar = deviceID
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            errorMessage = "Could not set input device (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        var format = bufferFormat
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr {
            errorMessage = "Could not set input format (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        // passUnretained is safe here because cleanup() always disposes the
        // AudioUnit (which synchronously drains any in-flight callbacks)
        // before this AudioManager can be deallocated. See deinit -> stop().
        var callbackStruct = AURenderCallbackStruct(
            inputProc: inputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status != noErr {
            errorMessage = "Could not set input callback (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        status = AudioUnitInitialize(audioUnit)
        if status != noErr {
            errorMessage = "Could not initialize input unit (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        return audioUnit
    }

    private func createOutputUnit(deviceID: AudioDeviceID) -> AudioComponentInstance? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            errorMessage = "Could not find HAL component"
            return nil
        }

        var au: AudioComponentInstance?
        var status = AudioComponentInstanceNew(component, &au)
        guard status == noErr, let audioUnit = au else {
            errorMessage = "Could not create output unit (error: \(status))"
            return nil
        }

        var maxFrames = Self.maxFramesPerSlice
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                                      kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        if status != noErr {
            errorMessage = "Could not set max frames (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        var deviceIDVar = deviceID
        status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0, &deviceIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            errorMessage = "Could not set output device (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        var format = bufferFormat
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if status != noErr {
            errorMessage = "Could not set output format (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        // See passUnretained note in createInputUnit.
        var callbackStruct = AURenderCallbackStruct(
            inputProc: outputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        status = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback,
                                      kAudioUnitScope_Input, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        if status != noErr {
            errorMessage = "Could not set render callback (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        status = AudioUnitInitialize(audioUnit)
        if status != noErr {
            errorMessage = "Could not initialize output unit (error: \(status))"
            AudioComponentInstanceDispose(audioUnit)
            return nil
        }

        return audioUnit
    }

    private func disposeUnit(_ unit: inout AudioComponentInstance?) {
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        unit = nil
    }

    private func cleanup() {
        // AudioOutputUnitStop is synchronous and drains in-flight callbacks,
        // so by the time disposeUnit returns, the audio thread no longer
        // touches our pre-allocated buffers — safe to drop the last reference.
        disposeUnit(&outputAU)
        disposeUnit(&inputAU)
        inputBuffers = nil  // ARC frees via deinit
        ringBuffer = nil
    }

    func stop() {
        cleanup()
        isRunning = false
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    /// Audio-thread entry point for input. Reuses pre-allocated buffers so
    /// the render thread never allocates.
    fileprivate func handleInputCallback(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inNumberFrames: UInt32
    ) {
        guard inNumberFrames <= Self.maxFramesPerSlice,
              let inputAU = inputAU,
              let buffers = inputBuffers else { return }

        let byteSize = inNumberFrames * 4
        buffers.listPtr[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: byteSize,
            mData: UnsafeMutableRawPointer(buffers.left)
        )
        buffers.listPtr[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: byteSize,
            mData: UnsafeMutableRawPointer(buffers.right)
        )

        let status = AudioUnitRender(
            inputAU,
            ioActionFlags,
            inTimeStamp,
            1,
            inNumberFrames,
            buffers.listPtr.unsafeMutablePointer
        )
        if status == noErr {
            ringBuffer?.store(buffers.listPtr.unsafeMutablePointer, frameCount: inNumberFrames)
        }
    }

    fileprivate func handleOutputCallback(
        ioData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: UInt32
    ) {
        ringBuffer?.fetch(ioData, frameCount: frameCount)
    }
}

/// Owns the heap memory the input render callback writes into. Class so ARC
/// guarantees `deinit` runs (and frees pointers) when the last reference is
/// dropped — an in-flight audio callback holds its own strong reference for
/// the duration of the call, keeping the buffers alive until it returns.
private final class PreallocatedInputBuffers {
    let listPtr: UnsafeMutableAudioBufferListPointer
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>

    init(maxFrames: Int) {
        self.listPtr = AudioBufferList.allocate(maximumBuffers: 2)
        self.left = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        self.right = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    }

    deinit {
        listPtr.unsafeMutablePointer.deallocate()
        left.deallocate()
        right.deallocate()
    }
}

private func inputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let manager = Unmanaged<AudioManager>.fromOpaque(inRefCon).takeUnretainedValue()
    manager.handleInputCallback(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inNumberFrames: inNumberFrames
    )
    return noErr
}

private func outputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard let bufferList = ioData else { return noErr }
    let manager = Unmanaged<AudioManager>.fromOpaque(inRefCon).takeUnretainedValue()
    manager.handleOutputCallback(ioData: bufferList, frameCount: inNumberFrames)
    return noErr
}
