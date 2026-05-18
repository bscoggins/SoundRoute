import Foundation
import AudioToolbox
import CoreAudio
import AppKit
import AVFoundation

class AudioManager: ObservableObject {
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var isMicrophoneDenied = false

    /// Flips `true` exactly when the free-tier daily budget is reached —
    /// either organically while routing, or by an attempt to `start()`
    /// when the budget is already exhausted. The view observes this to
    /// auto-present the paywall, then resets it back to `false`.
    @Published var dailyLimitReached: Bool = false

    /// Free-tier daily budget tracker. Optional because tests and
    /// previews can omit it; in the running app it's wired up by the
    /// view layer at launch. The audio path uses it to gate `start()`
    /// and to count seconds while routing.
    var dailyUsageTracker: DailyUsageTracker?

    /// Snapshot of `StoreManager.isUnlocked` kept in sync via
    /// `handleUnlockStateChange(unlocked:)`. Cached locally so the audio
    /// path doesn't have to hop actors to read it.
    private var isUnlockedSnapshot: Bool = false

    private var inputDeviceID: AudioDeviceID?
    private var outputDeviceID: AudioDeviceID?

    // Two HAL Output AudioUnits — one configured for input, one for output —
    // bridged by a ring buffer.
    private var inputAU: AudioComponentInstance?
    private var outputAU: AudioComponentInstance?

    private var ringBuffer: RingBuffer?

    // Format used end-to-end through the ring buffer. Sample rate is set
    // at start() from the **input device's nominal rate**, not a fixed
    // constant — macOS 26's HAL Output AudioUnit returns
    // kAudioUnitErr_CannotDoInCurrentContext from AudioUnitRender any time
    // its StreamFormat rate disagrees with the device's actual rate, so
    // we configure each AU at its own device's native rate and bridge
    // any rate mismatch ourselves via outputConverter below.
    private var bufferFormat = AudioStreamBasicDescription()

    // Output device's native rate. Used to configure the output AU and to
    // size outputConverter when input and output devices disagree.
    private var outputDeviceRate: Float64 = 48_000

    // SRC bridge from input rate (ring buffer rate) to output rate.
    // Created in start() only when the two devices' nominal rates differ;
    // nil means the output callback can fetch from the ring buffer
    // directly with no conversion overhead.
    private var outputConverter: AudioConverterRef?
    private var converterInputBuffers: PreallocatedInputBuffers?

    // Device IDs that the rate-change listener is currently registered
    // for. Captured at registration time so cleanup() can unregister
    // even if inputDeviceID/outputDeviceID have been updated since.
    private var rateListenerInputID: AudioDeviceID?
    private var rateListenerOutputID: AudioDeviceID?
    private var isReconfiguringForRateChange = false

    // Pre-allocated render buffers used inside the input callback so the
    // audio thread never has to allocate. Sized to maxFramesPerSlice; the
    // unit is told to never deliver more than that many frames per call.
    private static let maxFramesPerSlice: UInt32 = 4096

    // The output AU's render callback can request up to maxFramesPerSlice
    // frames at the output rate. When SRC is active, the corresponding
    // input-rate frame count is bounded by maxFramesPerSlice * (R_in/R_out).
    // We bound this conservatively at 4× to handle ratios up to e.g.
    // 192 kHz input vs. 48 kHz output (worst plausible case).
    private static let maxConverterInputFrames: Int = Int(maxFramesPerSlice) * 4

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

