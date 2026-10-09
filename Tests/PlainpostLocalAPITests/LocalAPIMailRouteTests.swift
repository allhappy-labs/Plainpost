import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostLocalAPI
@testable import PlainpostLocalServer
@testable import PlainpostOperations

final class LocalAPIMailRouteTests: XCTestCase, @unchecked Sendable {
    func testSessionStatusRouteReportsReady() async throws {
        let result: LocalAPISessionStatus = try await invoke(
            SessionStatusRoute(),
            parameters: LocalAPIEmptyParameters()
        )

        XCTAssertTrue(result.ready)
    }

    func testUnreadRouteReturnsNewestTenFromGlobalMessageSnapshot() async throws {
        let messages = (0..<12).map { index in
            fixtureMessage(
                id: "m-\(index)",
                isSeen: false,
                sentAt: Date(timeIntervalSince1970: Double(index))
            )
        } + [fixtureMessage(id: "read", isSeen: true, sentAt: Date(timeIntervalSince1970: 99))]
        let route = UnreadListRoute(store: InMemoryMailStore(messages: messages), lastSync: { nil })

        let result: LocalAPIUnreadListResult = try await invoke(
            route,
            parameters: LocalAPIUnreadListParameters(limit: 10)
        )

        XCTAssertEqual(result.messages.map(\.id), (2..<12).reversed().map { "m-\($0)" })
        XCTAssertNil(result.lastSuccessfulSyncAt)
    }

    func testUnreadRouteClampsLimitFiltersDeletedAndUsesIDAsDateTieBreaker() async throws {
        let syncDate = Date(timeIntervalSince1970: 500)
        let tiedDate = Date(timeIntervalSince1970: 100)
        let messages = [
            fixtureMessage(id: "a", sentAt: tiedDate),
            fixtureMessage(id: "c", sentAt: tiedDate),
            fixtureMessage(id: "b", sentAt: tiedDate),
            fixtureMessage(id: "deleted", isDeleted: true, sentAt: Date(timeIntervalSince1970: 200)),
            fixtureMessage(id: "read", isSeen: true, sentAt: Date(timeIntervalSince1970: 300)),
            fixtureMessage(id: "undated", sentAt: nil),
        ]
        let store = InMemoryMailStore(messages: messages)

        let maximumResult: LocalAPIUnreadListResult = try await invoke(
            UnreadListRoute(store: store, lastSync: { syncDate }),
            parameters: LocalAPIUnreadListParameters(limit: 99)
        )
        let minimumResult: LocalAPIUnreadListResult = try await invoke(
            UnreadListRoute(store: store, lastSync: { syncDate }),
            parameters: LocalAPIUnreadListParameters(limit: 0)
        )

        XCTAssertEqual(maximumResult.messages.map(\.id), ["c", "b", "a", "undated"])
        XCTAssertEqual(maximumResult.lastSuccessfulSyncAt, syncDate)
        XCTAssertEqual(minimumResult.messages.map(\.id), ["c"])
    }

