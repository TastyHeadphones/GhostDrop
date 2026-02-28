import Foundation

public actor TransportActor {
    public typealias TransportFactory = @Sendable () async throws -> any GhostTransport

    private let logger: GhostLogger
    private var activeTransport: (any GhostTransport)?

    public init(logger: GhostLogger = .shared) {
        self.logger = logger
    }

    @discardableResult
    public func negotiate(
        remoteCapabilities: GhostCapabilities,
        l2capFactory: TransportFactory?,
        gattFactory: TransportFactory
    ) async throws -> TransportKind {
        if remoteCapabilities.supportsL2CAP, let l2capFactory {
            do {
                let transport = try await l2capFactory()
                activeTransport = transport
                await logger.log("Selected L2CAP transport", category: .transport, level: .info)
                return .l2cap
            } catch {
                await logger.log(
                    "L2CAP unavailable; falling back to GATT: \(error.localizedDescription)",
                    category: .transport,
                    level: .warning
                )
            }
        }

        let transport = try await gattFactory()
        activeTransport = transport
        await logger.log("Selected GATT transport", category: .transport, level: .notice)
        return .gatt
    }

    public func start() async throws {
        guard let activeTransport else {
            throw GhostError.transportUnavailable
        }
        try await activeTransport.start()
    }

    public func send(_ frame: GhostFrame) async throws {
        guard let activeTransport else {
            throw GhostError.transportUnavailable
        }
        try await activeTransport.send(frame)
    }

    public func frames() async throws -> AsyncThrowingStream<GhostFrame, Error> {
        guard let activeTransport else {
            throw GhostError.transportUnavailable
        }
        return await activeTransport.frames()
    }

    public func close() async {
        guard let activeTransport else { return }
        await activeTransport.close()
        self.activeTransport = nil
    }

    public func currentTransportKind() -> TransportKind? {
        activeTransport?.kind
    }
}
