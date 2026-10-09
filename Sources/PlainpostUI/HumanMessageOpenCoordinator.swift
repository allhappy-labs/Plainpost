import PlainpostCore

@MainActor
public struct HumanMessageOpenCoordinator {
    private let openMessage: (MessageID) async throws -> Void

    public init(openMessage: @escaping (MessageID) async throws -> Void) {
        self.openMessage = openMessage
    }

    public func openIfPresent(_ messageID: String?) async throws {
        guard let messageID else { return }
        try await openMessage(MessageID(messageID))
    }
}
