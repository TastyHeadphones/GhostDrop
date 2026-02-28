import Foundation

#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

#if canImport(CoreBluetooth)
public actor BLEPeripheralActor {
    private struct ReadEvent: @unchecked Sendable {
        let request: CBATTRequest
    }

    private struct WriteEvent: @unchecked Sendable {
        let requests: [CBATTRequest]
    }

    private struct L2CAPPublishEvent: Sendable {
        let psm: CBL2CAPPSM?
        let errorDescription: String?
    }

    private struct OpenChannelEvent: @unchecked Sendable {
        let channel: CBL2CAPChannel?
        let errorDescription: String?
    }

    private final class DelegateProxy: NSObject, CBPeripheralManagerDelegate {
        var onState: ((CBManagerState) -> Void)?
        var onRead: ((ReadEvent) -> Void)?
        var onWrite: ((WriteEvent) -> Void)?
        var onReady: (() -> Void)?
        var onDidSubscribe: ((CBCentral, CBCharacteristic) -> Void)?
        var onDidUnsubscribe: ((CBCentral, CBCharacteristic) -> Void)?
        var onPublishPSM: ((L2CAPPublishEvent) -> Void)?
        var onOpenChannel: ((OpenChannelEvent) -> Void)?

        func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
            onState?(peripheral.state)
        }

        func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
            onRead?(ReadEvent(request: request))
        }

        func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
            onWrite?(WriteEvent(requests: requests))
        }

        func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
            onReady?()
        }

        func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
            onDidSubscribe?(central, characteristic)
        }

        func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
            onDidUnsubscribe?(central, characteristic)
        }

        func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
            onPublishPSM?(L2CAPPublishEvent(psm: error == nil ? PSM : nil, errorDescription: error?.localizedDescription))
        }

        func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
            onOpenChannel?(OpenChannelEvent(channel: channel, errorDescription: error?.localizedDescription))
        }
    }

    private let logger: GhostLogger
    private let peripheral: CBPeripheralManager
    private let delegateProxy: DelegateProxy

    private var transferService: CBMutableService?
    private var dataCharacteristic: CBMutableCharacteristic?
    private var controlCharacteristic: CBMutableCharacteristic?
    private var capabilitiesCharacteristic: CBMutableCharacteristic?

    private var encodedCapabilities = Data()
    private var publishedPSM: CBL2CAPPSM?
    private var subscribedCentrals: [UUID: CBCentral] = [:]

    private var powerWaiters: [CheckedContinuation<Void, Error>] = []
    private var publishPSMWaiter: CheckedContinuation<PSM?, Error>?
    private var updateReadyWaiters: [CheckedContinuation<Void, Never>] = []

    private var writeContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var l2capContinuations: [UUID: AsyncStream<L2CAPStreamPair>.Continuation] = [:]

    public init(logger: GhostLogger = .shared) {
        self.logger = logger
        let proxy = DelegateProxy()
        self.delegateProxy = proxy
        self.peripheral = CBPeripheralManager(delegate: proxy, queue: nil)
        let actor = self

        proxy.onState = { state in
            Task { await actor.handleStateChanged(state) }
        }

        proxy.onRead = { event in
            Task { await actor.handleRead(event) }
        }

        proxy.onWrite = { event in
            Task { await actor.handleWrite(event) }
        }

        proxy.onReady = {
            Task { await actor.handleReadyToUpdate() }
        }

        proxy.onDidSubscribe = { central, characteristic in
            Task { await actor.handleSubscribe(central: central, characteristic: characteristic) }
        }

        proxy.onDidUnsubscribe = { central, characteristic in
            Task { await actor.handleUnsubscribe(central: central, characteristic: characteristic) }
        }

        proxy.onPublishPSM = { event in
            Task { await actor.handlePublishedPSM(event) }
        }

        proxy.onOpenChannel = { event in
            Task { await actor.handleOpenChannel(event) }
        }
    }

    public func waitUntilPoweredOn() async throws {
        switch peripheral.state {
        case .poweredOn:
            return
        case .unauthorized:
            throw GhostError.bluetoothUnauthorized
        case .unsupported:
            throw GhostError.bluetoothUnavailable
        case .poweredOff, .resetting, .unknown:
            try await withCheckedThrowingContinuation { continuation in
                powerWaiters.append(continuation)
            }
        @unknown default:
            throw GhostError.bluetoothUnavailable
        }
    }

    public func startAdvertising(capabilities: GhostCapabilities) async throws -> PSM? {
        try await waitUntilPoweredOn()

        let mutableService = makeService()
        self.transferService = mutableService

        peripheral.removeAllServices()
        peripheral.add(mutableService)

        let psm: PSM?
        if capabilities.supportsL2CAP {
            psm = try await publishL2CAPChannel()
        } else {
            psm = nil
        }

        let advertisement = BLEAdvertisementCapabilities(capabilities: capabilities, psm: psm.map { UInt16($0.rawValue) })
        encodedCapabilities = try advertisement.encoded()

        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [GhostBLEUUIDs.serviceCBUUID],
            CBAdvertisementDataServiceDataKey: [GhostBLEUUIDs.serviceCBUUID: encodedCapabilities],
            CBAdvertisementDataLocalNameKey: Host.current().localizedName ?? "GhostDrop"
        ])

        await logger.log(
            "Started advertising (L2CAP: \(psm != nil ? "yes" : "no"))",
            category: .ble,
            level: .notice
        )

        return psm
    }

    public func stopAdvertising() {
        peripheral.stopAdvertising()
        if let psm = publishedPSM {
            peripheral.unpublishL2CAPChannel(psm)
        }
        publishedPSM = nil
        peripheral.removeAllServices()
    }

    public func incomingWritePackets() -> AsyncStream<Data> {
        AsyncStream { continuation in
            let id = UUID()
            writeContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeWriteContinuation(id: id)
                }
            }
        }
    }

    public func incomingL2CAPChannels() -> AsyncStream<L2CAPStreamPair> {
        AsyncStream { continuation in
            let id = UUID()
            l2capContinuations[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeL2CAPContinuation(id: id)
                }
            }
        }
    }

    public func notifyPacket(_ packet: Data) async {
        guard let characteristic = dataCharacteristic else { return }

        let accepted = peripheral.updateValue(
            packet,
            for: characteristic,
            onSubscribedCentrals: nil
        )

        guard !accepted else { return }

        await withCheckedContinuation { continuation in
            updateReadyWaiters.append(continuation)
        }

        _ = peripheral.updateValue(
            packet,
            for: characteristic,
            onSubscribedCentrals: nil
        )
    }

    private func removeWriteContinuation(id: UUID) {
        writeContinuations.removeValue(forKey: id)
    }

    private func removeL2CAPContinuation(id: UUID) {
        l2capContinuations.removeValue(forKey: id)
    }

    private func makeService() -> CBMutableService {
        let dataCharacteristic = CBMutableCharacteristic(
            type: GhostBLEUUIDs.dataCBUUID,
            properties: [.notify, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let controlCharacteristic = CBMutableCharacteristic(
            type: GhostBLEUUIDs.controlCBUUID,
            properties: [.notify, .write],
            value: nil,
            permissions: [.writeable]
        )

        let capabilitiesCharacteristic = CBMutableCharacteristic(
            type: GhostBLEUUIDs.capabilitiesCBUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )

        let service = CBMutableService(type: GhostBLEUUIDs.serviceCBUUID, primary: true)
        service.characteristics = [dataCharacteristic, controlCharacteristic, capabilitiesCharacteristic]

        self.dataCharacteristic = dataCharacteristic
        self.controlCharacteristic = controlCharacteristic
        self.capabilitiesCharacteristic = capabilitiesCharacteristic

        return service
    }

    private func publishL2CAPChannel() async throws -> PSM? {
        peripheral.publishL2CAPChannel(withEncryption: true)
        return try await withCheckedThrowingContinuation { continuation in
            publishPSMWaiter = continuation
        }
    }

    private func handleStateChanged(_ state: CBManagerState) {
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

    private func handleRead(_ event: ReadEvent) {
        if event.request.characteristic.uuid == GhostBLEUUIDs.capabilitiesCBUUID {
            event.request.value = encodedCapabilities
            peripheral.respond(to: event.request, withResult: .success)
        } else {
            peripheral.respond(to: event.request, withResult: .attributeNotFound)
        }
    }

    private func handleWrite(_ event: WriteEvent) {
        for request in event.requests {
            if let value = request.value {
                for continuation in writeContinuations.values {
                    continuation.yield(value)
                }
            }
        }

        for request in event.requests {
            peripheral.respond(to: request, withResult: .success)
        }
    }

    private func handleReadyToUpdate() {
        for waiter in updateReadyWaiters {
            waiter.resume()
        }
        updateReadyWaiters.removeAll()
    }

    private func handleSubscribe(central: CBCentral, characteristic: CBCharacteristic) {
        subscribedCentrals[central.identifier] = central
    }

    private func handleUnsubscribe(central: CBCentral, characteristic: CBCharacteristic) {
        subscribedCentrals.removeValue(forKey: central.identifier)
    }

    private func handlePublishedPSM(_ event: L2CAPPublishEvent) {
        if let description = event.errorDescription {
            publishPSMWaiter?.resume(throwing: GhostError.io(description))
            publishPSMWaiter = nil
            return
        }

        if let psm = event.psm {
            publishedPSM = psm
            publishPSMWaiter?.resume(returning: PSM(rawValue: CUnsignedShort(psm)))
            publishPSMWaiter = nil
        } else {
            publishPSMWaiter?.resume(returning: nil)
            publishPSMWaiter = nil
        }
    }

    private func handleOpenChannel(_ event: OpenChannelEvent) {
        if let description = event.errorDescription {
            Task {
                await logger.log(
                    "L2CAP channel open failed: \(description)",
                    category: .ble,
                    level: .error
                )
            }
            return
        }

        guard let channel = event.channel else { return }
        let pair = L2CAPStreamPair(inputStream: channel.inputStream, outputStream: channel.outputStream)
        for continuation in l2capContinuations.values {
            continuation.yield(pair)
        }
    }
}
#endif
