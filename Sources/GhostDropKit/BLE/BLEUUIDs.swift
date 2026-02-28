import Foundation

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

public enum GhostBLEUUIDs {
    public static let service = ServiceUUID(rawValue: UUID(uuidString: "BFA6E968-0F36-4888-8F63-C8EC01385E67")!)
    public static let data = CharacteristicUUID(rawValue: UUID(uuidString: "A0F2FA1D-F0E6-43F3-8B8A-642D7E6A0603")!)
    public static let control = CharacteristicUUID(rawValue: UUID(uuidString: "A0F2FA1D-F0E6-43F3-8B8A-642D7E6A0604")!)
    public static let capabilities = CharacteristicUUID(rawValue: UUID(uuidString: "A0F2FA1D-F0E6-43F3-8B8A-642D7E6A0605")!)

    #if canImport(CoreBluetooth)
    public static let serviceCBUUID = CBUUID(string: service.uuidString)
    public static let dataCBUUID = CBUUID(string: data.uuidString)
    public static let controlCBUUID = CBUUID(string: control.uuidString)
    public static let capabilitiesCBUUID = CBUUID(string: capabilities.uuidString)
    #endif
}

public struct BLEAdvertisementCapabilities: Codable, Hashable, Sendable {
    public let capabilities: GhostCapabilities
    public let psm: UInt16?

    public init(capabilities: GhostCapabilities, psm: UInt16?) {
        self.capabilities = capabilities
        self.psm = psm
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

#if canImport(CoreBluetooth)
public struct L2CAPStreamPair: @unchecked Sendable {
    public let inputStream: InputStream
    public let outputStream: OutputStream

    public init(inputStream: InputStream, outputStream: OutputStream) {
        self.inputStream = inputStream
        self.outputStream = outputStream
    }
}
#endif
