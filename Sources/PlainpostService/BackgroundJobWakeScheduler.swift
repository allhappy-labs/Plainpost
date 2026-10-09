import Foundation

protocol BackgroundJobWakeScheduling: Sendable {
    func replaceWake(
        at date: Date?,
        action: @escaping @Sendable () async -> Void
    ) async
}

actor TaskBackgroundJobWakeScheduler: BackgroundJobWakeScheduling {
    private var task: Task<Void, Never>?
    private var scheduledDate: Date?
    private var generation = UUID()

    func replaceWake(
        at date: Date?,
        action: @escaping @Sendable () async -> Void
    ) async {
        task?.cancel()
        task = nil
        scheduledDate = date
        generation = UUID()
        guard let date else { return }

        let expectedGeneration = generation
        let delay = max(0, date.timeIntervalSinceNow)
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.fire(
                expectedGeneration: expectedGeneration,
                action: action
            )
        }
    }

    private func fire(
        expectedGeneration: UUID,
        action: @escaping @Sendable () async -> Void
    ) async {
        guard generation == expectedGeneration else { return }
        task = nil
        scheduledDate = nil
        await action()
    }
}
