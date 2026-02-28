import Foundation

public struct GhostFrameCodec: Sendable {
    private static let magic: [UInt8] = [0x47, 0x48, 0x53, 0x54] // GHST
    private static let headerLength = 10
    private static let version: UInt8 = 1

    public init() {}

    public func encode(_ frame: GhostFrame) throws -> Data {
        let envelope = try GhostFrameEnvelope(frame: frame)
        let body = try JSONEncoder().encode(envelope.payload)

        var data = Data(Self.magic)
        data.append(Self.version)
        data.append(envelope.kind.rawValue)
        data.append(contentsOf: UInt32(body.count).bigEndianBytes)
        data.append(body)
        return data
    }

    public func decode(_ data: Data) throws -> GhostFrame {
        guard data.count >= Self.headerLength else {
            throw GhostError.frameDecodingFailed
        }

        let magic = Array(data.prefix(4))
        guard magic == Self.magic else {
            throw GhostError.frameDecodingFailed
        }

        let version = data[data.startIndex.advanced(by: 4)]
        guard version == Self.version else {
            throw GhostError.frameDecodingFailed
        }

        let kindRaw = data[data.startIndex.advanced(by: 5)]
        guard let kind = GhostFrameKind(rawValue: kindRaw) else {
            throw GhostError.frameDecodingFailed
        }

        let lengthSlice = dataSlice(data, offset: 6, length: 4)
        let bodyLength = Int(UInt32(bigEndianBytes: lengthSlice))
        let expectedCount = Self.headerLength + bodyLength
        guard data.count == expectedCount else {
            throw GhostError.frameDecodingFailed
        }

        let payloadData = data.suffix(bodyLength)
        let payload = try JSONDecoder().decode(GhostFrameEnvelope.Payload.self, from: payloadData)
        return try GhostFrameEnvelope.toFrame(kind: kind, payload: payload)
    }

    public func consumeFrames(from buffer: inout Data) throws -> [GhostFrame] {
        var frames: [GhostFrame] = []

        while buffer.count >= Self.headerLength {
            if Array(buffer.prefix(4)) != Self.magic {
                throw GhostError.frameDecodingFailed
            }

            let lengthSlice = dataSlice(buffer, offset: 6, length: 4)
            let bodyLength = Int(UInt32(bigEndianBytes: lengthSlice))
            let totalLength = Self.headerLength + bodyLength
            guard buffer.count >= totalLength else { break }

            let frameData = buffer.prefix(totalLength)
            frames.append(try decode(Data(frameData)))
            buffer.removeFirst(totalLength)
        }

        return frames
    }
}

private func dataSlice(_ data: Data, offset: Int, length: Int) -> Data.SubSequence {
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(start, offsetBy: length)
    return data[start..<end]
}

private struct GhostFrameEnvelope {
    struct Payload: Codable {
        var hello: HandshakeHelloPayload?
        var helloAck: HandshakeHelloAckPayload?
        var verify: VerificationPayload?
        var verifyAck: VerifyAckPayload?
        var metadata: FileMetadata?
        var dataPayload: DataPayload?
        var ack: GhostAck?
        var resume: GhostResumeRequest?
        var complete: TransferCompletePayload?
        var cancel: CancelPayload?
        var ping: PingPayload?
        var encrypted: EncryptedPayload?

        init() {}
    }

    struct VerifyAckPayload: Codable {
        let accepted: Bool
    }

    struct DataPayload: Codable {
        let sequence: UInt64
        let payload: Data
    }

    struct CancelPayload: Codable {
        let reason: String
    }

    struct PingPayload: Codable {
        let id: UInt32
    }

    struct EncryptedPayload: Codable {
        let sequence: UInt64
        let combined: Data
    }

    let kind: GhostFrameKind
    let payload: Payload

    init(frame: GhostFrame) throws {
        var payload = Payload()

        switch frame {
        case let .hello(value):
            kind = .hello
            payload.hello = value
        case let .helloAck(value):
            kind = .helloAck
            payload.helloAck = value
        case let .verify(value):
            kind = .verify
            payload.verify = value
        case let .verifyAck(accepted):
            kind = .verifyAck
            payload.verifyAck = VerifyAckPayload(accepted: accepted)
        case let .metadata(meta):
            kind = .metadata
            payload.metadata = meta
        case let .data(sequence, packet):
            kind = .data
            payload.dataPayload = DataPayload(sequence: sequence, payload: packet)
        case let .ack(ack):
            kind = .ack
            payload.ack = ack
        case let .resume(request):
            kind = .resume
            payload.resume = request
        case let .complete(complete):
            kind = .complete
            payload.complete = complete
        case let .cancel(reason):
            kind = .cancel
            payload.cancel = CancelPayload(reason: reason)
        case let .ping(id):
            kind = .ping
            payload.ping = PingPayload(id: id)
        case let .encrypted(sequence, combined):
            kind = .encrypted
            payload.encrypted = EncryptedPayload(sequence: sequence, combined: combined)
        }

        self.payload = payload
    }

    static func toFrame(kind: GhostFrameKind, payload: Payload) throws -> GhostFrame {
        switch kind {
        case .hello:
            guard let value = payload.hello else { throw GhostError.frameDecodingFailed }
            return .hello(value)
        case .helloAck:
            guard let value = payload.helloAck else { throw GhostError.frameDecodingFailed }
            return .helloAck(value)
        case .verify:
            guard let value = payload.verify else { throw GhostError.frameDecodingFailed }
            return .verify(value)
        case .verifyAck:
            guard let value = payload.verifyAck else { throw GhostError.frameDecodingFailed }
            return .verifyAck(value.accepted)
        case .metadata:
            guard let value = payload.metadata else { throw GhostError.frameDecodingFailed }
            return .metadata(value)
        case .data:
            guard let value = payload.dataPayload else { throw GhostError.frameDecodingFailed }
            return .data(sequence: value.sequence, payload: value.payload)
        case .ack:
            guard let value = payload.ack else { throw GhostError.frameDecodingFailed }
            return .ack(value)
        case .resume:
            guard let value = payload.resume else { throw GhostError.frameDecodingFailed }
            return .resume(value)
        case .complete:
            guard let value = payload.complete else { throw GhostError.frameDecodingFailed }
            return .complete(value)
        case .cancel:
            guard let value = payload.cancel else { throw GhostError.frameDecodingFailed }
            return .cancel(reason: value.reason)
        case .ping:
            guard let value = payload.ping else { throw GhostError.frameDecodingFailed }
            return .ping(value.id)
        case .encrypted:
            guard let value = payload.encrypted else { throw GhostError.frameDecodingFailed }
            return .encrypted(sequence: value.sequence, combined: value.combined)
        }
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }

    init(bigEndianBytes data: Data.SubSequence) {
        self = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
