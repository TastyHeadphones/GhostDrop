import Foundation

public struct GATTInflightFrame: Sendable {
    public var sequence: UInt64
    public var encodedFrame: Data
    public var sentAt: ContinuousClock.Instant
    public var retryCount: Int

    public init(
        sequence: UInt64,
        encodedFrame: Data,
        sentAt: ContinuousClock.Instant,
        retryCount: Int = 0
    ) {
        self.sequence = sequence
        self.encodedFrame = encodedFrame
        self.sentAt = sentAt
        self.retryCount = retryCount
    }
}

public struct GATTSlidingWindow: Sendable {
    public let windowSize: Int

    private(set) var inflight: [UInt64: GATTInflightFrame] = [:]

    public init(windowSize: Int) {
        self.windowSize = max(windowSize, 1)
    }

    public var inflightCount: Int {
        inflight.count
    }

    public func canSend(sequence: UInt64) -> Bool {
        if inflight[sequence] != nil {
            return true
        }
        return inflight.count < windowSize
    }

    public mutating func markSent(sequence: UInt64, encodedFrame: Data, at now: ContinuousClock.Instant) {
        inflight[sequence] = GATTInflightFrame(
            sequence: sequence,
            encodedFrame: encodedFrame,
            sentAt: now,
            retryCount: inflight[sequence]?.retryCount ?? 0
        )
    }

    public mutating func processAck(_ ack: GhostAck) -> [UInt64] {
        let cumulative = ack.cumulativeSequence

        let acked = inflight.keys.filter { $0 <= cumulative }
        for sequence in acked {
            inflight.removeValue(forKey: sequence)
        }

        var retransmit: [UInt64] = []
        guard ack.nackBitmap != 0 else {
            return retransmit.sorted()
        }

        for bit in 0..<64 {
            let mask = UInt64(1) << UInt64(bit)
            guard (ack.nackBitmap & mask) != 0 else { continue }

            let missingSequence = cumulative + 1 + UInt64(bit)
            if inflight[missingSequence] != nil {
                retransmit.append(missingSequence)
            }
        }

        return retransmit.sorted()
    }

    public mutating func timedOutSequences(
        now: ContinuousClock.Instant,
        timeout: Duration
    ) -> [UInt64] {
        inflight
            .values
            .filter { $0.sentAt.duration(to: now) >= timeout }
            .map(\.sequence)
            .sorted()
    }

    public mutating func markRetransmitted(sequence: UInt64, at now: ContinuousClock.Instant) {
        guard var frame = inflight[sequence] else { return }
        frame.sentAt = now
        frame.retryCount += 1
        inflight[sequence] = frame
    }

    public func frameData(for sequence: UInt64) -> Data? {
        inflight[sequence]?.encodedFrame
    }
}
