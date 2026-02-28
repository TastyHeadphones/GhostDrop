import Foundation

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

public actor L2CAPTransport: GhostTransport {
    public nonisolated let kind: TransportKind = .l2cap

    private let codec = GhostFrameCodec()

    private var inputStream: InputStream
    private var outputStream: OutputStream
    private var readLoopTask: Task<Void, Never>?
    private var started = false
    private var streamContinuations: [UUID: AsyncThrowingStream<GhostFrame, Error>.Continuation] = [:]

    public init(inputStream: InputStream, outputStream: OutputStream) {
        self.inputStream = inputStream
        self.outputStream = outputStream
    }

    #if canImport(CoreBluetooth)
    public init(channel: CBL2CAPChannel) {
        self.inputStream = channel.inputStream
        self.outputStream = channel.outputStream
    }
    #endif

    public func start() async throws {
        guard !started else { return }
        started = true
        inputStream.open()
        outputStream.open()

        readLoopTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    public func send(_ frame: GhostFrame) async throws {
        guard started else {
            throw GhostError.transportClosed
        }

        let encoded = try codec.encode(frame)
        try await writeAll(data: encoded)
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
        readLoopTask?.cancel()
        readLoopTask = nil
        inputStream.close()
        outputStream.close()

        for continuation in streamContinuations.values {
            continuation.finish()
        }
        streamContinuations.removeAll()
    }

    private func removeContinuation(id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }

    private func readLoop() async {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)

        while started, !Task.isCancelled {
            if inputStream.hasBytesAvailable {
                let count = inputStream.read(&scratch, maxLength: scratch.count)
                if count > 0 {
                    buffer.append(scratch, count: count)
                    do {
                        let frames = try codec.consumeFrames(from: &buffer)
                        for frame in frames {
                            emit(frame)
                        }
                    } catch {
                        emit(error: error)
                        return
                    }
                } else if count < 0 {
                    let message = inputStream.streamError?.localizedDescription ?? "stream read failed"
                    emit(error: GhostError.io(message))
                    return
                }
            }

            if !inputStream.hasBytesAvailable {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func writeAll(data: Data) async throws {
        var offset = 0
        let bytes = [UInt8](data)

        while offset < bytes.count {
            if Task.isCancelled {
                throw GhostError.cancelled
            }

            if !outputStream.hasSpaceAvailable {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }

            let remaining = bytes.count - offset
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return outputStream.write(baseAddress.advanced(by: offset), maxLength: remaining)
            }

            if written <= 0 {
                let message = outputStream.streamError?.localizedDescription ?? "stream write failed"
                throw GhostError.io(message)
            }

            offset += written
        }
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
}
