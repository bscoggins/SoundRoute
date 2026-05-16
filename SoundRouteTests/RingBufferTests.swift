import XCTest
import AudioToolbox
@testable import SoundRoute

final class RingBufferTests: XCTestCase {

    // MARK: - Single-channel happy path

    func testStoreThenFetchReturnsIdenticalFrames() {
        let ring = RingBuffer(channelCount: 1, capacityFrames: 16)
        let input: [Float] = [1, 2, 3, 4, 5]

        let inList = TestBufferList(channels: 1, frameCapacity: 16)
        inList.write(channel: 0, values: input)
        ring.store(inList.pointer, frameCount: 5)

        let outList = TestBufferList(channels: 1, frameCapacity: 16)
        ring.fetch(outList.pointer, frameCount: 5)

        XCTAssertEqual(outList.read(channel: 0, count: 5), input)
    }

    // MARK: - Underrun behavior

    func testFetchWithoutWriteZeroFillsOutput() {
        let ring = RingBuffer(channelCount: 1, capacityFrames: 16)
        let outList = TestBufferList(channels: 1, frameCapacity: 16)
        // Pre-fill the destination with non-zero so we can detect that the
        // ring buffer actively zero-filled instead of leaving stale memory.
        outList.write(channel: 0, values: [9, 9, 9, 9])
        ring.fetch(outList.pointer, frameCount: 4)
        XCTAssertEqual(outList.read(channel: 0, count: 4), [0, 0, 0, 0])
    }

    func testFetchExceedingAvailableZeroFillsTail() {
        let ring = RingBuffer(channelCount: 1, capacityFrames: 16)
        let inList = TestBufferList(channels: 1, frameCapacity: 16)
        inList.write(channel: 0, values: [7, 8, 9])
        ring.store(inList.pointer, frameCount: 3)

        let outList = TestBufferList(channels: 1, frameCapacity: 16)
        outList.write(channel: 0, values: [-1, -1, -1, -1, -1])
        ring.fetch(outList.pointer, frameCount: 5)

        // First 3 frames returned, remaining 2 zero-filled — never stale audio.
        XCTAssertEqual(outList.read(channel: 0, count: 5), [7, 8, 9, 0, 0])
    }

    // MARK: - Overrun behavior

