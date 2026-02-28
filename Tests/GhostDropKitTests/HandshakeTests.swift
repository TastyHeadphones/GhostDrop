import CryptoKit
import Foundation
import Testing
@testable import GhostDropKit

@Suite("Handshake")
struct HandshakeTests {
    @Test("Transcript and SAS are deterministic across peers")
    func transcriptDeterminism() throws {
        let sessionID = UUID()
        let nonceA = Data(repeating: 0x01, count: 16)
        let nonceB = Data(repeating: 0x02, count: 16)

        let keyA = P256.KeyAgreement.PrivateKey()
        let keyB = P256.KeyAgreement.PrivateKey()

        let pubA = keyA.publicKey.x963Representation
        let pubB = keyB.publicKey.x963Representation

        let a = try Handshake.deriveSecrets(
            localPrivateKey: keyA,
            localPublicKey: pubA,
            localNonce: nonceA,
            remotePublicKey: pubB,
            remoteNonce: nonceB,
            sessionID: sessionID
        )

        let b = try Handshake.deriveSecrets(
            localPrivateKey: keyB,
            localPublicKey: pubB,
            localNonce: nonceB,
            remotePublicKey: pubA,
            remoteNonce: nonceA,
            sessionID: sessionID
        )

        #expect(a.transcriptHash == b.transcriptHash)
        #expect(a.encKeyMaterial == b.encKeyMaterial)
        #expect(a.macKeyMaterial == b.macKeyMaterial)
        #expect(Handshake.deriveSASCode(transcriptHash: a.transcriptHash) == Handshake.deriveSASCode(transcriptHash: b.transcriptHash))
    }

    @Test("Handshake hello carries capabilities")
    func helloPayloadIncludesCapabilities() throws {
        let capabilities = GhostCapabilities(supportsL2CAP: true, maxChunk: 256, maxWindow: 24)
        let tuple = try Handshake.createHello(sessionID: UUID(), deviceID: DeviceID(), capabilities: capabilities)

        #expect(tuple.hello.capabilities == capabilities)
        #expect(tuple.hello.ephemeralPublicKey.isEmpty == false)
        #expect(tuple.hello.nonce.count == 16)
    }
}
