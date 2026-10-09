import Foundation

@MainActor
final class RuntimeBackgroundWork {
    private var admittedTasks: [UUID: Task<Void, Never>] = [:]
    private var drainTask: Task<Void, Never>?

    var ownedTaskCount: Int { admittedTasks.count }

    func start(_ operation: @escaping @Sendable () async -> Void) {
        guard drainTask == nil else { return }

        let id = UUID()
        let task = Task { [weak self, operation] in
            guard !Task.isCancelled else {
                self?.removeTask(id)
                return
            }
            await operation()
            self?.removeTask(id)
        }
        admittedTasks[id] = task
    }

    func beginShutdown() -> Task<Void, Never> {
        if let drainTask { return drainTask }

        let tasks = Array(admittedTasks.values)
        tasks.forEach { $0.cancel() }
        let drainTask = Task { [weak self, tasks] in
            for task in tasks {
                await task.value
            }
            self?.removeCompletedTasks()
        }
        self.drainTask = drainTask
        return drainTask
    }

    func shutdown() async {
        await beginShutdown().value
    }

    private func removeTask(_ id: UUID) {
        admittedTasks[id] = nil
    }

    private func removeCompletedTasks() {
        admittedTasks.removeAll()
    }
}
