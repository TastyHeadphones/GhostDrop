import Foundation
import GhostDropKit
import SwiftUI

#if canImport(CoreBluetooth)
import CoreBluetooth
#endif

@MainActor
final class MacAppViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case receive
        case send

        var id: String { rawValue }
    }

    @Published var mode: Mode = .receive
    @Published var state: SessionState = .idle
    @Published var nearbyDevices: [NearbyDevice] = []
    @Published var selectedFileURL: URL?
    @Published var progress: TransferProgress?
    @Published var logs: [GhostLogEntry] = []
    @Published var sasCode: String?
    @Published var showingPairing = false
    @Published var activeTransport: TransportKind?
    @Published var errorMessage: String?

    #if canImport(CoreBluetooth)
    private let central = BLECentralActor()
    private let peripheral = BLEPeripheralActor()
    #endif

    private var senderSession: SessionActor?
    private var receiverSession: SessionActor?

    private var senderEventTask: Task<Void, Never>?
    private var receiverEventTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    func setMode(_ newMode: Mode) {
        mode = newMode

        Task {
            switch newMode {
            case .receive:
                await startReceiveMode()
            case .send:
                await startSendMode()
            }
        }
    }

    func chooseFile() {
        if let url = MacOpenPanel.pickFile() {
            selectedFileURL = url
        }
    }

    func connect(to device: NearbyDevice) {
        Task {
            await connectAndPair(device)
        }
    }

    func confirmSAS(match: Bool) {
        Task {
            do {
                if mode == .send {
                    try await senderSession?.confirmSAS(matches: match)
                } else {
                    try await receiverSession?.confirmSAS(matches: match)
                }
                showingPairing = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func sendSelectedFile() {
        guard let selectedFileURL else {
            errorMessage = "Pick a file first."
            return
        }

        Task {
            do {
                try await senderSession?.sendFile(at: selectedFileURL, mimeType: "application/octet-stream")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportLogs() {
        Task {
            do {
                let destination = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads")
                    .appendingPathComponent("ghostdrop-macos-log.ndjson")
                try await senderSession?.exportLogsNDJSON(to: destination)
                try await receiverSession?.exportLogsNDJSON(to: destination)
                errorMessage = "Logs exported to \(destination.path)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startReceiveMode() async {
        teardownSender()

        do {
            let session = try SessionActor(role: .receiver, localCapabilities: .init(supportsL2CAP: true, maxChunk: 180, maxWindow: 32))
            receiverSession = session
            observeSessionEvents(session, isSender: false)

            #if canImport(CoreBluetooth)
            _ = try await peripheral.startAdvertising(capabilities: .init(supportsL2CAP: true, maxChunk: 180, maxWindow: 32))

            let gatt = try await makeReceiverGATTTransport()
            try await session.configureTransport(
                remoteCapabilities: .init(supportsL2CAP: false, maxChunk: 180, maxWindow: 32),
                l2capFactory: nil,
                gattFactory: { gatt }
            )
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSendMode() async {
        teardownReceiver()

        do {
            let session = try SessionActor(role: .sender, localCapabilities: .init(supportsL2CAP: true, maxChunk: 180, maxWindow: 32))
            senderSession = session
            observeSessionEvents(session, isSender: true)

            #if canImport(CoreBluetooth)
            try await central.startScanning()
            scanTask?.cancel()
            scanTask = Task {
                let stream = await central.nearbyDeviceStream()
                for await devices in stream {
                    await MainActor.run {
                        self.nearbyDevices = devices
                    }
                }
            }
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connectAndPair(_ device: NearbyDevice) async {
        guard let senderSession else {
            errorMessage = "Sender session unavailable."
            return
        }

        do {
            #if canImport(CoreBluetooth)
            let centralActor = central
            try await centralActor.connect(to: device.id)
            try await centralActor.discoverTransportCharacteristics(for: device.id)

            let gattFactory: TransportActor.TransportFactory = {
                let transport = GATTTransport(
                    maxPacketSize: device.capabilities.maxChunk,
                    windowSize: device.capabilities.maxWindow,
                    writePacket: { packet, requiresResponse in
                        try await centralActor.writePacket(packet, to: device.id, requiresResponse: requiresResponse)
                    },
                    canSendWithoutResponse: {
                        await centralActor.canSendWriteWithoutResponse(to: device.id)
                    },
                    waitForWriteWithoutResponse: {
                        await centralActor.waitForWriteWithoutResponseReady(to: device.id)
                    }
                )

                Task {
                    let packetStream = await centralActor.incomingPackets(for: device.id)
                    for await packet in packetStream {
                        try? await transport.receivePacket(packet)
                    }
                }

                return transport
            }

            let l2capFactory: TransportActor.TransportFactory? = device.l2capPSM.map { psm in
                {
                    let streams = try await centralActor.openL2CAP(to: device.id, psm: psm)
                    return L2CAPTransport(inputStream: streams.inputStream, outputStream: streams.outputStream)
                }
            }

            try await senderSession.configureTransport(
                remoteCapabilities: device.capabilities,
                l2capFactory: l2capFactory,
                gattFactory: gattFactory
            )
            #endif

            let result = try await senderSession.initiateHandshake()
            sasCode = result.sasCode
            showingPairing = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if canImport(CoreBluetooth)
    private func makeReceiverGATTTransport() async throws -> GATTTransport {
        let transport = GATTTransport(
            maxPacketSize: 180,
            windowSize: 32,
            writePacket: { [peripheral] packet, _ in
                await peripheral.notifyPacket(packet)
            }
        )

        Task {
            let incoming = await peripheral.incomingWritePackets()
            for await packet in incoming {
                try? await transport.receivePacket(packet)
            }
        }

        return transport
    }
    #endif

    private func observeSessionEvents(_ session: SessionActor, isSender: Bool) {
        let task = Task {
            let stream = await session.events()
            for await event in stream {
                await self.handle(event)
            }
        }

        if isSender {
            senderEventTask?.cancel()
            senderEventTask = task
        } else {
            receiverEventTask?.cancel()
            receiverEventTask = task
        }
    }

    private func handle(_ event: GhostEvent) {
        switch event {
        case let .stateChanged(state):
            self.state = state
        case let .nearbyDevicesUpdated(devices):
            self.nearbyDevices = devices
        case let .transportSelected(kind):
            self.activeTransport = kind
        case let .handshakeSAS(code):
            self.sasCode = code
            self.showingPairing = true
        case .verificationRequired:
            self.showingPairing = true
        case let .transferProgress(progress):
            self.progress = progress
        case let .transferCompleted(fileName):
            self.logs.append(GhostLogEntry(category: "session", level: "info", message: "Completed: \(fileName)"))
        case let .transferFailed(message):
            self.errorMessage = message
        case let .log(entry):
            self.logs.append(entry)
        case .connected:
            break
        }
    }

    private func teardownSender() {
        senderEventTask?.cancel()
        senderEventTask = nil
        scanTask?.cancel()
        scanTask = nil
    }

    private func teardownReceiver() {
        receiverEventTask?.cancel()
        receiverEventTask = nil
    }
}