    func testUnreadRouteMapsOnlyStableFields() async throws {
        let message = fixtureMessage(
            id: "m-1",
            senderName: "Alice",
            body: "private full body",
            sentAt: Date(timeIntervalSince1970: 20)
        )

        let result: LocalAPIUnreadListResult = try await invoke(
            UnreadListRoute(store: InMemoryMailStore(messages: [message]), lastSync: { nil }),
            parameters: LocalAPIUnreadListParameters(limit: 10)
        )

        XCTAssertEqual(
            result.messages,
            [
                LocalAPIUnreadMessage(
                    id: "m-1",
                    sender: "alice@example.com",
                    senderName: "Alice",
                    subject: "Subject m-1",
                    preview: "Preview m-1",
                    sentAt: Date(timeIntervalSince1970: 20)
                )
            ]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result.messages[0])) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["id", "sender", "senderName", "subject", "preview", "sentAt"])
        XCTAssertNil(object["body"])
    }

    func testUnreadRouteEncodesDatesAsISO8601StringsOnWire() async throws {
        let sentAt = Date(timeIntervalSince1970: 20)
        let lastSync = Date(timeIntervalSince1970: 500)
        let route = UnreadListRoute(
            store: InMemoryMailStore(messages: [fixtureMessage(id: "m-1", sentAt: sentAt)]),
            lastSync: { lastSync }
        )
        let request = LocalAPIRequest(
            requestID: "req-dates",
            method: .mailUnreadList,
            parameters: LocalAPIUnreadListParameters(limit: 10)
        )

        let response = try await route.handle(
            requestData: JSONEncoder().encode(request),
            requestID: "req-dates"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response) as? [String: Any]
        )
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let messages = try XCTUnwrap(result["messages"] as? [[String: Any]])

        XCTAssertEqual(messages.first?["sentAt"] as? String, "1970-01-01T00:00:20Z")
        XCTAssertEqual(result["lastSuccessfulSyncAt"] as? String, "1970-01-01T00:08:20Z")
    }

    func testOpenRouteReturnsPlainTextAndMarksRead() async throws {
        let store = InMemoryMailStore(
            messages: [fixtureMessage(id: "m-1", isSeen: false, body: "Hello")],
            memberships: [MailboxMessageMembership(
                accountID: AccountID("account-m-1"), mailboxPath: "INBOX",
                uidValidity: 1, uid: 1, messageID: MessageID("m-1")
            )],
            threads: [MailThread(
                id: ThreadID("thread-m-1"),
                accountID: AccountID("account-m-1"),
                subjectNormalized: "subject m-1",
                participantEmails: []
            )]
        )
        let scheduler = RecordingMailboxFlagScheduler()
        let route = OpenMessageRoute(
            opening: MessageOpeningService(store: store, scheduler: scheduler)
        )

        let result: LocalAPIMessageDetail = try await invoke(
            route,
            parameters: LocalAPIOpenMessageParameters(messageID: "m-1")
        )

        XCTAssertEqual(result.bodyPlain, "Hello")
        XCTAssertEqual(result.id, "m-1")
        XCTAssertEqual(result.threadID, "thread-m-1")
        XCTAssertEqual(result.sender, "alice@example.com")
        XCTAssertEqual(result.senderName, "Alice")
        XCTAssertTrue(result.isSeen)
        XCTAssertTrue(store.messages[0].isSeen)
        XCTAssertEqual(scheduler.inputs.map(\.messageID), [MessageID("m-1")])
    }

    func testOpenRouteTruncatesBodyAtValidUTF8Boundary() async throws {
        let prefix = String(repeating: "a", count: LocalAPIProtocol.maximumMessageBodyBytes - 1)
        let body = prefix + "🙂" + "tail"
        let store = InMemoryMailStore(
            messages: [fixtureMessage(id: "m-1", body: body)],
            memberships: [MailboxMessageMembership(
                accountID: AccountID("account-m-1"), mailboxPath: "INBOX",
                uidValidity: 1, uid: 1, messageID: MessageID("m-1")
            )],
            threads: [MailThread(
                id: ThreadID("thread-m-1"),
                accountID: AccountID("account-m-1"),
                subjectNormalized: "subject m-1",
                participantEmails: []
            )]
        )
        let route = OpenMessageRoute(
            opening: MessageOpeningService(store: store, scheduler: RecordingMailboxFlagScheduler())
        )

        let result: LocalAPIMessageDetail = try await invoke(
            route,
            parameters: LocalAPIOpenMessageParameters(messageID: "m-1")
        )

        XCTAssertEqual(result.bodyPlain, prefix)
        XCTAssertLessThanOrEqual(result.bodyPlain.utf8.count, LocalAPIProtocol.maximumMessageBodyBytes)
    }

    func testOpenRouteMapsMissingMessageToSafeNotFoundError() async throws {
        let route = OpenMessageRoute(
            opening: MessageOpeningService(
                store: InMemoryMailStore(),
                scheduler: RecordingMailboxFlagScheduler()
            )
        )
        let router = LocalAPIRouter(routes: [route])
        let request = LocalAPIRequest(
            requestID: "req-missing",
            method: .mailOpen,
            parameters: LocalAPIOpenMessageParameters(messageID: "missing")
        )

        let response = await router.handle(
            try JSONEncoder().encode(request),
            caller: .browserExtension
        )
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: response)

        XCTAssertEqual(failure.error.code, .notFound)
        XCTAssertEqual(failure.error.message, "Message not found.")
    }

    func testOpenRouteMapsInvalidParametersToSafeInvalidRequestError() async throws {
        let route = OpenMessageRoute(
            opening: MessageOpeningService(
                store: InMemoryMailStore(),
                scheduler: RecordingMailboxFlagScheduler()
            )
        )
        let router = LocalAPIRouter(routes: [route])
        let raw = #"{"apiVersion":1,"requestID":"req-invalid","method":"mail.open","parameters":{}}"#

        let response = await router.handle(Data(raw.utf8), caller: .browserExtension)
        let failure = try JSONDecoder().decode(LocalAPIFailure.self, from: response)

        XCTAssertEqual(failure.error.code, .invalidRequest)
        XCTAssertEqual(failure.error.message, "The request parameters are invalid.")
    }

    func testIncrementalSyncAllContinuesAfterOneAccountFails() async throws {
        let syncer = RecordingAccountSyncer(results: [
            "a": .success(3),
            "b": .failure(.offline),
        ])
        let route = IncrementalSyncAllRoute(
            accountIDs: { [AccountID("a"), AccountID("b")] },
            syncer: syncer
        )

        let result: LocalAPISyncResult = try await invoke(
            route,
            parameters: LocalAPIEmptyParameters()
        )

        XCTAssertEqual(result.completedAccountIDs, ["a"])
        XCTAssertEqual(result.failedAccountIDs, ["b"])
        XCTAssertEqual(result.newMessageCount, 3)
        let inputs = await syncer.inputs.sorted {
            $0.accountID.rawValue < $1.accountID.rawValue
        }
        XCTAssertEqual(inputs, [
            PlainpostInboxSyncInput(accountID: AccountID("a"), trigger: .manual, scope: .incremental),
            PlainpostInboxSyncInput(accountID: AccountID("b"), trigger: .manual, scope: .incremental),
        ])
    }

    func testIncrementalSyncAllHandlesNoAccounts() async throws {
        let syncer = RecordingAccountSyncer(results: [:])
        let route = IncrementalSyncAllRoute(accountIDs: { [] }, syncer: syncer)

        let result: LocalAPISyncResult = try await invoke(
            route,
            parameters: LocalAPIEmptyParameters()
        )

        XCTAssertEqual(result, LocalAPISyncResult(
            completedAccountIDs: [],
            failedAccountIDs: [],
            newMessageCount: 0
        ))
        let inputs = await syncer.inputs
        XCTAssertTrue(inputs.isEmpty)
    }

    func testConcurrentIncrementalSyncCallersShareOneAccountExecution() async throws {
        let syncer = SuspendedAccountSyncer(outcomes: ["a": .success(3)])
        let route = IncrementalSyncAllRoute(
            accountIDs: { [AccountID("a")] },
            syncer: syncer
        )

        async let first: LocalAPISyncResult = invoke(
            route,
            parameters: LocalAPIEmptyParameters()
        )
        async let second: LocalAPISyncResult = invoke(
            route,
            parameters: LocalAPIEmptyParameters()
        )

        await syncer.waitForCallCount(1)
        try await Task.sleep(for: .milliseconds(50))
        let callCount = await syncer.callCount
        XCTAssertEqual(callCount, 1)
        await syncer.releaseAll()

        let results = try await [first, second]
        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[0].newMessageCount, 3)
    }

    func testCancelledIncrementalSyncWaiterReturnsPromptlyWhileSharedExecutionContinues() async throws {
        let syncer = SuspendedAccountSyncer(outcomes: ["a": .success(2)])
        let route = IncrementalSyncAllRoute(
            accountIDs: { [AccountID("a")] },
            syncer: syncer
        )
        let firstReturned = DispatchSemaphore(value: 0)
        let first = Task {
            defer { firstReturned.signal() }
            let result: LocalAPISyncResult = try await self.invoke(
                route,
                parameters: LocalAPIEmptyParameters()
            )
            return result
        }

        await syncer.waitForCallCount(1)
        let second = Task {
            let result: LocalAPISyncResult = try await self.invoke(
                route,
                parameters: LocalAPIEmptyParameters()
            )
            return result
        }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        let cancelledWaiterReturnedPromptly = await Task.detached {
            waitForSignal(firstReturned, timeout: 1)
        }.value

        let callCount = await syncer.callCount
        XCTAssertEqual(callCount, 1)
        let completionCountBeforeRelease = await syncer.completionCount
        XCTAssertEqual(completionCountBeforeRelease, 0)
        await syncer.releaseAll()

        let secondResult = try await second.value
        let finalCallCount = await syncer.callCount
        let finalCompletionCount = await syncer.completionCount
        XCTAssertTrue(cancelledWaiterReturnedPromptly)
        XCTAssertEqual(secondResult.newMessageCount, 2)
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(finalCompletionCount, 1)
        _ = try await first.value
    }

    func testCancelledCoordinatorWaitersDrainWhileOneSharedOperationRemainsAlive() async throws {
        let syncer = SuspendedAccountSyncer(outcomes: ["a": .success(4)])
        let coordinator = IncrementalSyncCoordinator()
        let input = PlainpostInboxSyncInput(
            accountID: AccountID("a"),
            trigger: .manual,
            scope: .incremental
        )
        let firstReturned = DispatchSemaphore(value: 0)
        let secondReturned = DispatchSemaphore(value: 0)
        let first = Task {
            defer { firstReturned.signal() }
            return try await coordinator.execute(input) {
                try await syncer.executeInboxSync(input)
            }
        }
        let second = Task {
            defer { secondReturned.signal() }
            return try await coordinator.execute(input) {
                try await syncer.executeInboxSync(input)
            }
        }
        await syncer.waitForCallCount(1)
        let allWaitersRegistered = await waitForActiveWaiterCount(
            coordinator,
            expected: 2
        )
        first.cancel()
        second.cancel()
        let cancelledWaitersReturnedPromptly = await Task.detached {
            waitForSignal(firstReturned, timeout: 1)
                && waitForSignal(secondReturned, timeout: 1)
        }.value
        let cancelledWaitersDrained = await waitForActiveWaiterCount(
            coordinator,
            expected: 0
        )
        let activeWaiterCount = await coordinator.activeWaiterCount
        let activeOperationCount = await coordinator.activeOperationCount
        let completionCountBeforeRelease = await syncer.completionCount
        let survivor = Task {
            try await coordinator.execute(input) {
                try await syncer.executeInboxSync(input)
            }
        }
        let survivorJoined = await waitForActiveWaiterCount(coordinator, expected: 1)

        await syncer.releaseAll()
        let survivorResult = try await survivor.value
        _ = try? await first.value
        _ = try? await second.value
        let finalCallCount = await syncer.callCount

        XCTAssertTrue(allWaitersRegistered)
        XCTAssertTrue(cancelledWaitersReturnedPromptly)
        XCTAssertTrue(cancelledWaitersDrained)
        XCTAssertEqual(activeWaiterCount, 0)
        XCTAssertEqual(activeOperationCount, 1)
        XCTAssertEqual(completionCountBeforeRelease, 0)
        XCTAssertTrue(survivorJoined)
        XCTAssertEqual(survivorResult.newlyDiscoveredMessageCount, 4)
        XCTAssertEqual(finalCallCount, 1)
    }

    func testIncrementalSyncExecutesAccountsIndependentlyAndAggregatesInAccountOrder() async throws {
        let syncer = ConcurrentAccountSyncer(delays: [
            "a": .milliseconds(120),
            "b": .milliseconds(10),
        ])
        let route = IncrementalSyncAllRoute(
            accountIDs: { [AccountID("a"), AccountID("b")] },
            syncer: syncer
        )

        let result: LocalAPISyncResult = try await invoke(
            route,
            parameters: LocalAPIEmptyParameters()
        )

        XCTAssertEqual(result.completedAccountIDs, ["a", "b"])
        XCTAssertEqual(result.failedAccountIDs, [])
        XCTAssertEqual(result.newMessageCount, 2)
        let maximumConcurrentExecutions = await syncer.maximumConcurrentExecutions
        XCTAssertEqual(maximumConcurrentExecutions, 2)
    }

    func testTerminalIncrementalSyncSuccessAndFailurePermitFreshExecutions() async throws {
        let syncer = SequencedAccountSyncer(outcomes: [
            .success(1),
            .failure(.offline),
            .success(2),
        ])
        let route = IncrementalSyncAllRoute(
            accountIDs: { [AccountID("a")] },
            syncer: syncer
        )

        let first: LocalAPISyncResult = try await invoke(
            route,
            parameters: LocalAPIEmptyParameters()
        )
        let second: LocalAPISyncResult = try await invoke(
            route,
            parameters: LocalAPIEmptyParameters()
        )
        let third: LocalAPISyncResult = try await invoke(
            route,
            parameters: LocalAPIEmptyParameters()
        )

        XCTAssertEqual(first.completedAccountIDs, ["a"])
        XCTAssertEqual(first.newMessageCount, 1)
        XCTAssertEqual(second.failedAccountIDs, ["a"])
        XCTAssertEqual(third.completedAccountIDs, ["a"])
        XCTAssertEqual(third.newMessageCount, 2)
        let callCount = await syncer.callCount
        XCTAssertEqual(callCount, 3)
    }

    private func invoke<Parameters, Result>(
        _ route: some LocalAPIRoute,
        parameters: Parameters
    ) async throws -> Result where Parameters: Codable & Sendable, Result: Codable & Sendable {
        let requestID = "test-request"
        let request = LocalAPIRequest(
            requestID: requestID,
            method: route.method,
            parameters: parameters
        )
        let response = try await route.handle(
            requestData: JSONEncoder().encode(request),
            requestID: requestID
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalAPISuccess<Result>.self, from: response).result
    }

    private func fixtureMessage(
        id: String,
        senderName: String? = "Alice",
        isSeen: Bool = false,
        isDeleted: Bool = false,
        body: String? = nil,
        sentAt: Date? = Date(timeIntervalSince1970: 10)
    ) -> MessageSummary {
        MessageSummary(
            id: MessageID(id),
            threadID: ThreadID("thread-\(id)"),
            from: EmailAddress("alice@example.com"),
            fromDisplayName: senderName,
            subject: "Subject \(id)",
            preview: "Preview \(id)",
            smartCategory: .personal,
            labels: [],
            isSeen: isSeen,
            mailboxPath: "INBOX",
            isDeleted: isDeleted,
            body: body ?? "Body \(id)",
            sentAt: sentAt
        )
    }
}

