import CryptoKit
import Foundation

public actor IncomingTransferStore {
    private let fileManager: FileManager
    private let baseDirectory: URL

    public init(fileManager: FileManager = .default, baseDirectory: URL? = nil) throws {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.baseDirectory = appSupport.appendingPathComponent("GhostDrop/Incoming", isDirectory: true)
        }
        try Self.ensureBaseDirectory(fileManager: fileManager, at: self.baseDirectory)
    }

    public func prepareTransfer(_ metadata: FileMetadata) throws -> URL {
        let folder = transferDirectory(for: metadata.transferID)
        if !fileManager.fileExists(atPath: folder.path()) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let fileURL = folder.appendingPathComponent(metadata.filename)
        if !fileManager.fileExists(atPath: fileURL.path()) {
            fileManager.createFile(atPath: fileURL.path(), contents: nil)
        }
        return fileURL
    }

    public func appendChunk(
        transferID: UUID,
        fileName: String,
        payload: Data,
        expectedOffset: UInt64
    ) throws {
        let fileURL = transferDirectory(for: transferID).appendingPathComponent(fileName)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: expectedOffset)
        try handle.write(contentsOf: payload)
    }

    public func fileURL(transferID: UUID, fileName: String) -> URL {
        transferDirectory(for: transferID).appendingPathComponent(fileName)
    }

    public func finalize(transferID: UUID, fileName: String) throws -> Data {
        let data = try Data(contentsOf: fileURL(transferID: transferID, fileName: fileName))
        return Data(SHA256.hash(data: data))
    }

    private func transferDirectory(for transferID: UUID) -> URL {
        baseDirectory.appendingPathComponent(transferID.uuidString, isDirectory: true)
    }

    private static func ensureBaseDirectory(fileManager: FileManager, at directory: URL) throws {
        guard !fileManager.fileExists(atPath: directory.path()) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
