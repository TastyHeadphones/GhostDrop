import Foundation

public typealias GATTWriteHandler = @Sendable (_ packet: Data, _ requiresResponse: Bool) async throws -> Void
public typealias GATTFlowControlProbe = @Sendable () async -> Bool
public typealias GATTFlowControlWaiter = @Sendable () async -> Void

public actor GATTTransport: GhostTransport {
    private struct PartialFrame: Sendable {
        var flags: UInt8
        var fragmentCount: Int
        var fragments: [Int: Data]
        var updatedAt: ContinuousClock.Instant
    }

    private enum Constants {
        static let magic: [UInt8] = [0x47, 0x44] // GD
        static let headerLength = 11
        static let staleFrameTimeout: Duration = .seconds(10)
    }

    public nonisolated let kind: TransportKind = .gatt

    private let codec = GhostFrameCodec()
    private let writePacket: GATTWriteHandler
    private let canSendWithoutResponse: GATTFlowControlProbe
    private let waitForWriteWithoutResponse: GATTFlowControlWaiter
    private let maxPacketSize: Int
    private let retryInterval: Duration
    private let retryTimeout: Duration
    private let clock = ContinuousClock()

    private var started = false
    private var nextFrameID: UInt32 = 1
    private var reassembly: [UInt32: PartialFrame] = [:]
    private var window: GATTSlidingWindow
    private var retryTask: Task<Void, Never>?
    private var streamContinuations: [UUID: AsyncThrowingStream<GhostFrame, Error>.Continuation] = [:]

    public init(
        maxPacketSize: Int,
        windowSize: Int = 32,
        retryInterval: Duration = .milliseconds(200),
        retryTimeout: Duration = .seconds(2),
        writePacket: @escaping GATTWriteHandler,
        canSendWithoutResponse: @escaping GATTFlowControlProbe = { true },
        waitForWriteWithoutResponse: @escaping GATTFlowControlWaiter = {}
    ) {
        self.maxPacketSize = max(maxPacketSize, 40)
        self.window = GATTSlidingWindow(windowSize: windowSize)
        self.retryInterval = retryInterval
        self.retryTimeout = retryTimeout
        self.writePacket = writePacket
        self.canSendWithoutResponse = canSendWithoutResponse
        self.waitForWriteWithoutResponse = waitForWriteWithoutResponse
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        let retryInterval = self.retryInterval
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: retryInterval)
                await self?.handleRetryTick()
            }
        }
    }

    public func send(_ frame: GhostFrame) async throws {
        guard started else {
            throw GhostError.transportClosed
        }

        if Task.isCancelled {
            throw GhostError.cancelled
        }

        let encoded = try codec.encode(frame)
        let isBulk = isBulkFrame(frame)
        let sequence = extractSequence(frame)

        if isBulk, let sequence {
            while !window.canSend(sequence: sequence) {
                if Task.isCancelled {
                    throw GhostError.cancelled
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        let frameID = makeFrameID()
        let fragments = makeFragments(frameID: frameID, encodedFrame: encoded, control: !isBulk)

        if isBulk {
            for fragment in fragments {
                while !(await canSendWithoutResponse()) {
                    if Task.isCancelled {
                        throw GhostError.cancelled
                    }
                    await waitForWriteWithoutResponse()
                }
                try await writePacket(fragment, false)
            }

            if let sequence {
                window.markSent(sequence: sequence, encodedFrame: encoded, at: clock.now)
            }
        } else {
            for fragment in fragments {
                try await writePacket(fragment, true)
            }
        }
    }

    public func receivePacket(_ packet: Data) async throws {
        let parsed = try parseHeader(packet)

        var partial = reassembly[parsed.frameID] ?? PartialFrame(
            flags: parsed.flags,
            fragmentCount: parsed.fragmentCount,
            fragments: [:],
            updatedAt: clock.now
        )

        partial.fragments[parsed.fragmentIndex] = parsed.payload
        partial.updatedAt = clock.now
        reassembly[parsed.frameID] = partial

        guard partial.fragments.count == partial.fragmentCount else {
            cleanupReassemblyIfNeeded()
            return
        }

        reassembly.removeValue(forKey: parsed.frameID)

        var combined = Data()
        for index in 0..<partial.fragmentCount {
            guard let fragment = partial.fragments[index] else {
                throw GhostError.frameDecodingFailed
            }
            combined.append(fragment)
        }

        let frame = try codec.decode(combined)
        if case let .ack(ack) = frame {
            try await handleAck(ack)
        }
        emit(frame)
    }

    public func frames() -> AsyncThrowingStream<GhostFrame, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            streamContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
    }

    public func close() async {
        started = false
        retryTask?.cancel()
        retryTask = nil
        for continuation in streamContinuations.values {
            continuation.finish()
        }
        streamContinuations.removeAll()
        reassembly.removeAll()
    }

    private func removeContinuation(id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }

    private func emit(_ frame: GhostFrame) {
        for continuation in streamContinuations.values {
            continuation.yield(frame)
        }
    }

    private func emit(error: Error) {
        for continuation in streamContinuations.values {
            continuation.finish(throwing: error)
        }
        streamContinuations.removeAll()
    }

    private func handleRetryTick() async {
        guard started else { return }

        let timedOut = window.timedOutSequences(now: clock.now, timeout: retryTimeout)
        guard !timedOut.isEmpty else { return }

        for sequence in timedOut {
            guard let encoded = frameData(sequence: sequence) else { continue }
            do {
                try await retransmit(sequence: sequence, encodedFrame: encoded)
            } catch {
                emitRetryError(error)
                return
            }
        }
    }

    private func emitRetryError(_ error: Error) {
        emit(error: error)
    }

    private func frameData(sequence: UInt64) -> Data? {
        window.frameData(for: sequence)
    }

    private func handleAck(_ ack: GhostAck) async throws {
        let retransmitSequences = window.processAck(ack)
        guard !retransmitSequences.isEmpty else { return }

        for sequence in retransmitSequences {
            guard let encoded = window.frameData(for: sequence) else { continue }
            try await retransmit(sequence: sequence, encodedFrame: encoded)
        }
    }

    private func retransmit(sequence: UInt64, encodedFrame: Data) async throws {
        let frameID = makeFrameID()
        let fragments = makeFragments(frameID: frameID, encodedFrame: encodedFrame, control: false)

        for fragment in fragments {
            while !(await canSendWithoutResponse()) {
                await waitForWriteWithoutResponse()
            }
            try await writePacket(fragment, false)
        }

        window.markRetransmitted(sequence: sequence, at: clock.now)
    }

    private func makeFrameID() -> UInt32 {
        defer {
            nextFrameID &+= 1
            if nextFrameID == 0 {
                nextFrameID = 1
            }
        }
        return nextFrameID
    }

    private func isBulkFrame(_ frame: GhostFrame) -> Bool {
        switch frame {
        case .data:
            return true
        default:
            return false
        }
    }

    private func extractSequence(_ frame: GhostFrame) -> UInt64? {
        switch frame {
        case let .data(sequence, _):
            return sequence
        default:
            return nil
        }
    }

    private func makeFragments(frameID: UInt32, encodedFrame: Data, control: Bool) -> [Data] {
        let payloadCapacity = maxPacketSize - Constants.headerLength
        let count = max(1, Int(ceil(Double(encodedFrame.count) / Double(payloadCapacity))))

        var fragments: [Data] = []
        fragments.reserveCapacity(count)

        for index in 0..<count {
            let start = index * payloadCapacity
            let end = min(start + payloadCapacity, encodedFrame.count)
            let chunk = encodedFrame[start..<end]

            var packet = Data(Constants.magic)
            packet.append(contentsOf: frameID.bigEndianBytes)
            packet.append(contentsOf: UInt16(index).bigEndianBytes)
            packet.append(contentsOf: UInt16(count).bigEndianBytes)
            packet.append(control ? 0x01 : 0x00)
            packet.append(chunk)
            fragments.append(packet)
        }

        return fragments
    }

    private func parseHeader(_ packet: Data) throws -> (
        frameID: UInt32,
        fragmentIndex: Int,
        fragmentCount: Int,
        flags: UInt8,
        payload: Data
    ) {
        guard packet.count >= Constants.headerLength else {
            throw GhostError.frameDecodingFailed
        }

        let magic = Array(packet.prefix(2))
        guard magic == Constants.magic else {
            throw GhostError.frameDecodingFailed
        }

        let frameID = UInt32(bigEndianBytes: dataSlice(packet, offset: 2, length: 4))
        let fragmentIndex = Int(UInt16(bigEndianBytes: dataSlice(packet, offset: 6, length: 2)))
        let fragmentCount = Int(UInt16(bigEndianBytes: dataSlice(packet, offset: 8, length: 2)))
        let flagIndex = packet.index(packet.startIndex, offsetBy: 10)
        let flags = packet[flagIndex]
        let payload = Data(packet.dropFirst(Constants.headerLength))

        guard fragmentCount > 0, fragmentIndex < fragmentCount else {
            throw GhostError.frameDecodingFailed
        }

        return (frameID, fragmentIndex, fragmentCount, flags, payload)
    }

    private func cleanupReassemblyIfNeeded() {
        let now = clock.now
        reassembly = reassembly.filter { _, partial in
            partial.updatedAt.duration(to: now) < Constants.staleFrameTimeout
        }
    }
}

private func dataSlice(_ data: Data, offset: Int, length: Int) -> Data.SubSequence {
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(start, offsetBy: length)
    return data[start..<end]
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }

    init(bigEndianBytes bytes: Data.SubSequence) {
        self = bytes.prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }

    init(bigEndianBytes bytes: Data.SubSequence) {
        self = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
