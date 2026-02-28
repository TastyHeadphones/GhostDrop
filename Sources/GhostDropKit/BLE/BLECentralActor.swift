import Foundation

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

#if canImport(CoreBluetooth)
public actor BLECentralActor {
    private struct PeripheralContext {
        var peripheral: CBPeripheral
        var lastRSSI: Int
        var displayName: String
        var advertisedCapabilities: BLEAdvertisementCapabilities?
        var dataCharacteristic: CBCharacteristic?
        var controlCharacteristic: CBCharacteristic?
        var capabilitiesCharacteristic: CBCharacteristic?
    }

    private struct DiscoveryEvent: @unchecked Sendable {
        let peripheral: CBPeripheral
        let advertisementData: [String: Any]
        let rssi: Int
    }

    private struct ConnectionEvent: @unchecked Sendable {
        let peripheral: CBPeripheral
        let error: Error?
    }

    private struct ServiceEvent: @unchecked Sendable {
        let peripheral: CBPeripheral
        let error: Error?
    }

    private struct CharacteristicEvent: @unchecked Sendable {
        let peripheral: CBPeripheral
        let service: CBService
        let error: Error?
    }

    private struct ValueEvent: @unchecked Sendable {
        let peripheral: CBPeripheral
        let characteristic: CBCharacteristic
        let error: Error?
    }

    private struct L2CAPEvent: @unchecked Sendable {
        let peripheral: CBPeripheral
        let channel: CBL2CAPChannel?
        let error: Error?
    }

    private final class DelegateProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
        var onState: ((CBManagerState) -> Void)?
        var onDiscover: ((DiscoveryEvent) -> Void)?
        var onConnect: ((ConnectionEvent) -> Void)?
        var onConnectFailure: ((ConnectionEvent) -> Void)?
        var onDisconnect: ((ConnectionEvent) -> Void)?
        var onServices: ((ServiceEvent) -> Void)?
        var onCharacteristics: ((CharacteristicEvent) -> Void)?
        var onValue: ((ValueEvent) -> Void)?
        var onWrite: ((ValueEvent) -> Void)?
        var onReadyWithoutResponse: ((CBPeripheral) -> Void)?
        var onL2CAP: ((L2CAPEvent) -> Void)?

        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            onState?(central.state)
        }

        func centralManager(
            _ central: CBCentralManager,
            didDiscover peripheral: CBPeripheral,
            advertisementData: [String: Any],
            rssi RSSI: NSNumber
        ) {
            onDiscover?(DiscoveryEvent(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI.intValue))
        }

        func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
            onConnect?(ConnectionEvent(peripheral: peripheral, error: nil))
        }

        func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
            onConnectFailure?(ConnectionEvent(peripheral: peripheral, error: error))
        }

        func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
            onDisconnect?(ConnectionEvent(peripheral: peripheral, error: error))
        }

        func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
            onServices?(ServiceEvent(peripheral: peripheral, error: error))
        }

        func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
            onCharacteristics?(CharacteristicEvent(peripheral: peripheral, service: service, error: error))
        }

        func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
            onValue?(ValueEvent(peripheral: peripheral, characteristic: characteristic, error: error))
        }

        func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
            onWrite?(ValueEvent(peripheral: peripheral, characteristic: characteristic, error: error))
        }

        func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
            onReadyWithoutResponse?(peripheral)
        }

        func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
            onL2CAP?(L2CAPEvent(peripheral: peripheral, channel: channel, error: error))
        }
    }

    private let logger: GhostLogger
    private let central: CBCentralManager
    private let delegateProxy: DelegateProxy

    private var peripheralContexts: [UUID: PeripheralContext] = [:]

    private var powerWaiters: [CheckedContinuation<Void, Error>] = []
    private var connectWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var discoveryWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var writeWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private var flowControlWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var l2capWaiters: [UUID: CheckedContinuation<L2CAPStreamPair, Error>] = [:]

    private var deviceContinuations: [UUID: AsyncStream<[NearbyDevice]>.Continuation] = [:]
    private var packetContinuations: [UUID: [UUID: AsyncStream<Data>.Continuation]] = [:]

    public init(logger: GhostLogger = .shared) {
        self.logger = logger
        let proxy = DelegateProxy()
        self.delegateProxy = proxy
        self.central = CBCentralManager(delegate: proxy, queue: nil)
        let actor = self

        proxy.onState = { state in
            Task {
                await actor.handleStateChanged(state)
            }
        }

        proxy.onDiscover = { event in
            Task {
                await actor.handleDiscovery(event)
            }
        }

        proxy.onConnect = { event in
            Task {
                await actor.handleConnected(event)
            }
        }

        proxy.onConnectFailure = { event in
            Task {
                await actor.handleConnectFailure(event)
            }
        }

        proxy.onDisconnect = { event in
            Task {
                await actor.handleDisconnect(event)
            }
        }

        proxy.onServices = { event in
            Task {
                await actor.handleServices(event)
            }
        }

        proxy.onCharacteristics = { event in
            Task {
                await actor.handleCharacteristics(event)
            }
        }

        proxy.onValue = { event in
            Task {
                await actor.handleValue(event)
            }
        }

        proxy.onWrite = { event in
            Task {
                await actor.handleWriteResult(event)
            }
        }

        proxy.onReadyWithoutResponse = { peripheral in
            Task {
                await actor.handleReadyWithoutResponse(peripheral)
            }
        }

        proxy.onL2CAP = { event in
            Task {
                await actor.handleL2CAP(event)
            }
        }
    }

    public func waitUntilPoweredOn() async throws {
        switch central.state {
        case .poweredOn:
            return
        case .unauthorized:
            throw GhostError.bluetoothUnauthorized
        case .poweredOff, .resetting, .unsupported, .unknown:
            return try await withCheckedThrowingContinuation { continuation in
                powerWaiters.append(continuation)
            }
        @unknown default:
            throw GhostError.bluetoothUnavailable
        }
    }

    public func startScanning() async throws {
        try await waitUntilPoweredOn()
        central.scanForPeripherals(withServices: [GhostBLEUUIDs.serviceCBUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        await logger.log("Started BLE scanning", category: .ble, level: .info)
    }

    public func stopScanning() {
        central.stopScan()
    }

    public func nearbyDevices() -> [NearbyDevice] {
        peripheralContexts.map { uuid, context in
            let advertised = context.advertisedCapabilities
            return NearbyDevice(
                id: DeviceID(rawValue: uuid),
                displayName: context.displayName,
                rssi: context.lastRSSI,
                capabilities: advertised?.capabilities ?? .default,
                l2capPSM: advertised?.psm.map { PSM(rawValue: CUnsignedShort($0)) }
            )
        }
        .sorted { $0.rssi > $1.rssi }
    }

    public func nearbyDeviceStream() -> AsyncStream<[NearbyDevice]> {
        AsyncStream { continuation in
            let id = UUID()
            deviceContinuations[id] = continuation
            continuation.yield(nearbyDevices())
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeNearbyContinuation(id: id)
                }
            }
        }
    }

    public func connect(to deviceID: DeviceID) async throws {
        guard let context = peripheralContexts[deviceID.rawValue] else {
            throw GhostError.transportUnavailable
        }

        context.peripheral.delegate = delegateProxy

        if context.peripheral.state == .connected {
            return
        }

        central.connect(context.peripheral)

        try await withCheckedThrowingContinuation { continuation in
            connectWaiters[deviceID.rawValue] = continuation
        }
    }

    public func discoverTransportCharacteristics(for deviceID: DeviceID) async throws {
        guard let context = peripheralContexts[deviceID.rawValue] else {
            throw GhostError.transportUnavailable
        }

        context.peripheral.delegate = delegateProxy
        context.peripheral.discoverServices([GhostBLEUUIDs.serviceCBUUID])

        try await withCheckedThrowingContinuation { continuation in
            discoveryWaiters[deviceID.rawValue] = continuation
        }
    }

    public func advertisedCapabilities(for deviceID: DeviceID) -> GhostCapabilities? {
        peripheralContexts[deviceID.rawValue]?.advertisedCapabilities?.capabilities
    }

    public func openL2CAP(to deviceID: DeviceID, psm: PSM) async throws -> L2CAPStreamPair {
        guard let context = peripheralContexts[deviceID.rawValue] else {
            throw GhostError.transportUnavailable
        }

        context.peripheral.openL2CAPChannel(psm.rawValue)

        return try await withCheckedThrowingContinuation { continuation in
            l2capWaiters[deviceID.rawValue] = continuation
        }
    }

    public func canSendWriteWithoutResponse(to deviceID: DeviceID) -> Bool {
        guard let peripheral = peripheralContexts[deviceID.rawValue]?.peripheral else {
            return false
        }
        return peripheral.canSendWriteWithoutResponse
    }

    public func waitForWriteWithoutResponseReady(to deviceID: DeviceID) async {
        guard let peripheral = peripheralContexts[deviceID.rawValue]?.peripheral else { return }
        if peripheral.canSendWriteWithoutResponse {
            return
        }

        await withCheckedContinuation { continuation in
            flowControlWaiters[deviceID.rawValue, default: []].append(continuation)
        }
    }

    public func writePacket(
        _ packet: Data,
        to deviceID: DeviceID,
        requiresResponse: Bool
    ) async throws {
        guard let context = peripheralContexts[deviceID.rawValue] else {
            throw GhostError.transportUnavailable
        }

        let target: CBCharacteristic?
        if requiresResponse {
            target = context.controlCharacteristic ?? context.dataCharacteristic
        } else {
            target = context.dataCharacteristic ?? context.controlCharacteristic
        }

        guard let characteristic = target else {
            throw GhostError.transportUnavailable
        }

        if requiresResponse {
            context.peripheral.writeValue(packet, for: characteristic, type: .withResponse)
            try await withCheckedThrowingContinuation { continuation in
                writeWaiters[deviceID.rawValue, default: []].append(continuation)
            }
        } else {
            context.peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
        }
    }

    public func incomingPackets(for deviceID: DeviceID) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let streamID = UUID()
            packetContinuations[deviceID.rawValue, default: [:]][streamID] = continuation

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removePacketContinuation(deviceID: deviceID, streamID: streamID)
                }
            }
        }
    }

    private func removeNearbyContinuation(id: UUID) {
        deviceContinuations.removeValue(forKey: id)
    }

    private func removePacketContinuation(deviceID: DeviceID, streamID: UUID) {
        packetContinuations[deviceID.rawValue]?.removeValue(forKey: streamID)
        if packetContinuations[deviceID.rawValue]?.isEmpty == true {
            packetContinuations.removeValue(forKey: deviceID.rawValue)
        }
    }

    private func publishNearbyDevices() {
        let devices = nearbyDevices()
        for continuation in deviceContinuations.values {
            continuation.yield(devices)
        }
    }

    private func handleStateChanged(_ state: CBManagerState) {
        Task {
            await logger.log("Central state changed: \(state.rawValue)", category: .ble, level: .debug)
        }

        switch state {
        case .poweredOn:
            for waiter in powerWaiters {
                waiter.resume()
            }
            powerWaiters.removeAll()
        case .unauthorized:
            for waiter in powerWaiters {
                waiter.resume(throwing: GhostError.bluetoothUnauthorized)
            }
            powerWaiters.removeAll()
        case .unsupported:
            for waiter in powerWaiters {
                waiter.resume(throwing: GhostError.bluetoothUnavailable)
            }
            powerWaiters.removeAll()
        default:
            break
        }
    }

    private func handleDiscovery(_ event: DiscoveryEvent) {
        let uuid = event.peripheral.identifier

        let advertisedCaps = parseAdvertisement(advertisementData: event.advertisementData)
        let existing = peripheralContexts[uuid]
        peripheralContexts[uuid] = PeripheralContext(
            peripheral: event.peripheral,
            lastRSSI: event.rssi,
            displayName: (event.advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? event.peripheral.name
                ?? existing?.displayName
                ?? "Unknown Device",
            advertisedCapabilities: advertisedCaps,
            dataCharacteristic: existing?.dataCharacteristic,
            controlCharacteristic: existing?.controlCharacteristic,
            capabilitiesCharacteristic: existing?.capabilitiesCharacteristic
        )

        publishNearbyDevices()
    }

    private func handleConnected(_ event: ConnectionEvent) {
        connectWaiters[event.peripheral.identifier]?.resume()
        connectWaiters.removeValue(forKey: event.peripheral.identifier)
    }

    private func handleConnectFailure(_ event: ConnectionEvent) {
        connectWaiters[event.peripheral.identifier]?.resume(
            throwing: event.error ?? GhostError.transportUnavailable
        )
        connectWaiters.removeValue(forKey: event.peripheral.identifier)
    }

    private func handleDisconnect(_ event: ConnectionEvent) {
        if let waiter = connectWaiters[event.peripheral.identifier] {
            waiter.resume(throwing: event.error ?? GhostError.transportClosed)
            connectWaiters.removeValue(forKey: event.peripheral.identifier)
        }
    }

    private func handleServices(_ event: ServiceEvent) {
        guard event.error == nil else {
            discoveryWaiters[event.peripheral.identifier]?.resume(throwing: event.error ?? GhostError.transportUnavailable)
            discoveryWaiters.removeValue(forKey: event.peripheral.identifier)
            return
        }

        guard let services = event.peripheral.services else {
            discoveryWaiters[event.peripheral.identifier]?.resume(throwing: GhostError.transportUnavailable)
            discoveryWaiters.removeValue(forKey: event.peripheral.identifier)
            return
        }

        for service in services where service.uuid == GhostBLEUUIDs.serviceCBUUID {
            event.peripheral.discoverCharacteristics(
                [GhostBLEUUIDs.dataCBUUID, GhostBLEUUIDs.controlCBUUID, GhostBLEUUIDs.capabilitiesCBUUID],
                for: service
            )
        }
    }

    private func handleCharacteristics(_ event: CharacteristicEvent) {
        guard event.error == nil else {
            discoveryWaiters[event.peripheral.identifier]?.resume(throwing: event.error ?? GhostError.transportUnavailable)
            discoveryWaiters.removeValue(forKey: event.peripheral.identifier)
            return
        }

        guard let characteristics = event.service.characteristics else {
            discoveryWaiters[event.peripheral.identifier]?.resume(throwing: GhostError.transportUnavailable)
            discoveryWaiters.removeValue(forKey: event.peripheral.identifier)
            return
        }

        var context = peripheralContexts[event.peripheral.identifier]
        for characteristic in characteristics {
            switch characteristic.uuid {
            case GhostBLEUUIDs.dataCBUUID:
                context?.dataCharacteristic = characteristic
                event.peripheral.setNotifyValue(true, for: characteristic)
            case GhostBLEUUIDs.controlCBUUID:
                context?.controlCharacteristic = characteristic
                event.peripheral.setNotifyValue(true, for: characteristic)
            case GhostBLEUUIDs.capabilitiesCBUUID:
                context?.capabilitiesCharacteristic = characteristic
            default:
                break
            }
        }
        if let context {
            peripheralContexts[event.peripheral.identifier] = context
        }

        discoveryWaiters[event.peripheral.identifier]?.resume()
        discoveryWaiters.removeValue(forKey: event.peripheral.identifier)
    }

    private func handleValue(_ event: ValueEvent) {
        if let error = event.error {
            if let continuations = packetContinuations[event.peripheral.identifier]?.values {
                for continuation in continuations {
                    continuation.finish()
                }
            }
            packetContinuations.removeValue(forKey: event.peripheral.identifier)
            Task {
                await logger.log(
                    "Characteristic update failed: \(error.localizedDescription)",
                    category: .ble,
                    level: .error
                )
            }
            return
        }

        guard let value = event.characteristic.value else { return }
        if let continuations = packetContinuations[event.peripheral.identifier]?.values {
            for continuation in continuations {
                continuation.yield(value)
            }
        }
    }

    private func handleWriteResult(_ event: ValueEvent) {
        let id = event.peripheral.identifier
        guard var waiters = writeWaiters[id], !waiters.isEmpty else { return }

        let waiter = waiters.removeFirst()
        writeWaiters[id] = waiters
        if waiters.isEmpty {
            writeWaiters.removeValue(forKey: id)
        }

        if let error = event.error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume()
        }
    }

    private func handleReadyWithoutResponse(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard let waiters = flowControlWaiters[id] else { return }
        for waiter in waiters {
            waiter.resume()
        }
        flowControlWaiters.removeValue(forKey: id)
    }

    private func handleL2CAP(_ event: L2CAPEvent) {
        let id = event.peripheral.identifier
        guard let waiter = l2capWaiters[id] else { return }
        l2capWaiters.removeValue(forKey: id)

        if let error = event.error {
            waiter.resume(throwing: error)
            return
        }

        guard let channel = event.channel else {
            waiter.resume(throwing: GhostError.transportUnavailable)
            return
        }

        waiter.resume(returning: L2CAPStreamPair(
            inputStream: channel.inputStream,
            outputStream: channel.outputStream
        ))
    }

    private func parseAdvertisement(advertisementData: [String: Any]) -> BLEAdvertisementCapabilities? {
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let raw = serviceData[GhostBLEUUIDs.serviceCBUUID],
           let decoded = try? BLEAdvertisementCapabilities.decode(raw) {
            return decoded
        }

        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           let decoded = try? BLEAdvertisementCapabilities.decode(manufacturer) {
            return decoded
        }

        return nil
    }
}
#endif