        // Free-tier daily-budget gate. Unlocked users skip this entirely.
        if !isUnlockedSnapshot, let tracker = dailyUsageTracker, tracker.isLimitReached {
            errorMessage = "Free routing time for today is used up."
            dailyLimitReached = true
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

        // Read each device's nominal sample rate. macOS 26's HAL Output
        // AudioUnit requires StreamFormat rate to match the device — any
        // mismatch makes AudioUnitRender fail with
        // kAudioUnitErr_CannotDoInCurrentContext on every callback (sound
        // silently disappears). So we configure each AU at its device's
        // own rate and let outputConverter bridge if they differ.
        let inputRate = Self.deviceNominalSampleRate(inputID) ?? 48_000
        outputDeviceRate = Self.deviceNominalSampleRate(outputID) ?? 48_000

        // Ring buffer + input AU run at the input device's rate.
        bufferFormat = Self.makeStreamFormat(sampleRate: inputRate)

        ringBuffer = RingBuffer(channelCount: 2, capacityFrames: Self.ringBufferCapacityFrames)
        inputBuffers = PreallocatedInputBuffers(maxFrames: Int(Self.maxFramesPerSlice))

        // Create the output-side SRC bridge only when devices disagree.
        // When they match (the common case — both at 48 kHz), the output
        // callback fetches from the ring buffer directly with no
        // conversion overhead.
        if inputRate != outputDeviceRate {
            converterInputBuffers = PreallocatedInputBuffers(maxFrames: Self.maxConverterInputFrames)
            var srcFormat = bufferFormat
            var dstFormat = Self.makeStreamFormat(sampleRate: outputDeviceRate)
            var converter: AudioConverterRef?
            let cvStatus = AudioConverterNew(&srcFormat, &dstFormat, &converter)
            guard cvStatus == noErr, let converter else {
                errorMessage = "Could not create sample-rate converter (error: \(cvStatus))"
                cleanup()
                return
            }
            outputConverter = converter
        }

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

        registerRateChangeListeners(inputID: inputID, outputID: outputID)

        isRunning = true
        startTrackingIfNeeded()
    }

    /// Hand control to the daily-usage tracker so it counts seconds
    /// against the free budget while routing. Unlocked users skip this
    /// entirely. The tracker fires `handleDailyLimitReached` once if the
    /// daily cap is hit mid-session.
    private func startTrackingIfNeeded() {
        guard !isUnlockedSnapshot else { return }
        dailyUsageTracker?.start { [weak self] in
            self?.handleDailyLimitReached()
        }
    }

    /// Invoked by `DailyUsageTracker` when the daily budget is exhausted
    /// mid-session. Stops routing cleanly, surfaces the message, and
    /// flips `dailyLimitReached` so the view auto-presents the paywall.
    private func handleDailyLimitReached() {
        cleanup()
        isRunning = false
        errorMessage = "Free routing time for today is used up."
        dailyLimitReached = true
    }

    /// Called by the view layer whenever `StoreManager.isUnlocked`
    /// changes, so the audio engine has a fresh, actor-local snapshot of
    /// unlock state without reaching into `StoreManager` from the audio
    /// path.
    ///
    /// - **Unlock mid-session:** stop the tracker so the newly-purchased
    ///   session doesn't keep draining the free budget. Also clear any
    ///   stale daily-limit error state — being unlocked means any
    ///   "you've used up your free time" condition is obsolete by
    ///   definition. Persistent errors (mic denial, device init failure)
    ///   re-surface naturally on the next `start()` attempt.
    /// - **Lock while routing:** re-engage the tracker so the free-tier
    ///   daily cap takes effect. If the user is already over the daily
    ///   limit, this fires the limit callback immediately and tears
    ///   down routing cleanly (which sets the error message itself).
    /// - **Lock while idle with exhausted budget:** surface the same
    ///   red error as a mid-session limit hit. Otherwise the popover
    ///   transitions to a locked + no-time-left state silently, with
    ///   only the header status line indicating why routing is
    ///   blocked — inconsistent with every other path into this state.
    func handleUnlockStateChange(unlocked: Bool) {
        let wasUnlocked = isUnlockedSnapshot
        isUnlockedSnapshot = unlocked
        if unlocked {
            dailyUsageTracker?.stop()
            errorMessage = nil
            dailyLimitReached = false
        } else if wasUnlocked {
            if isRunning {
                startTrackingIfNeeded()
            } else if dailyUsageTracker?.isLimitReached == true {
                errorMessage = "Free routing time for today is used up."
            }
        }
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

        // Output AU runs at the output device's native rate. If that
        // differs from the input device's rate, outputConverter (set up
        // in start()) bridges between them — the output render callback
        // pulls from the ring buffer at inputRate and converts to
        // outputDeviceRate before delivering.
        var format = Self.makeStreamFormat(sampleRate: outputDeviceRate)
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
        unregisterRateChangeListeners()
        disposeUnit(&outputAU)
        disposeUnit(&inputAU)
        if let converter = outputConverter {
            AudioConverterDispose(converter)
        }
        outputConverter = nil
        converterInputBuffers = nil
        inputBuffers = nil  // ARC frees via deinit
        ringBuffer = nil
    }

