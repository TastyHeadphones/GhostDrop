import Foundation

public enum SessionState: String, Codable, Sendable {
    case idle
    case advertising
    case scanning
    case connecting
    case negotiating
    case verifying
    case transferring
    case completed
    case failed
    case cancelled
}
