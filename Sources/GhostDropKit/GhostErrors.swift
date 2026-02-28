import Foundation

public enum GhostError: Error, LocalizedError, Sendable {
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case invalidCapabilities
    case transportUnavailable
    case transportClosed
    case frameEncodingFailed
    case frameDecodingFailed
    case handshakeFailed(String)
    case verificationRejected
    case encryptionFailure
    case decryptionFailure
    case timeout(String)
    case io(String)
    case invalidStateTransition(from: SessionState, to: SessionState)
    case resumeStateMissing
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is unavailable on this device."
        case .bluetoothUnauthorized:
            return "Bluetooth permission has not been granted."
        case .invalidCapabilities:
            return "Device capabilities could not be parsed."
        case .transportUnavailable:
            return "No compatible transport was available."
        case .transportClosed:
            return "Transport is closed."
        case let .handshakeFailed(reason):
            return "Handshake failed: \(reason)."
        case .verificationRejected:
            return "User rejected Short Authentication String verification."
        case .encryptionFailure:
            return "Encryption failed."
        case .decryptionFailure:
            return "Decryption failed."
        case let .timeout(scope):
            return "Timed out while waiting for \(scope)."
        case let .io(message):
            return "I/O failed: \(message)."
        case let .invalidStateTransition(from, to):
            return "Invalid session state transition from \(from.rawValue) to \(to.rawValue)."
        case .resumeStateMissing:
            return "No resumable state was found for this transfer."
        case .frameEncodingFailed:
            return "Frame encoding failed."
        case .frameDecodingFailed:
            return "Frame decoding failed."
        case .cancelled:
            return "Operation cancelled."
        }
    }
}
