import CryptoKit
import Foundation

public actor SessionActor {
    private struct ReceiveTransferContext {
        var metadata: FileMetadata
        var lastConfirmedSequence: UInt64
        var startedAt: Date
    }

    private let role: SessionRole
    private let logger: GhostLogger
    private let transportActor: TransportActor
    private let resumeStore: ResumeStore
    private let incomingStore: IncomingTransferStore

    private let localDeviceID: DeviceID
    private let localCapabilities: GhostCapabilities

    private var state: SessionState = .idle

    private var eventContinuations: [UUID: AsyncStream<GhostEvent>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?

    private var sessionID: UUID?
    private var localHelloKey: P256.KeyAgreement.PrivateKey?
    private var localHelloNonce: Data?
    private var localHelloPublicKey: Data?

    private var pendingHelloAck: CheckedContinuation<HandshakeHelloAckPayload, Error>?
    private var pendingVerifyAck: CheckedContinuation<Bool, Error>?

    private var handshakeSecrets: HandshakeSecrets?
    private var cryptoContext: SessionCryptoContext?
    private var sasCode: String?
    private var transcriptHash: Data?
    private var verificationPassed = false

    private var currentReceiveContext: ReceiveTransferContext?
    private var expectedSenderDigest: Data?

    private var lastAckedSequence: UInt64 = 0
    private var resumeFromSequence: UInt64 = 0

    public init(
        role: SessionRole,
        localDeviceID: DeviceID = DeviceID(),
        localCapabilities: GhostCapabilities,
        logger: GhostLogger = .shared,
        transportActor: TransportActor = TransportActor(),
        resumeStore: ResumeStore? = nil,
        incomingStore: IncomingTransferStore? = nil
    ) throws {
        self.role = role
        self.localDeviceID = localDeviceID
        self.localCapabilities = localCapabilities
        self.logger = logger
        self.transportActor = transportActor
        self.resumeStore = try resumeStore ?? ResumeStore()
        self.incomingStore = try incomingStore ?? IncomingTransferStore()
    }

    public func events() -> AsyncStream<GhostEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventContinuations[id] = continuation
            continuation.yield(.stateChanged(state))

            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeEventContinuation(id: id)
                }
            }
        }
    }

    public func currentState() -> SessionState {
        state
    }

    public func configureTransport(
        remoteCapabilities: GhostCapabilities,
        l2capFactory: TransportActor.TransportFactory?,
        gattFactory: TransportActor.TransportFactory
    ) async throws {
        try transition(to: .negotiating)

        let selected = try await transportActor.negotiate(
            remoteCapabilities: remoteCapabilities,
            l2capFactory: l2capFactory,
            gattFactory: gattFactory
        )

        try await transportActor.start()
        startReceiveLoop()

        emit(.transportSelected(selected))
    }

    public func enterReceiveMode() throws {
        try transition(to: .advertising)
    }

    public func enterSendMode() throws {
        try transition(to: .scanning)
    }

    public func initiateHandshake() async throws -> HandshakeResult {
        try transition(to: .connecting)

        let newSessionID = UUID()
        sessionID = newSessionID

        let helloTuple = try Handshake.createHello(
            sessionID: newSessionID,
            deviceID: localDeviceID,
            capabilities: localCapabilities
        )

        localHelloKey = helloTuple.privateKey
        localHelloNonce = helloTuple.hello.nonce
        localHelloPublicKey = helloTuple.hello.ephemeralPublicKey

        try transition(to: .negotiating)
        try await transportActor.send(.hello(helloTuple.hello))

        let helloAck = try await waitForHelloAck(timeout: .seconds(15))
        try await deriveSharedSecretsFromHelloAck(helloAck)

        guard let sasCode, let transcriptHash else {
            throw GhostError.handshakeFailed("SAS was not available")
        }

        let verify = VerificationPayload(transcriptHash: transcriptHash, sasCode: sasCode)
        try await transportActor.send(.verify(verify))

        try transition(to: .verifying)
        emit(.handshakeSAS(sasCode))
        emit(.verificationRequired)

        return HandshakeResult(sasCode: sasCode, transcriptHash: transcriptHash)
    }

    public func confirmSAS(matches: Bool) async throws {
        guard state == .verifying || state == .negotiating else {
            throw GhostError.invalidStateTransition(from: state, to: .verifying)
        }

        try await transportActor.send(.verifyAck(matches))

        guard matches else {
            verificationPassed = false
            try transition(to: .failed)
            throw GhostError.verificationRejected
        }

        verificationPassed = true
        try transition(to: .transferring)

        if role == .sender {
            let accepted = try await waitForVerifyAck(timeout: .seconds(15))
            guard accepted else {
                verificationPassed = false
                try transition(to: .failed)
                throw GhostError.verificationRejected
            }
        }
    }

    public func sendFile(
        at fileURL: URL,
        mimeType: String = "application/octet-stream",
        requestedChunkSize: Int? = nil
    ) async throws {
        guard verificationPassed else {
            throw GhostError.handshakeFailed("SAS verification is required before transfer")
        }

        try transition(to: .transferring)

        let data = try Data(contentsOf: fileURL)
        let transferID = UUID()
        let digest = Data(SHA256.hash(data: data))
        expectedSenderDigest = digest

        let chunkSize = max(1, min(requestedChunkSize ?? localCapabilities.maxChunk, localCapabilities.maxChunk))

        let metadata = FileMetadata(
            transferID: transferID,
            filename: fileURL.lastPathComponent,
            size: Int64(data.count),
            mimeType: mimeType,
            sha256: digest,
            chunkSize: chunkSize
        )

        try await sendControlFrame(.metadata(metadata))

        let totalChunks = UInt64(ceil(Double(data.count) / Double(chunkSize)))
        let startSequence = min(resumeFromSequence, totalChunks)

        let transferStart = Date()
        var bytesSent: Int64 = Int64(startSequence) * Int64(chunkSize)

        for sequence in startSequence..<totalChunks {
            if Task.isCancelled {
                throw GhostError.cancelled
            }

            let offset = Int(sequence) * chunkSize
            let end = min(offset + chunkSize, data.count)
            let plaintextChunk = data[offset..<end]

            let payload: Data
            if let cryptoContext {
                payload = try await cryptoContext.sealDataPayload(
                    sequence: sequence,
                    payload: Data(plaintextChunk)
                )
            } else {
                payload = Data(plaintextChunk)
            }

            try await transportActor.send(.data(sequence: sequence, payload: payload))

            bytesSent = Int64(end)
            let elapsed = max(Date().timeIntervalSince(transferStart), 0.001)
            let throughput = Double(bytesSent) / elapsed
            let remaining = Int64(data.count) - bytesSent
            let eta = throughput > 0 ? Double(remaining) / throughput : nil
            let transport = await transportActor.currentTransportKind() ?? .gatt

            emit(.transferProgress(
                TransferProgress(
                    bytesTransferred: bytesSent,
                    totalBytes: Int64(data.count),
                    throughputBytesPerSecond: throughput,
                    etaSeconds: eta,
                    transport: transport
                )
            ))
        }

        try await sendControlFrame(.complete(TransferCompletePayload(transferID: transferID, sha256: digest)))
        try transition(to: .completed)
        emit(.transferCompleted(fileName: fileURL.lastPathComponent))
    }

    public func cancel(reason: String = "Cancelled by user") async {
        do {
            try await sendControlFrame(.cancel(reason: reason))
        } catch {
            emit(.log(GhostLogEntry(category: "session", level: "error", message: "Cancel frame failed: \(error.localizedDescription)")))
        }

        do {
            try transition(to: .cancelled)
        } catch {
            emit(.transferFailed(error.localizedDescription))
        }

        await transportActor.close()
        receiveTask?.cancel()
        receiveTask = nil
    }

    public func exportLogsNDJSON(to url: URL) async throws {
        try await logger.exportNDJSON(to: url)
    }

    private func removeEventContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func emit(_ event: GhostEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.transportActor.frames()
                for try await frame in stream {
                    try await self.processIncoming(frame)
                }
            } catch {
                await self.handleReceiveError(error)
            }
        }
    }

    private func handleReceiveError(_ error: Error) {
        emit(.transferFailed(error.localizedDescription))
        do {
            try transition(to: .failed)
        } catch {
            emit(.transferFailed(error.localizedDescription))
        }
    }

    private func processIncoming(_ frame: GhostFrame) async throws {
        switch frame {
        case let .hello(payload):
            try await handleHello(payload)
        case let .helloAck(payload):
            pendingHelloAck?.resume(returning: payload)
            pendingHelloAck = nil
        case let .verify(payload):
            try handleVerify(payload)
        case let .verifyAck(accepted):
            pendingVerifyAck?.resume(returning: accepted)
            pendingVerifyAck = nil
            guard accepted else {
                throw GhostError.verificationRejected
            }
            verificationPassed = true
            try transition(to: .transferring)
        case let .metadata(metadata):
            try await handleMetadata(metadata)
        case let .data(sequence, payload):
            try await handleData(sequence: sequence, payload: payload)
        case let .ack(ack):
            handleAck(ack)
        case let .resume(resume):
            handleResume(resume)
        case let .complete(payload):
            try await handleComplete(payload)
        case let .cancel(reason):
            throw GhostError.handshakeFailed("Peer cancelled: \(reason)")
        case .ping:
            break
        case let .encrypted(sequence, combined):
            try await handleEncryptedFrame(sequence: sequence, combined: combined)
        }
    }

    private func waitForHelloAck(timeout: Duration) async throws -> HandshakeHelloAckPayload {
        try await withCheckedThrowingContinuation { continuation in
            pendingHelloAck = continuation

            Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.timeoutHelloAckIfNeeded()
            }
        }
    }

    private func waitForVerifyAck(timeout: Duration) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            pendingVerifyAck = continuation

            Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.timeoutVerifyAckIfNeeded()
            }
        }
    }

    private func deriveSharedSecretsFromHelloAck(_ helloAck: HandshakeHelloAckPayload) async throws {
        guard
            let key = localHelloKey,
            let localPublicKey = localHelloPublicKey,
            let localNonce = localHelloNonce,
            let sessionID
        else {
            throw GhostError.handshakeFailed("Local hello state is missing")
        }

        let secrets = try Handshake.deriveSecrets(
            localPrivateKey: key,
            localPublicKey: localPublicKey,
            localNonce: localNonce,
            remotePublicKey: helloAck.ephemeralPublicKey,
            remoteNonce: helloAck.nonce,
            sessionID: sessionID
        )

        self.handshakeSecrets = secrets
        self.transcriptHash = secrets.transcriptHash
        self.sasCode = Handshake.deriveSASCode(transcriptHash: secrets.transcriptHash)
        self.cryptoContext = SessionCryptoContext(secrets: secrets, role: role)
    }

    private func handleHello(_ hello: HandshakeHelloPayload) async throws {
        guard role == .receiver else { return }

        sessionID = hello.sessionID

        let ackTuple = try Handshake.createHelloAck(sessionID: hello.sessionID)

        let secrets = try Handshake.deriveSecrets(
            localPrivateKey: ackTuple.privateKey,
            localPublicKey: ackTuple.helloAck.ephemeralPublicKey,
            localNonce: ackTuple.helloAck.nonce,
            remotePublicKey: hello.ephemeralPublicKey,
            remoteNonce: hello.nonce,
            sessionID: hello.sessionID
        )

        self.handshakeSecrets = secrets
        self.transcriptHash = secrets.transcriptHash
        self.sasCode = Handshake.deriveSASCode(transcriptHash: secrets.transcriptHash)
        self.cryptoContext = SessionCryptoContext(secrets: secrets, role: role)

        try await transportActor.send(.helloAck(ackTuple.helloAck))

        if let sasCode {
            try transition(to: .verifying)
            emit(.handshakeSAS(sasCode))
            emit(.verificationRequired)
        }
    }

    private func handleVerify(_ payload: VerificationPayload) throws {
        guard let transcriptHash, let sasCode else {
            throw GhostError.handshakeFailed("Verify arrived before transcript was established")
        }

        guard transcriptHash == payload.transcriptHash else {
            throw GhostError.handshakeFailed("Transcript hash mismatch")
        }

        guard sasCode == payload.sasCode else {
            throw GhostError.handshakeFailed("SAS mismatch")
        }

        emit(.handshakeSAS(payload.sasCode))
        emit(.verificationRequired)
    }

    private func handleMetadata(_ metadata: FileMetadata) async throws {
        _ = try await incomingStore.prepareTransfer(metadata)

        let existing = try await resumeStore.load(transferID: metadata.transferID)
        let lastConfirmed = existing?.lastConfirmedSequence ?? 0

        currentReceiveContext = ReceiveTransferContext(
            metadata: metadata,
            lastConfirmedSequence: lastConfirmed,
            startedAt: Date()
        )

        let resume = GhostResumeRequest(transferID: metadata.transferID, lastConfirmedSequence: lastConfirmed)
        try await transportActor.send(.resume(resume))
    }

    private func handleData(sequence: UInt64, payload: Data) async throws {
        guard var context = currentReceiveContext else {
            throw GhostError.handshakeFailed("Received data before metadata")
        }

        let plaintext: Data
        if let cryptoContext, verificationPassed {
            plaintext = try await cryptoContext.openDataPayload(sequence: sequence, combined: payload)
        } else {
            plaintext = payload
        }

        let offset = sequence * UInt64(context.metadata.chunkSize)
        try await incomingStore.appendChunk(
            transferID: context.metadata.transferID,
            fileName: context.metadata.filename,
            payload: plaintext,
            expectedOffset: offset
        )

        context.lastConfirmedSequence = max(context.lastConfirmedSequence, sequence)
        currentReceiveContext = context

        let resumeState = TransferResumeState(
            transferID: context.metadata.transferID,
            fileName: context.metadata.filename,
            fileSize: context.metadata.size,
            sha256Hex: context.metadata.sha256.hexString,
            chunkSize: context.metadata.chunkSize,
            lastConfirmedSequence: context.lastConfirmedSequence
        )
        try await resumeStore.save(resumeState)

        let ack = GhostAck(cumulativeSequence: context.lastConfirmedSequence)
        try await transportActor.send(.ack(ack))

        let bytes = Int64((context.lastConfirmedSequence + 1) * UInt64(context.metadata.chunkSize))
        let transferred = min(bytes, context.metadata.size)
        let elapsed = max(Date().timeIntervalSince(context.startedAt), 0.001)
        let throughput = Double(transferred) / elapsed
        let remaining = context.metadata.size - transferred
        let eta = throughput > 0 ? Double(remaining) / throughput : nil
        let transport = await transportActor.currentTransportKind() ?? .gatt

        emit(.transferProgress(
            TransferProgress(
                bytesTransferred: transferred,
                totalBytes: context.metadata.size,
                throughputBytesPerSecond: throughput,
                etaSeconds: eta,
                transport: transport
            )
        ))
    }

    private func handleAck(_ ack: GhostAck) {
        lastAckedSequence = max(lastAckedSequence, ack.cumulativeSequence)
    }

    private func handleResume(_ resume: GhostResumeRequest) {
        resumeFromSequence = max(resumeFromSequence, resume.lastConfirmedSequence + 1)
    }

    private func handleComplete(_ payload: TransferCompletePayload) async throws {
        guard let context = currentReceiveContext else {
            throw GhostError.handshakeFailed("Complete received before metadata")
        }

        let receivedDigest = try await incomingStore.finalize(
            transferID: payload.transferID,
            fileName: context.metadata.filename
        )

        guard receivedDigest == payload.sha256 else {
            throw GhostError.handshakeFailed("Final SHA256 mismatch")
        }

        try await resumeStore.delete(transferID: payload.transferID)
        try transition(to: .completed)
        emit(.transferCompleted(fileName: context.metadata.filename))
    }

    private func handleEncryptedFrame(sequence: UInt64, combined: Data) async throws {
        guard let cryptoContext else {
            throw GhostError.decryptionFailure
        }

        let outer = GhostFrame.encrypted(sequence: sequence, combined: combined)
        let decrypted = try await cryptoContext.open(outer)
        try await processIncoming(decrypted)
    }

    private func sendControlFrame(_ frame: GhostFrame) async throws {
        guard verificationPassed, let cryptoContext else {
            try await transportActor.send(frame)
            return
        }

        switch frame {
        case .ack, .resume:
            try await transportActor.send(frame)
        default:
            let wrapped = try await cryptoContext.seal(frame)
            try await transportActor.send(wrapped)
        }
    }

    private func timeoutHelloAckIfNeeded() {
        guard let continuation = pendingHelloAck else { return }
        pendingHelloAck = nil
        continuation.resume(throwing: GhostError.timeout("hello ack"))
    }

    private func timeoutVerifyAckIfNeeded() {
        guard let continuation = pendingVerifyAck else { return }
        pendingVerifyAck = nil
        continuation.resume(throwing: GhostError.timeout("verify ack"))
    }

    private func transition(to newState: SessionState) throws {
        if state == newState { return }

        guard isValidTransition(from: state, to: newState) else {
            throw GhostError.invalidStateTransition(from: state, to: newState)
        }

        state = newState
        emit(.stateChanged(newState))
    }

    private func isValidTransition(from old: SessionState, to new: SessionState) -> Bool {
        switch (old, new) {
        case (.idle, .advertising), (.idle, .scanning), (.idle, .connecting), (.idle, .negotiating), (.idle, .failed), (.idle, .cancelled):
            return true
        case (.advertising, .connecting), (.advertising, .negotiating), (.advertising, .failed), (.advertising, .cancelled):
            return true
        case (.scanning, .connecting), (.scanning, .negotiating), (.scanning, .failed), (.scanning, .cancelled):
            return true
        case (.connecting, .negotiating), (.connecting, .failed), (.connecting, .cancelled):
            return true
        case (.negotiating, .verifying), (.negotiating, .failed), (.negotiating, .cancelled), (.negotiating, .transferring):
            return true
        case (.verifying, .transferring), (.verifying, .failed), (.verifying, .cancelled):
            return true
        case (.transferring, .completed), (.transferring, .failed), (.transferring, .cancelled):
            return true
        case (.completed, .idle), (.failed, .idle), (.cancelled, .idle):
            return true
        default:
            return false
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
