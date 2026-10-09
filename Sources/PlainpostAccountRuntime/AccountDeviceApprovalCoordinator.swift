import Foundation

@MainActor
public final class AccountDeviceApprovalCoordinator {
    private let authenticator: any LocalApprovalAuthenticating
    private var capability: AccountDeviceApprovalCapability?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var taskID: UUID?

    public init(authenticator: any LocalApprovalAuthenticating) { self.authenticator = authenticator }
    deinit { task?.cancel() }
    public func present(_ capability: AccountDeviceApprovalCapability) {
        generation &+= 1
        if let prior = self.capability { Task { await prior.cancel() } }
        task?.cancel(); task=nil; taskID=nil; self.capability=capability
    }
    public func approve(now: Date = Date()) {
        guard task == nil, let capability else { return }
        let context=capability.context
        guard now < context.expiresAt else { self.capability=nil; Task { await capability.cancel() }; return }
        let expectedGeneration=generation, expectedTaskID=UUID(); taskID=expectedTaskID; let authenticator=authenticator
        task=Task { [weak self] in
            do {
                try await authenticator.authenticate(reason:"Approve this device for your Plainpost account")
                guard !Task.isCancelled, let self, self.generation==expectedGeneration, self.capability?.id==capability.id, Date()<context.expiresAt else { return }
                try await capability.approve()
                guard self.generation==expectedGeneration, self.capability?.id==capability.id else { return }
                self.capability=nil
            } catch {
                await capability.cancel()
                guard let self, self.generation==expectedGeneration, self.capability?.id==capability.id else { return }
                self.capability=nil
            }
            guard let self, self.taskID==expectedTaskID else { return }; self.task=nil; self.taskID=nil
        }
    }
    public func cancel() { generation &+= 1; if let capability { Task { await capability.cancel() } }; capability=nil; task?.cancel(); task=nil; taskID=nil }
    public func waitUntilIdle() async { while let task { await task.value } }
}
