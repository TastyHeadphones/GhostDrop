import CryptoKit
import Foundation

public actor SessionCryptoContext {
    private let codec = GhostFrameCodec()

    private let sendEncKey: SymmetricKey
    private let receiveEncKey: SymmetricKey
    private let macKey: SymmetricKey
    private let sendNoncePrefix: Data
    private let receiveNoncePrefix: Data

    private var sendSequence: UInt64 = 0

    public init(secrets: HandshakeSecrets, role: SessionRole) {
        let baseEncKey = SymmetricKey(data: secrets.encKeyMaterial)
        self.macKey = SymmetricKey(data: secrets.macKeyMaterial)

        let senderKey = SessionCryptoContext.deriveDirectionalKey(baseKey: baseEncKey, label: "sender")
        let receiverKey = SessionCryptoContext.deriveDirectionalKey(baseKey: baseEncKey, label: "receiver")

        let senderPrefix = Data(SHA256.hash(data: Data("ghostdrop-sender".utf8))).prefix(4)
        let receiverPrefix = Data(SHA256.hash(data: Data("ghostdrop-receiver".utf8))).prefix(4)

        switch role {
        case .sender:
            self.sendEncKey = senderKey
            self.receiveEncKey = receiverKey
            self.sendNoncePrefix = Data(senderPrefix)
            self.receiveNoncePrefix = Data(receiverPrefix)
        case .receiver:
            self.sendEncKey = receiverKey
            self.receiveEncKey = senderKey
            self.sendNoncePrefix = Data(receiverPrefix)
            self.receiveNoncePrefix = Data(senderPrefix)
        }
    }

    /// Encrypts a control frame and wraps it as `.encrypted`.
    public func seal(_ frame: GhostFrame) throws -> GhostFrame {
        let plaintext = try codec.encode(frame)
        let nonce = try makeNonce(prefix: sendNoncePrefix, sequence: sendSequence)

        let sealed = try AES.GCM.seal(
            plaintext,
            using: sendEncKey,
            nonce: nonce,
            authenticating: sendSequence.bigEndianData
        )

        guard let combined = sealed.combined else {
            throw GhostError.encryptionFailure
        }

        let wrapped = GhostFrame.encrypted(sequence: sendSequence, combined: combined)
        sendSequence += 1
        return wrapped
    }

    /// Decrypts a wrapped control frame.
    public func open(_ frame: GhostFrame) throws -> GhostFrame {
        guard case let .encrypted(sequence, combined) = frame else {
            return frame
        }

        let expectedNonce = try makeNonce(prefix: receiveNoncePrefix, sequence: sequence)
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let expectedNonceData = expectedNonce.withUnsafeBytes { Data($0) }
        let receivedNonceData = sealedBox.nonce.withUnsafeBytes { Data($0) }
        guard receivedNonceData == expectedNonceData else {
            throw GhostError.decryptionFailure
        }
        let plaintext = try AES.GCM.open(
            sealedBox,
            using: receiveEncKey,
            authenticating: sequence.bigEndianData
        )
        return try codec.decode(plaintext)
    }

    /// Encrypts data chunk payload while preserving the outer `.data(sequence:...)` frame.
    public func sealDataPayload(sequence: UInt64, payload: Data) throws -> Data {
        let nonce = try makeNonce(prefix: sendNoncePrefix, sequence: sequence)
        let sealed = try AES.GCM.seal(
            payload,
            using: sendEncKey,
            nonce: nonce,
            authenticating: sequence.bigEndianData
        )

        guard let combined = sealed.combined else {
            throw GhostError.encryptionFailure
        }
        return combined
    }

    /// Decrypts data chunk payload from outer `.data(sequence:...)` frame.
    public func openDataPayload(sequence: UInt64, combined: Data) throws -> Data {
        let expectedNonce = try makeNonce(prefix: receiveNoncePrefix, sequence: sequence)
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let expectedNonceData = expectedNonce.withUnsafeBytes { Data($0) }
        let receivedNonceData = sealedBox.nonce.withUnsafeBytes { Data($0) }
        guard receivedNonceData == expectedNonceData else {
            throw GhostError.decryptionFailure
        }
        return try AES.GCM.open(
            sealedBox,
            using: receiveEncKey,
            authenticating: sequence.bigEndianData
        )
    }

    public func authenticate(_ frame: GhostFrame) throws -> Data {
        let encoded = try codec.encode(frame)
        let code = HMAC<SHA256>.authenticationCode(for: encoded, using: macKey)
        return Data(code)
    }

    public func verify(_ frame: GhostFrame, tag: Data) throws -> Bool {
        let encoded = try codec.encode(frame)
        let expected = HMAC<SHA256>.authenticationCode(for: encoded, using: macKey)
        return Data(expected) == tag
    }

    private static func deriveDirectionalKey(baseKey: SymmetricKey, label: String) -> SymmetricKey {
        let keyData = baseKey.withUnsafeBytes { Data($0) }
        let salt = Data("ghostdrop-directional".utf8)
        let info = Data(label.utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyData),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    private func makeNonce(prefix: Data, sequence: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(prefix)
        bytes.append(sequence.bigEndianData)
        return try AES.GCM.Nonce(data: bytes)
    }
}

private extension UInt64 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
