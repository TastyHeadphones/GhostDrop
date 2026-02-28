import Foundation

public struct TransferResumeState: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let fileName: String
    public let fileSize: Int64
    public let sha256Hex: String
    public let chunkSize: Int
    public let lastConfirmedSequence: UInt64
    public let updatedAt: Date

    public init(
        transferID: UUID,
        fileName: String,
        fileSize: Int64,
        sha256Hex: String,
        chunkSize: Int,
        lastConfirmedSequence: UInt64,
        updatedAt: Date = Date()
    ) {
        self.transferID = transferID
        self.fileName = fileName
        self.fileSize = fileSize
        self.sha256Hex = sha256Hex
        self.chunkSize = chunkSize
        self.lastConfirmedSequence = lastConfirmedSequence
        self.updatedAt = updatedAt
    }
}

public actor ResumeStore {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) throws {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.baseDirectory = appSupport.appendingPathComponent("GhostDrop/Resume", isDirectory: true)
        }

        try Self.createDirectoryIfNeeded(fileManager: fileManager, at: self.baseDirectory)
    }

    public func save(_ state: TransferResumeState) throws {
        let url = fileURL(for: state.transferID)
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    public func load(transferID: UUID) throws -> TransferResumeState? {
        let url = fileURL(for: transferID)
        guard fileManager.fileExists(atPath: url.path()) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(TransferResumeState.self, from: data)
    }

    public func loadAll() throws -> [TransferResumeState] {
        let contents = try fileManager.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        return try contents
            .filter { $0.pathExtension == "json" }
            .map { url in
                let data = try Data(contentsOf: url)
                return try decoder.decode(TransferResumeState.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(transferID: UUID) throws {
        let url = fileURL(for: transferID)
        guard fileManager.fileExists(atPath: url.path()) else { return }
        try fileManager.removeItem(at: url)
    }

    private static func createDirectoryIfNeeded(fileManager: FileManager, at directory: URL) throws {
        guard !fileManager.fileExists(atPath: directory.path()) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for transferID: UUID) -> URL {
        baseDirectory.appendingPathComponent("\(transferID.uuidString).json")
    }
}
