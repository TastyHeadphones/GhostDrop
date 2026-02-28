import Foundation

public struct DeviceID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID

    public var id: UUID { rawValue }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

public struct PSM: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: CUnsignedShort

    public init(rawValue: CUnsignedShort) {
        self.rawValue = rawValue
    }
}

public struct ServiceUUID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var uuidString: String {
        rawValue.uuidString
    }
}

public struct CharacteristicUUID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var uuidString: String {
        rawValue.uuidString
    }
}

public struct GhostCapabilities: Codable, Hashable, Sendable {
    public let supportsL2CAP: Bool
    public let maxChunk: Int
    public let maxWindow: Int
    public let protocolVersion: Int

    public init(
        supportsL2CAP: Bool,
        maxChunk: Int = 180,
        maxWindow: Int = 32,
        protocolVersion: Int = 1
    ) {
        self.supportsL2CAP = supportsL2CAP
        self.maxChunk = maxChunk
        self.maxWindow = maxWindow
        self.protocolVersion = protocolVersion
    }

    public static let `default` = GhostCapabilities(supportsL2CAP: false)
}

public struct NearbyDevice: Hashable, Sendable, Identifiable {
    public let id: DeviceID
    public let displayName: String
    public let rssi: Int
    public let capabilities: GhostCapabilities
    public let l2capPSM: PSM?

    public init(
        id: DeviceID,
        displayName: String,
        rssi: Int,
        capabilities: GhostCapabilities,
        l2capPSM: PSM?
    ) {
        self.id = id
        self.displayName = displayName
        self.rssi = rssi
        self.capabilities = capabilities
        self.l2capPSM = l2capPSM
    }
}

public struct TransferProgress: Hashable, Sendable {
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let throughputBytesPerSecond: Double
    public let etaSeconds: Double?
    public let transport: TransportKind

    public init(
        bytesTransferred: Int64,
        totalBytes: Int64,
        throughputBytesPerSecond: Double,
        etaSeconds: Double?,
        transport: TransportKind
    ) {
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.throughputBytesPerSecond = throughputBytesPerSecond
        self.etaSeconds = etaSeconds
        self.transport = transport
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes)
    }
}

public enum SessionRole: String, Codable, Sendable {
    case sender
    case receiver
}

public enum TransportKind: String, Codable, Sendable {
    case l2cap
    case gatt
}

public struct HandshakeResult: Sendable {
    public let sasCode: String
    public let transcriptHash: Data

    public init(sasCode: String, transcriptHash: Data) {
        self.sasCode = sasCode
        self.transcriptHash = transcriptHash
    }
}
