import Foundation
import Testing
@testable import GhostDropKit

@Suite("Crypto Context")
struct KeyDerivationTests {
    @Test("Control frame seal/open round-trip")
    func controlFrameRoundTrip() async throws {
        let secrets = HandshakeSecrets(
            encKeyMaterial: Data((0..<32).map(UInt8.init)),
            macKeyMaterial: Data((32..<64).map(UInt8.init)),
            transcriptHash: Data(repeating: 0xEF, count: 32)
        )

        let sender = SessionCryptoContext(secrets: secrets, role: .sender)
        let receiver = SessionCryptoContext(secrets: secrets, role: .receiver)

        let frame: GhostFrame = .metadata(
            FileMetadata(
                transferID: UUID(),
                filename: "file.bin",
                size: 44,
                mimeType: "application/octet-stream",
                sha256: Data(repeating: 0x9A, count: 32),
                chunkSize: 22
            )
        )

        let sealed = try await sender.seal(frame)
        let opened = try await receiver.open(sealed)
        #expect(opened == frame)
    }

    @Test("Data payload seal/open round-trip")
    func dataPayloadRoundTrip() async throws {
        let secrets = HandshakeSecrets(
            encKeyMaterial: Data((0..<32).map(UInt8.init)),
            macKeyMaterial: Data((32..<64).map(UInt8.init)),
            transcriptHash: Data(repeating: 0xCD, count: 32)
        )

        let sender = SessionCryptoContext(secrets: secrets, role: .sender)
        let receiver = SessionCryptoContext(secrets: secrets, role: .receiver)

        let payload = Data((0..<512).map { UInt8($0 % 251) })
        let sealed = try await sender.sealDataPayload(sequence: 9, payload: payload)
        let opened = try await receiver.openDataPayload(sequence: 9, combined: sealed)

        #expect(opened == payload)
    }
}
