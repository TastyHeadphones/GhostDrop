import Foundation
import Testing
@testable import GhostDropKit

@Suite("Resume Store")
struct ResumeStoreTests {
    @Test("Save and load resume state")
    func saveLoadDelete() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostDropResumeTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let store = try ResumeStore(baseDirectory: base)

        let transferID = UUID()
        let stableDate = Date(timeIntervalSince1970: 1_750_000_000)
        let state = TransferResumeState(
            transferID: transferID,
            fileName: "movie.mov",
            fileSize: 99_000,
            sha256Hex: "abc123",
            chunkSize: 256,
            lastConfirmedSequence: 77,
            updatedAt: stableDate
        )

        try await store.save(state)
        let loaded = try await store.load(transferID: transferID)

        #expect(loaded == state)

        try await store.delete(transferID: transferID)
        let deleted = try await store.load(transferID: transferID)
        #expect(deleted == nil)
    }
}
