import Foundation

public struct FileMetadata: Codable, Hashable, Sendable {
    public let transferID: UUID
    public let filename: String
    public let size: Int64
    public let mimeType: String
    public let sha256: Data
    public let chunkSize: Int

    public init(
        transferID: UUID,
        filename: String,
        size: Int64,
        mimeType: String,
        sha256: Data,
        chunkSize: Int
    ) {
        self.transferID = transferID
        self.filename = filename
        self.size = size
        self.mimeType = mimeType
        self.sha256 = sha256
        self.chunkSize = chunkSize
    }
}

public struct GhostAck: Codable, Hashable, Sendable {
    public let cumulativeSequence: UInt64
    public let nackBitmap: UInt64

    public init(cumulativeSequence: UInt64, nackBitmap: UInt64 = 0) {
        self.cumulativeSequence = cumulativeSequence
        self.nackBitmap = nackBitmap
    }
}

public struct GhostResumeRequest: Codable, Hashable, Sendable {
    public let transferID: UUID
    public let lastConfirmedSequence: UInt64

    public init(transferID: UUID, lastConfirmedSequence: UInt64) {
        self.transferID = transferID
        self.lastConfirmedSequence = lastConfirmedSequence
    }
}
