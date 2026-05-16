import Foundation
import AudioToolbox
import CoreAudio
import os

/// SPSC ring buffer for handing audio from the input render thread to the
/// output render thread.
///
/// Indices are monotonically increasing; modulo `capacity` only on actual
/// buffer access. `available = writeIndex - readIndex`. On overrun the read
/// index is advanced (drop oldest); on underrun the consumer's output is
/// zero-filled for the missing tail.
///
/// OSAllocatedUnfairLock keeps the critical section to a memcpy-equivalent.
/// A truly lock-free variant (atomic indices with acquire/release fences via
/// swift-atomics) is the proper long-term fix.
final class RingBuffer {
    private var buffers: [[Float]]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let capacity: Int
    private let lock = OSAllocatedUnfairLock()

    init(channelCount: Int, capacityFrames: Int) {
        self.capacity = capacityFrames
        self.buffers = (0..<channelCount).map { _ in [Float](repeating: 0, count: capacityFrames) }
    }

    func store(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        let n = Int(frameCount)
        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        for (channelIndex, buffer) in ablPointer.enumerated() {
            guard channelIndex < buffers.count,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }

            for frame in 0..<n {
                buffers[channelIndex][(writeIndex + frame) % capacity] = data[frame]
            }
        }
        writeIndex += n

        // Overrun: consumer fell behind — drop oldest by advancing readIndex
        // so we never report more than `capacity` frames available.
        if writeIndex - readIndex > capacity {
            readIndex = writeIndex - capacity
        }
    }

    func fetch(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        lock.lock()
        defer { lock.unlock() }

        let n = Int(frameCount)
        let available = writeIndex - readIndex
        let toRead = min(n, available)

        let ablPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        for (channelIndex, buffer) in ablPointer.enumerated() {
            guard channelIndex < buffers.count,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }

            for frame in 0..<toRead {
                data[frame] = buffers[channelIndex][(readIndex + frame) % capacity]
            }
            // Underrun: zero-fill rather than play stale audio from before
            // the read pointer.
            for frame in toRead..<n {
                data[frame] = 0
            }
        }
        readIndex += toRead
    }
}