private enum TestError: Error, Sendable {
    case offline
}

private func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

private func waitForActiveWaiterCount(
    _ coordinator: IncrementalSyncCoordinator,
    expected: Int,
    timeout: TimeInterval = 1
) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if await coordinator.activeWaiterCount == expected { return true }
        await Task.yield()
    }
    return await coordinator.activeWaiterCount == expected
}

private final class RecordingMailboxFlagScheduler: MailboxFlagScheduling, @unchecked Sendable {
    private(set) var inputs: [PlainpostMailboxFlagInput] = []

    func schedule(_ input: PlainpostMailboxFlagInput) throws {
        inputs.append(input)
    }

    func signalWork() async throws {}
}

private actor RecordingAccountSyncer: PlainpostOperationClientProtocol {
    private let results: [String: Result<Int, TestError>]
    private(set) var inputs: [PlainpostInboxSyncInput] = []

    init(results: [String: Result<Int, TestError>]) {
        self.results = results
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        inputs.append(input)
        let count = try results[input.accountID.rawValue, default: .success(0)].get()
        return PlainpostInboxSyncResult(
            accountID: input.accountID,
            syncedMessageCount: count,
            newlyDiscoveredMessageCount: count,
            jobID: "job-\(input.accountID.rawValue)"
        )
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        throw TestError.offline
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw TestError.offline
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw TestError.offline
    }
}

