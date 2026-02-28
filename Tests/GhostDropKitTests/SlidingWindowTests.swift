import Foundation
import Testing
@testable import GhostDropKit

@Suite("GATT Sliding Window")
struct SlidingWindowTests {
    @Test("Advances with cumulative ACK")
    func cumulativeAck() {
        let clock = ContinuousClock()
        var window = GATTSlidingWindow(windowSize: 3)

        window.markSent(sequence: 1, encodedFrame: Data([1]), at: clock.now)
        window.markSent(sequence: 2, encodedFrame: Data([2]), at: clock.now)
        window.markSent(sequence: 3, encodedFrame: Data([3]), at: clock.now)

        #expect(window.canSend(sequence: 4) == false)

        let retransmit = window.processAck(GhostAck(cumulativeSequence: 2, nackBitmap: 0))
        #expect(retransmit.isEmpty)
        #expect(window.canSend(sequence: 4) == true)
        #expect(window.frameData(for: 3) != nil)
    }

    @Test("Returns NACKed sequences for retransmission")
    func nackBitmap() {
        let clock = ContinuousClock()
        var window = GATTSlidingWindow(windowSize: 8)

        for sequence in 10...14 {
            window.markSent(sequence: UInt64(sequence), encodedFrame: Data([UInt8(sequence)]), at: clock.now)
        }

        let bitmap: UInt64 = 0b101
        let retransmit = window.processAck(GhostAck(cumulativeSequence: 10, nackBitmap: bitmap))

        #expect(retransmit == [11, 13])
    }

    @Test("Timed-out frames are detected")
    func timeoutDetection() {
        let clock = ContinuousClock()
        var window = GATTSlidingWindow(windowSize: 4)
        let start = clock.now

        window.markSent(sequence: 1, encodedFrame: Data([1]), at: start)
        window.markSent(sequence: 2, encodedFrame: Data([2]), at: start)

        let timeout = Duration.seconds(2)
        let late = start.advanced(by: .seconds(3))
        let expired = window.timedOutSequences(now: late, timeout: timeout)

        #expect(expired == [1, 2])

        window.markRetransmitted(sequence: 2, at: late)
        let later = late.advanced(by: .seconds(1))
        let expiredAfterRetransmit = window.timedOutSequences(now: later, timeout: timeout)

        #expect(expiredAfterRetransmit == [1])
    }
}