    // MARK: - Device rate-change watcher

    /// Registers CoreAudio property listeners for nominal sample rate
    /// changes on both the input and output devices. When either device's
    /// rate changes (Audio MIDI Setup, or a pro audio interface
    /// auto-negotiating for another client), `handleDeviceRateChange`
    /// rebuilds the AU + converter chain on the main thread so routing
    /// continues at the new rate without the user having to Stop + Start.
    ///
    /// Uses the C-function listener API (refCon pattern, same as the audio
    /// render callbacks) rather than the Block variant — the latter
    /// caused SEGVs across the test suite, likely due to Swift's optional
    /// storage of `@convention(block)` closures interacting badly with
    /// `AudioObject*PropertyListenerBlock`'s lifecycle.
    private func registerRateChangeListeners(inputID: AudioDeviceID, outputID: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        AudioObjectAddPropertyListener(inputID, &addr, rateChangeListenerProc, refCon)
        rateListenerInputID = inputID
        if outputID != inputID {
            AudioObjectAddPropertyListener(outputID, &addr, rateChangeListenerProc, refCon)
            rateListenerOutputID = outputID
        } else {
            rateListenerOutputID = nil
        }
    }

    private func unregisterRateChangeListeners() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if let inID = rateListenerInputID {
            AudioObjectRemovePropertyListener(inID, &addr, rateChangeListenerProc, refCon)
            rateListenerInputID = nil
        }
        if let outID = rateListenerOutputID {
            AudioObjectRemovePropertyListener(outID, &addr, rateChangeListenerProc, refCon)
            rateListenerOutputID = nil
        }
    }

    /// Called (on the main thread, dispatched from the CoreAudio listener
    /// callback) when either device's nominal sample rate changes.
    /// Reconfigures the pipeline only if the new rates actually differ
    /// from what we built `start()` against — guards against listener
    /// chatter and re-entry while a reconfigure is already in flight.
    fileprivate func handleDeviceRateChange() {
        guard isRunning,
              !isReconfiguringForRateChange,
              let inID = inputDeviceID,
              let outID = outputDeviceID else { return }

        let currentInputRate = Self.deviceNominalSampleRate(inID) ?? 0
        let currentOutputRate = Self.deviceNominalSampleRate(outID) ?? 0
        let configuredInputRate = bufferFormat.mSampleRate
        let configuredOutputRate = outputDeviceRate

        guard currentInputRate != configuredInputRate
                || currentOutputRate != configuredOutputRate else {
            return
        }

        isReconfiguringForRateChange = true
        defer { isReconfiguringForRateChange = false }

        // start() begins with stop() → cleanup(), which unregisters the
        // listeners and tears down the AU chain + converter. It then
        // re-reads each device's current nominal rate, rebuilds the
        // pipeline, and re-registers the listeners. The unlock snapshot
        // and daily tracker reference persist on AudioManager so gating
        // + counting resume seamlessly.
        start()
    }

    func stop() {
        // Stop the daily counter first so it stops accruing seconds; the
        // tracker self-persists on every tick, so all the user's actual
        // routing time is already saved — no flush needed here.
        dailyUsageTracker?.stop()
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
        // Common path: input and output devices agree on rate, so the
        // output AU asks for the exact same frames we have queued. Skip
        // SRC entirely — fetch directly from the ring buffer.
        guard let converter = outputConverter else {
            ringBuffer?.fetch(ioData, frameCount: frameCount)
            return
        }

        // Rate-bridged path: AudioConverter pulls inputRate frames from
        // the ring via our input-data callback and writes outputRate
        // frames to ioData. Real-time-safe — no allocations in the
        // hot path; converterInputBuffers were pre-allocated in start().
        var framesToProduce = frameCount
        let status = AudioConverterFillComplexBuffer(
            converter,
            converterInputDataCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &framesToProduce,
            ioData,
            nil
        )
        if status != noErr || framesToProduce < frameCount {
            // Underrun or convert failure — zero-fill the remaining
            // tail of each channel buffer so the device gets silence
            // rather than uninitialized memory.
            let abl = UnsafeMutableAudioBufferListPointer(ioData)
            let zeroOffset = Int(framesToProduce) * 4
            let zeroBytes = Int(frameCount - framesToProduce) * 4
            for buf in abl {
                guard let base = buf.mData, zeroBytes > 0 else { continue }
                memset(base.advanced(by: zeroOffset), 0, zeroBytes)
            }
        }
    }

    /// Called by `AudioConverterFillComplexBuffer` on the audio thread
    /// to refill the converter's input buffer from our ring buffer.
    /// Always provides exactly the number of frames requested (the ring
    /// buffer zero-fills on underrun, which is the right behavior here:
    /// briefly missing input maps to brief silence at the output).
    fileprivate func handleConverterInputData(
        ioDataPacketCount: UnsafeMutablePointer<UInt32>,
        ioData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let maxFrames = UInt32(Self.maxConverterInputFrames)
        let requested = min(ioDataPacketCount.pointee, maxFrames)
        guard let convBufs = converterInputBuffers else {
            ioDataPacketCount.pointee = 0
            return noErr
        }

        let byteSize = requested * 4
        convBufs.listPtr[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: byteSize,
            mData: UnsafeMutableRawPointer(convBufs.left)
        )
        convBufs.listPtr[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: byteSize,
            mData: UnsafeMutableRawPointer(convBufs.right)
        )
        ringBuffer?.fetch(convBufs.listPtr.unsafeMutablePointer, frameCount: requested)

        // Hand the converter our preallocated buffers (no copy).
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        abl[0] = convBufs.listPtr[0]
        if abl.count > 1 {
            abl[1] = convBufs.listPtr[1]
        }
        ioDataPacketCount.pointee = requested
        return noErr
    }

    // MARK: - Format helpers

    /// Reads a device's nominal sample rate via the CoreAudio HAL. Returns
    /// nil when the property isn't queryable on the device.
    private static func deviceNominalSampleRate(_ deviceID: AudioDeviceID) -> Float64? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    /// Builds the canonical SoundRoute stream format (stereo float32,
    /// non-interleaved, packed) at the requested sample rate.
    private static func makeStreamFormat(sampleRate: Float64) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}

private func rateChangeListenerProc(
    _ inObjectID: AudioObjectID,
    _ inNumberAddresses: UInt32,
    _ inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return noErr }
    let manager = Unmanaged<AudioManager>.fromOpaque(inClientData).takeUnretainedValue()
    // CoreAudio invokes this on its own thread; bounce to main where the
    // observable @Published state and the rebuild path can run safely.
    DispatchQueue.main.async {
        manager.handleDeviceRateChange()
    }
    return noErr
}

private func converterInputDataCallback(
    _ converter: AudioConverterRef,
    _ ioPacketCount: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ packetDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ refCon: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let refCon else { return noErr }
    let manager = Unmanaged<AudioManager>.fromOpaque(refCon).takeUnretainedValue()
    return manager.handleConverterInputData(ioDataPacketCount: ioPacketCount, ioData: ioData)
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
