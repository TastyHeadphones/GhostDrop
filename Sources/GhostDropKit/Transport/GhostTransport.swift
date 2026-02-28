import Foundation

public protocol GhostTransport: Actor {
    nonisolated var kind: TransportKind { get }

    func start() async throws
    func send(_ frame: GhostFrame) async throws
    func frames() -> AsyncThrowingStream<GhostFrame, Error>
    func close() async
}
