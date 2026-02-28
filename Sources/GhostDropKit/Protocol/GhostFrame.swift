import Foundation

public struct HandshakeHelloPayload: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let deviceID: DeviceID
    public let ephemeralPublicKey: Data
    public let nonce: Data
    public let capabilities: GhostCapabilities

    public init(
        sessionID: UUID,
        deviceID: DeviceID,
        ephemeralPublicKey: Data,
        nonce: Data,
        capabilities: GhostCapabilities
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.capabilities = capabilities
    }
}

public struct HandshakeHelloAckPayload: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let ephemeralPublicKey: Data
    public let nonce: Data

    public init(sessionID: UUID, ephemeralPublicKey: Data, nonce: Data) {
        self.sessionID = sessionID
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }
}

public struct VerificationPayload: Codable, Hashable, Sendable {
    public let transcriptHash: Data
    public let sasCode: String

    public init(transcriptHash: Data, sasCode: String) {
        self.transcriptHash = transcriptHash
        self.sasCode = sasCode
    }
}

public struct TransferCompletePayload: Codable, Hashable, Sendable {
    public let transferID: UUID
    public let sha256: Data

    public init(transferID: UUID, sha256: Data) {
        self.transferID = transferID
        self.sha256 = sha256
    }
}

public enum GhostFrame: Hashable, Sendable {
    case hello(HandshakeHelloPayload)
    case helloAck(HandshakeHelloAckPayload)
    case verify(VerificationPayload)
    case verifyAck(Bool)
    case metadata(FileMetadata)
    case data(sequence: UInt64, payload: Data)
    case ack(GhostAck)
    case resume(GhostResumeRequest)
    case complete(TransferCompletePayload)
    case cancel(reason: String)
    case ping(UInt32)
    case encrypted(sequence: UInt64, combined: Data)
}

public enum GhostFrameKind: UInt8, Sendable {
    case hello = 0x01
    case helloAck = 0x02
    case verify = 0x03
    case verifyAck = 0x04
    case metadata = 0x05
    case data = 0x06
    case ack = 0x07
    case resume = 0x08
    case complete = 0x09
    case cancel = 0x0A
    case ping = 0x0B
    case encrypted = 0x0C
}