private actor SuspendedAccountSyncer: PlainpostOperationClientProtocol {
    private let outcomes: [String: Result<Int, TestError>]
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [
        (expected: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var observedCallCount = 0
    private var observedCompletionCount = 0

    init(outcomes: [String: Result<Int, TestError>]) {
        self.outcomes = outcomes
    }

    var callCount: Int { observedCallCount }
    var completionCount: Int { observedCompletionCount }

    func waitForCallCount(_ expected: Int) async {
        guard observedCallCount < expected else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((expected, continuation))
        }
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        observedCallCount += 1
        resumeSatisfiedCallCountWaiters()
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        observedCompletionCount += 1
        let count = try outcomes[input.accountID.rawValue, default: .success(0)].get()
        return PlainpostInboxSyncResult(
            accountID: input.accountID,
            syncedMessageCount: count,
            newlyDiscoveredMessageCount: count,
            jobID: "job-\(input.accountID.rawValue)"
        )
    }

    private func resumeSatisfiedCallCountWaiters() {
        var pending: [(expected: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if observedCallCount >= waiter.expected {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        callCountWaiters = pending
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        throw TestError.offline
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw TestError.offline
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw TestError.offline
    }
}

private actor ConcurrentAccountSyncer: PlainpostOperationClientProtocol {
    private let delays: [String: Duration]
    private var currentExecutions = 0
    private var observedMaximumConcurrentExecutions = 0

    init(delays: [String: Duration]) {
        self.delays = delays
    }

    var maximumConcurrentExecutions: Int { observedMaximumConcurrentExecutions }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        currentExecutions += 1
        observedMaximumConcurrentExecutions = max(
            observedMaximumConcurrentExecutions,
            currentExecutions
        )
        defer { currentExecutions -= 1 }
        try await Task.sleep(for: delays[input.accountID.rawValue, default: .milliseconds(1)])
        return PlainpostInboxSyncResult(
            accountID: input.accountID,
            syncedMessageCount: 1,
            newlyDiscoveredMessageCount: 1,
            jobID: "job-\(input.accountID.rawValue)"
        )
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        throw TestError.offline
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw TestError.offline
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw TestError.offline
    }
}

private actor SequencedAccountSyncer: PlainpostOperationClientProtocol {
    private var outcomes: [Result<Int, TestError>]
    private var observedCallCount = 0

    init(outcomes: [Result<Int, TestError>]) {
        self.outcomes = outcomes
    }

    var callCount: Int { observedCallCount }

    func executeInboxSync(_ input: PlainpostInboxSyncInput) async throws -> PlainpostInboxSyncResult {
        observedCallCount += 1
        let outcome = outcomes.isEmpty ? .success(0) : outcomes.removeFirst()
        let count = try outcome.get()
        return PlainpostInboxSyncResult(
            accountID: input.accountID,
            syncedMessageCount: count,
            newlyDiscoveredMessageCount: count,
            jobID: "job-\(observedCallCount)"
        )
    }

    func executeAI(_ input: PlainpostAIOperationInput) async throws -> PlainpostAIOperationResult {
        throw TestError.offline
    }

    func approveSend(requestID: SendRequestID, approvedBy: String) async throws {
        throw TestError.offline
    }

    func denySend(requestID: SendRequestID, deniedBy: String) async throws {
        throw TestError.offline
    }
}
