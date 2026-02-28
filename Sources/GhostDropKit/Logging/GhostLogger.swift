import Foundation
import OSLog

public enum GhostLogCategory: String, Sendable {
    case ble
    case transport
    case protocolLayer = "protocol"
    case security
    case session
    case storage
    case ui
}

public enum GhostLogLevel: String, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

public actor GhostLogger {
    public static let shared = GhostLogger()

    private let subsystem = "com.ghostdrop.core"
    private var entries: [GhostLogEntry] = []

    public init() {}

    public func log(
        _ message: String,
        category: GhostLogCategory,
        level: GhostLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        let osLogger = Logger(subsystem: subsystem, category: category.rawValue)
        switch level {
        case .debug:
            osLogger.debug("\(message, privacy: .public)")
        case .info:
            osLogger.info("\(message, privacy: .public)")
        case .notice:
            osLogger.notice("\(message, privacy: .public)")
        case .warning:
            osLogger.warning("\(message, privacy: .public)")
        case .error:
            osLogger.error("\(message, privacy: .public)")
        }

        entries.append(
            GhostLogEntry(
                category: category.rawValue,
                level: level.rawValue,
                message: message,
                metadata: metadata
            )
        )

        if entries.count > 10_000 {
            entries.removeFirst(entries.count - 10_000)
        }
    }

    public func snapshot() -> [GhostLogEntry] {
        entries
    }

    public func exportNDJSON(to url: URL) throws {
        let body = entries.map { $0.asNDJSONLine() }.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
