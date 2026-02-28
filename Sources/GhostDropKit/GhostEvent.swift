import Foundation

public struct GhostLogEntry: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let category: String
    public let level: String
    public let message: String
    public let metadata: [String: String]

    public init(
        timestamp: Date = Date(),
        category: String,
        level: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.metadata = metadata
    }

    public func asNDJSONLine() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self), let line = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return line
    }
}

public enum GhostEvent: Sendable {
    case stateChanged(SessionState)
    case nearbyDevicesUpdated([NearbyDevice])
    case connected(NearbyDevice)
    case transportSelected(TransportKind)
    case handshakeSAS(String)
    case verificationRequired
    case transferProgress(TransferProgress)
    case transferCompleted(fileName: String)
    case transferFailed(String)
    case log(GhostLogEntry)
}