    func testOverrunDropsOldestFrames() {
        // Capacity 4. Write 10 frames. Read 4 — should be the most recent 4,
        // i.e. oldest 6 were discarded.
        let ring = RingBuffer(channelCount: 1, capacityFrames: 4)
        let inList = TestBufferList(channels: 1, frameCapacity: 16)
        inList.write(channel: 0, values: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        ring.store(inList.pointer, frameCount: 10)

        let outList = TestBufferList(channels: 1, frameCapacity: 16)
        ring.fetch(outList.pointer, frameCount: 4)
        XCTAssertEqual(outList.read(channel: 0, count: 4), [7, 8, 9, 10])
    }

    func testOverrunNeverReportsMoreThanCapacityAvailable() {
        // After heavy overrun, subsequent fetch larger than capacity should
        // return at most `capacity` real frames plus zero-fill.
        let ring = RingBuffer(channelCount: 1, capacityFrames: 4)
        let inList = TestBufferList(channels: 1, frameCapacity: 16)
        inList.write(channel: 0, values: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        ring.store(inList.pointer, frameCount: 10)

        let outList = TestBufferList(channels: 1, frameCapacity: 16)
        ring.fetch(outList.pointer, frameCount: 6)
        // First 4 are most-recent kept frames; last 2 are zero-fill since the
        // ring only held `capacity` (=4) frames at the time of fetch.
        XCTAssertEqual(outList.read(channel: 0, count: 6), [7, 8, 9, 10, 0, 0])
    }

    // MARK: - Wrap-around

    func testWrapAroundAtCapacityBoundary() {
        // Capacity 8, alternate store/fetch in chunks of 5 — the second store
        // straddles the modulo boundary at index 8.
        let ring = RingBuffer(channelCount: 1, capacityFrames: 8)

        let in1 = TestBufferList(channels: 1, frameCapacity: 16)
        in1.write(channel: 0, values: [1, 2, 3, 4, 5])
        ring.store(in1.pointer, frameCount: 5)

        let out1 = TestBufferList(channels: 1, frameCapacity: 16)
        ring.fetch(out1.pointer, frameCount: 5)
        XCTAssertEqual(out1.read(channel: 0, count: 5), [1, 2, 3, 4, 5])

        let in2 = TestBufferList(channels: 1, frameCapacity: 16)
        in2.write(channel: 0, values: [6, 7, 8, 9, 10])
        ring.store(in2.pointer, frameCount: 5)

        let out2 = TestBufferList(channels: 1, frameCapacity: 16)
        ring.fetch(out2.pointer, frameCount: 5)
        XCTAssertEqual(out2.read(channel: 0, count: 5), [6, 7, 8, 9, 10])
    }

    // MARK: - Multi-channel

    func testMultiChannelIndependence() {
        let ring = RingBuffer(channelCount: 2, capacityFrames: 16)

        let inList = TestBufferList(channels: 2, frameCapacity: 16)
        inList.write(channel: 0, values: [1, 2, 3])
        inList.write(channel: 1, values: [-1, -2, -3])
        ring.store(inList.pointer, frameCount: 3)

        let outList = TestBufferList(channels: 2, frameCapacity: 16)
        ring.fetch(outList.pointer, frameCount: 3)

        XCTAssertEqual(outList.read(channel: 0, count: 3), [1, 2, 3])
        XCTAssertEqual(outList.read(channel: 1, count: 3), [-1, -2, -3])
    }

    // MARK: - Sequential pipelining

    func testMultipleStoreFetchCyclesPreserveOrder() {
        let ring = RingBuffer(channelCount: 1, capacityFrames: 16)
        var expected: [Float] = []
        for cycle in 0..<5 {
            let chunk: [Float] = (0..<4).map { Float(cycle * 4 + $0) }
            let inList = TestBufferList(channels: 1, frameCapacity: 16)
            inList.write(channel: 0, values: chunk)
            ring.store(inList.pointer, frameCount: 4)

            let outList = TestBufferList(channels: 1, frameCapacity: 16)
            ring.fetch(outList.pointer, frameCount: 4)
            expected.append(contentsOf: chunk)

            XCTAssertEqual(outList.read(channel: 0, count: 4), chunk,
                           "Cycle \(cycle) returned wrong frames")
        }
    }
}

/// Heap-allocated AudioBufferList wrapper used to drive `RingBuffer.store` /
/// `fetch` from tests. Owns its channel memory and frees it on deinit.
private final class TestBufferList {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private let listPtr: UnsafeMutableAudioBufferListPointer
    private let channelBuffers: [UnsafeMutablePointer<Float>]
    private let frameCapacity: Int

    init(channels: Int, frameCapacity: Int) {
        self.frameCapacity = frameCapacity
        self.listPtr = AudioBufferList.allocate(maximumBuffers: channels)
        self.pointer = listPtr.unsafeMutablePointer

        var channelPointers: [UnsafeMutablePointer<Float>] = []
        for i in 0..<channels {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: frameCapacity)
            buf.initialize(repeating: 0, count: frameCapacity)
            channelPointers.append(buf)
            listPtr[i] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCapacity * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(buf)
            )
        }
        self.channelBuffers = channelPointers
    }

    deinit {
        for buf in channelBuffers {
            buf.deinitialize(count: frameCapacity)
            buf.deallocate()
        }
        listPtr.unsafeMutablePointer.deallocate()
    }

    func write(channel: Int, values: [Float]) {
        let buf = channelBuffers[channel]
        for (i, v) in values.enumerated() where i < frameCapacity {
            buf[i] = v
        }
    }

    func read(channel: Int, count: Int) -> [Float] {
        let buf = channelBuffers[channel]
        return (0..<min(count, frameCapacity)).map { buf[$0] }
    }
}
