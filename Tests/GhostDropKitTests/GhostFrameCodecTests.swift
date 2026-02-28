import Foundation
import Testing
@testable import GhostDropKit

@Suite("GhostFrameCodec")
struct GhostFrameCodecTests {
    @Test("Round-trips all frame variants")
    func roundTripKnownFrames() throws {
        let codec = GhostFrameCodec()

        let hello = HandshakeHelloPayload(
            sessionID: UUID(),
            deviceID: DeviceID(),
            ephemeralPublicKey: Data([1, 2, 3, 4]),
            nonce: Data([9, 8, 7, 6]),
            capabilities: GhostCapabilities(supportsL2CAP: true, maxChunk: 180, maxWindow: 16)
        )

        let frames: [GhostFrame] = [
            .hello(hello),
            .helloAck(HandshakeHelloAckPayload(sessionID: hello.sessionID, ephemeralPublicKey: Data([5, 6]), nonce: Data([7, 8]))),
            .verify(VerificationPayload(transcriptHash: Data(repeating: 0xAA, count: 32), sasCode: "123456")),
            .verifyAck(true),
            .metadata(FileMetadata(transferID: UUID(), filename: "sample.txt", size: 1024, mimeType: "text/plain", sha256: Data(repeating: 0x11, count: 32), chunkSize: 128)),
            .data(sequence: 42, payload: Data(repeating: 0xEE, count: 512)),
            .ack(GhostAck(cumulativeSequence: 41, nackBitmap: 0b1010)),
            .resume(GhostResumeRequest(transferID: UUID(), lastConfirmedSequence: 32)),
            .complete(TransferCompletePayload(transferID: UUID(), sha256: Data(repeating: 0x22, count: 32))),
            .cancel(reason: "cancelled"),
            .ping(777),
            .encrypted(sequence: 5, combined: Data(repeating: 0x33, count: 24))
        ]

        for frame in frames {
            let encoded = try codec.encode(frame)
            let decoded = try codec.decode(encoded)
            #expect(decoded == frame)
        }
    }

    @Test("Consumes concatenated stream frames")
    func streamDecode() throws {
        let codec = GhostFrameCodec()
        let input: [GhostFrame] = [
            .ping(1),
            .cancel(reason: "x"),
            .data(sequence: 7, payload: Data([1, 2, 3]))
        ]

        var buffer = Data()
        for frame in input {
            buffer.append(try codec.encode(frame))
        }

        let decoded = try codec.consumeFrames(from: &buffer)
        #expect(decoded == input)
        #expect(buffer.isEmpty)
    }

    @Test("Fuzz-ish random payload round-trip")
    func fuzzishRoundTrip() throws {
        let codec = GhostFrameCodec()

        for i in 0..<150 {
            let sequence = UInt64(i)
            let randomPayload = Data((0..<(i % 1024 + 1)).map { _ in UInt8.random(in: 0...255) })
            let frame = GhostFrame.data(sequence: sequence, payload: randomPayload)

            let encoded = try codec.encode(frame)
            let decoded = try codec.decode(encoded)
            #expect(decoded == frame)
        }
    }
}
