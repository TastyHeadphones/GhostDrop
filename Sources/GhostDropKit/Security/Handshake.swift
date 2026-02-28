import CryptoKit
import Foundation

public struct HandshakeSecrets: Sendable {
    public let encKeyMaterial: Data
    public let macKeyMaterial: Data
    public let transcriptHash: Data

    public init(encKeyMaterial: Data, macKeyMaterial: Data, transcriptHash: Data) {
        self.encKeyMaterial = encKeyMaterial
        self.macKeyMaterial = macKeyMaterial
        self.transcriptHash = transcriptHash
    }
}

public enum Handshake {
    private static let protocolLabel = Data("GhostDrop-v1".utf8)
    private static let hkdfInfo = Data("GhostDrop Session Keys".utf8)

    public static func createHello(
        sessionID: UUID,
        deviceID: DeviceID,
        capabilities: GhostCapabilities
    ) throws -> (privateKey: P256.KeyAgreement.PrivateKey, hello: HandshakeHelloPayload) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let hello = HandshakeHelloPayload(
            sessionID: sessionID,
            deviceID: deviceID,
            ephemeralPublicKey: privateKey.publicKey.x963Representation,
            nonce: Self.randomNonce(length: 16),
            capabilities: capabilities
        )
        return (privateKey, hello)
    }

    public static func createHelloAck(
        sessionID: UUID
    ) throws -> (privateKey: P256.KeyAgreement.PrivateKey, helloAck: HandshakeHelloAckPayload) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let ack = HandshakeHelloAckPayload(
            sessionID: sessionID,
            ephemeralPublicKey: privateKey.publicKey.x963Representation,
            nonce: Self.randomNonce(length: 16)
        )
        return (privateKey, ack)
    }

    public static func deriveSecrets(
        localPrivateKey: P256.KeyAgreement.PrivateKey,
        localPublicKey: Data,
        localNonce: Data,
        remotePublicKey: Data,
        remoteNonce: Data,
        sessionID: UUID
    ) throws -> HandshakeSecrets {
        let remotePublic = try P256.KeyAgreement.PublicKey(x963Representation: remotePublicKey)
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remotePublic)

        let transcript = try transcriptData(
            localPublicKey: localPublicKey,
            localNonce: localNonce,
            remotePublicKey: remotePublicKey,
            remoteNonce: remoteNonce,
            sessionID: sessionID
        )
        let transcriptHash = Data(SHA256.hash(data: transcript))

        let material = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: hkdfInfo,
            outputByteCount: 64
        )

        let materialData = material.withUnsafeBytes { Data($0) }
        let encKeyMaterial = materialData.prefix(32)
        let macKeyMaterial = materialData.suffix(32)

        return HandshakeSecrets(
            encKeyMaterial: Data(encKeyMaterial),
            macKeyMaterial: Data(macKeyMaterial),
            transcriptHash: transcriptHash
        )
    }

    public static func deriveSASCode(transcriptHash: Data) -> String {
        let firstFour = transcriptHash.prefix(4)
        let value = firstFour.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let sixDigits = value % 1_000_000
        return String(format: "%06u", sixDigits)
    }

    public static func transcriptData(
        localPublicKey: Data,
        localNonce: Data,
        remotePublicKey: Data,
        remoteNonce: Data,
        sessionID: UUID
    ) throws -> Data {
        let peerA: (Data, Data)
        let peerB: (Data, Data)

        if localPublicKey.lexicographicallyPrecedes(remotePublicKey) {
            peerA = (localPublicKey, localNonce)
            peerB = (remotePublicKey, remoteNonce)
        } else {
            peerA = (remotePublicKey, remoteNonce)
            peerB = (localPublicKey, localNonce)
        }

        var data = Data()
        data.append(protocolLabel)
        data.append(contentsOf: sessionID.uuidBytes)
        data.append(peerA.0)
        data.append(peerA.1)
        data.append(peerB.0)
        data.append(peerB.1)
        return data
    }

    private static func randomNonce(length: Int) -> Data {
        Data((0..<length).map { _ in UInt8.random(in: .min ... .max) })
    }
}

private extension UUID {
    var uuidBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}
