import Darwin
import Foundation
import XCTest
@testable import PlainpostCore
@testable import PlainpostDB
@testable import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
@testable import PlainpostService
@testable import PlainpostTestSupport
@testable import PlainpostUI

private actor IdleNotificationCenter: SystemNotificationCenterAdapting {
    private(set) var addAttemptCount = 0
    private(set) var notifications: [PlainpostNotification] = []

    func authorizationStatus() async -> LocalNotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> LocalNotificationAuthorization { .authorized }

    func add(_ notification: PlainpostNotification) async throws {
        addAttemptCount += 1
        notifications.append(notification)
    }
}

final class IMAPHarnessTests: XCTestCase {
    func testServiceOwnedIdleSignalImportsAndDeliversNewMailWithoutFallbackDelay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainpost-service-idle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = "service-idle-secret"
        let remoteMessage = PlainpostFixtures.aliceMessage
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: password,
            message: remoteMessage,
            messageUID: 2,
            supportsIdle: true,
            sendsIdleChange: true
        )
        try await server.start()
        defer { server.stop() }
        let store = try SQLiteMailStore(
            path: directory.appendingPathComponent("Plainpost.sqlite").path
        )
        try store.migrate()
        let account = Account(
            id: AccountID("acc-service-idle"),
            displayName: "Service IDLE",
            email: EmailAddress("me@example.com"),
            username: "me@example.com",
            imapHost: "127.0.0.1",
            imapPort: server.port,
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        try store.cacheMailboxes([
            Mailbox(
                id: MailboxID("mbx-service-idle"),
                accountID: account.id,
                name: "INBOX",
                path: "INBOX",
                specialUse: "\\Inbox"
            )
        ])
        let seedMessage = MessageSummary(
            id: MessageID("msg-service-idle-seed"),
            threadID: nil,
            from: EmailAddress("seed@example.com"),
            subject: "Existing cursor",
            preview: "Already synchronized",
            smartCategory: .personal
        )
        try store.cacheMessageReliably(seedMessage)
        XCTAssertEqual(
            try store.recordMailboxGeneration(
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1
            ),
            .initialBaseline
        )
        try store.recordCachedUID(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 1,
            messageID: seedMessage.id
        )
        try store.markMailboxBaselineComplete(
            accountID: account.id,
            mailboxPath: "INBOX",
            uidValidity: 1
        )
        let assembly = SQLiteCredentialVaultAssembly(
            store: store,
            provider: IdleTestVaultKeyProvider()
        )
        try await assembly.unlockForeground(prompt: "IDLE integration test")
        try await assembly.vault.store(
            Data(password.utf8),
            for: CredentialRecordKey(
                rawValue: "account:\(account.id.rawValue):imap-password"
            )
        )
        let fallbackSignals = IdleFallbackSignalRecorder()
        let operations = PlainpostServiceOperations(
            applicationSupportURL: directory,
            store: store,
            assembly: assembly,
            mailMonitorFactory: { serviceSignal in
                let idleSupervisor = IMAPIdleSupervisor(
                    store: store,
                    credentials: assembly.vault,
                    signal: serviceSignal
                )
                return ServiceMailMonitor(
                    store: store,
                    idleSupervisor: idleSupervisor,
                    signal: { accountID in
                        await fallbackSignals.record(accountID)
                    },
                    notificationCenter: NotificationCenter(),
                    observeDistributedNotifications: false
                )
            }
        )
        let notificationCenter = IdleNotificationCenter()
        let delivery = MacNewMailDelivery(
            store: store,
            center: notificationCenter,
            newMailEnabled: { true },
            previewEnabled: { true },
            soundsEnabled: { true }
        )

        let startedAt = ContinuousClock.now
        await delivery.start()
        await operations.reopenRuntimeConstruction()
        var imported = false
        do {
            let deadline = startedAt.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                imported = store.messages.contains {
                    $0.id != seedMessage.id
                        && $0.subject == remoteMessage.subject
                }
                if imported { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            await delivery.stop()
            await operations.beginVaultLockdown()
            throw error
        }
        await operations.beginVaultLockdown()
        await operations.confirmVaultLocked()
        var notificationDelivered = false
        do {
            let deadline = startedAt.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                notificationDelivered = await notificationCenter.addAttemptCount == 1
                if notificationDelivered { break }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            await delivery.stop()
            throw error
        }
        let elapsed = startedAt.duration(to: .now)
        await delivery.stop()

        let fallbackSignalCount = await fallbackSignals.count
        XCTAssertTrue(imported, "IDLE did not import the new message")
        XCTAssertTrue(notificationDelivered, "the two-second delivery window waited for fallback")
        XCTAssertLessThan(elapsed, .seconds(5))
        XCTAssertEqual(
            fallbackSignalCount,
            1,
            "only the intentionally suppressed immediate fallback should run"
        )
    }

    func testUnsupportedIdleAndFiveMinuteFallbackShareCoalescedServiceSignal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "plainpost-service-idle-fallback-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = "service-fallback-secret"
        let server = LocalIMAPServer(
            username: "fallback@example.com",
            password: password,
            message: PlainpostFixtures.aliceMessage,
            supportsIdle: false
        )
        try await server.start()
        defer { server.stop() }
        let store = try SQLiteMailStore(
            path: directory.appendingPathComponent("Plainpost.sqlite").path
        )
        try store.migrate()
        let account = Account(
            id: AccountID("acc-service-fallback"),
            displayName: "Service fallback",
            email: EmailAddress("fallback@example.com"),
            username: "fallback@example.com",
            imapHost: "127.0.0.1",
            imapPort: server.port,
            smtpHost: "smtp.example.com"
        )
        try store.cacheAccounts([account])
        let assembly = SQLiteCredentialVaultAssembly(
            store: store,
            provider: IdleTestVaultKeyProvider()
        )
        try await assembly.unlockForeground(prompt: "IDLE fallback integration test")
        try await assembly.vault.store(
            Data(password.utf8),
            for: CredentialRecordKey(
                rawValue: "account:\(account.id.rawValue):imap-password"
            )
        )
        let signalRecorder = IdleFallbackSignalRecorder()
        let initialSignalBarrier = IdleInitialSignalBarrier()
        let fallbackClock = IdleFallbackClock()
        let operations = PlainpostServiceOperations(
            applicationSupportURL: directory,
            store: store,
            assembly: assembly,
            mailMonitorFactory: { serviceSignal in
                let sharedSignal: IMAPIdleSupervisor.Signal = { accountID in
                    await initialSignalBarrier.wait()
                    try await serviceSignal(accountID)
                    await signalRecorder.record(accountID)
                }
                let idleSupervisor = IMAPIdleSupervisor(
                    store: store,
                    credentials: assembly.vault,
                    signal: sharedSignal
                )
                return ServiceMailMonitor(
                    store: store,
                    idleSupervisor: idleSupervisor,
                    signal: sharedSignal,
                    sleep: { duration in try await fallbackClock.sleep(duration) },
                    notificationCenter: NotificationCenter(),
                    observeDistributedNotifications: false
                )
            }
        )

        await operations.reopenRuntimeConstruction()
        let initialDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await signalRecorder.count < 2,
              ContinuousClock.now < initialDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let initialSignalCount = await signalRecorder.count
        XCTAssertEqual(initialSignalCount, 2)
        XCTAssertEqual(fallbackClock.durations, [.seconds(5 * 60)])
        let jobsAfterUnsupported = try store.jobs(limit: 100).filter {
            $0.kind == .inboxSync
        }
        XCTAssertEqual(
            jobsAfterUnsupported.count,
            1,
            "the immediate fallback and unsupported-IDLE signal must coalesce"
        )

        fallbackClock.resumeNext()
        let fallbackDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await signalRecorder.count < 3,
              ContinuousClock.now < fallbackDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        await operations.beginVaultLockdown()
        await operations.confirmVaultLocked()

        let finalSignalCount = await signalRecorder.count
        XCTAssertEqual(finalSignalCount, 3)
        let jobs = try store.jobs(limit: 100).filter { $0.kind == .inboxSync }
        XCTAssertEqual(jobs.count, 2)
        for job in jobs {
            let input = try JSONDecoder().decode(
                PlainpostInboxSyncInput.self,
                from: Data(job.payloadJSON.utf8)
            )
            XCTAssertEqual(job.state, .completed)
            XCTAssertEqual(input.trigger, .realTimeSignal)
            XCTAssertEqual(input.scope, .incremental)
        }
    }

    func testDisconnectedPeerWriteReturnsSocketErrorWithoutSIGPIPE() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage,
            peer: .init(
                capabilities: ["IMAP4REV1", "AUTH=PLAIN", "X-GM-EXT-1"],
                mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox")],
                uidValidity: 1,
                messageUID: 1,
                messageData: Data("Subject: literal\r\n\r\nbody".utf8),
                providerMetadata: .init(stableID: "111", threadID: "222", labels: ["\\Inbox"]),
                metadataBehavior: .gmailLabelsLiteral(bytes: 2 << 20)
            )
        )
        try await server.start()
        defer { server.stop() }

        var descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IMAPClientError.connectionFailed }
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = server.port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw IMAPClientError.connectionFailed
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw IMAPClientError.connectionFailed }

        var greeting = [UInt8](repeating: 0, count: 128)
        let greetingCount = greeting.withUnsafeMutableBytes { buffer in
            Darwin.recv(descriptor, buffer.baseAddress!, buffer.count, 0)
        }
        XCTAssertGreaterThan(greetingCount, 0)
        let request = Array("A001 UID FETCH 1 (X-GM-LABELS)\r\n".utf8)
        let written = request.withUnsafeBytes { buffer in
            Darwin.send(descriptor, buffer.baseAddress!, buffer.count, 0)
        }
        XCTAssertEqual(written, request.count)
        XCTAssertEqual(Darwin.shutdown(descriptor, SHUT_WR), 0)
        try await Task.sleep(for: .milliseconds(20))
        var resetOnClose = linger(l_onoff: 1, l_linger: 0)
        XCTAssertEqual(
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_LINGER,
                &resetOnClose,
                socklen_t(MemoryLayout<linger>.size)
            ),
            0
        )
        Darwin.close(descriptor)
        descriptor = -1

        let deadline = Date().addingTimeInterval(2)
        while server.socketWriteFailureCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(
            server.socketWriteFailureCount,
            0,
            "the disconnected write must return a socket error rather than SIGPIPE"
        )

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        let mailboxes = try await client.listMailboxes()
        XCTAssertEqual(mailboxes.map(\.path), ["INBOX"])
        await client.disconnect()
    }

    func testCommandLiteralLimitAcceptsExactAndRejectsPlusOne() async throws {
        let limit = 8 << 20
        for bytes in [limit, limit + 1] {
            let peer = LocalIMAPPeerResponse(
                capabilities: ["IMAP4REV1", "AUTH=PLAIN", "X-GM-EXT-1"],
                mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox")],
                uidValidity: 1,
                messageUID: 1,
                messageData: Data("Subject: literal\r\n\r\nbody".utf8),
                providerMetadata: .init(stableID: "111", threadID: "222", labels: ["\\Inbox"]),
                metadataBehavior: .gmailLabelsLiteral(bytes: bytes)
            )
            let server = LocalIMAPServer(
                username: "me@example.com",
                password: "secret",
                message: PlainpostFixtures.aliceMessage,
                peer: peer
            )
            try await server.start()
            defer { server.stop() }

            let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
            try await client.login(username: "me@example.com", password: "secret")
            if bytes == limit {
                let header = try await client.fetchHeader(uid: 1)
                XCTAssertGreaterThanOrEqual(header.utf8.count, limit)
            } else {
                do {
                    _ = try await client.fetchHeader(uid: 1)
                    XCTFail("accepted command literal larger than the exact limit")
                } catch {
                    XCTAssertEqual(error as? IMAPClientError, .resourceLimit)
                }
            }
            await client.disconnect()
        }
    }

    func testMutationsNeverBroadExpungeUnrelatedDeletedMessages() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        try await client.delete(uid: 1)

        XCTAssertEqual(server.deletedUIDs, [1])
        XCTAssertEqual(server.expungeCount, 1)
        XCTAssertEqual(server.broadExpungeCount, 0)
    }

    func testIdleReportsMailboxChangeAndCompletesDoneHandshake() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage,
            supportsIdle: true,
            sendsIdleChange: true
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")
        let capabilities = try await client.capabilities()
        XCTAssertTrue(capabilities.contains("IDLE"))
        let outcome = try await client.idle(maxDuration: 2)
        XCTAssertEqual(outcome, .mailboxChanged)
        await client.disconnect()
    }

    func testIdleUsesPollingFallbackWhenCapabilityIsMissing() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")
        let outcome = try await client.idle(maxDuration: 1)
        XCTAssertEqual(outcome, .unsupported)
        await client.disconnect()
    }

    func testCancellingIdleClosesTheBlockingTransportPromptly() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage,
            supportsIdle: true
        )
        try await server.start()
        defer { server.stop() }
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")
        let startedAt = Date()
        let task = Task { try await client.idle(maxDuration: 300) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testStoppingServerTerminatesAlreadyAcceptedSession() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")

        server.stop()

        do {
            _ = try await client.listMailboxes()
            XCTFail("stopped server accepted a command on an existing connection")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .connectionFailed)
        }
    }

    func testStoppingServerFromSessionStartCallbackDoesNotDeadlock() async throws {
        let callbackEntered = DispatchSemaphore(value: 0)
        let callbackReturned = DispatchSemaphore(value: 0)
        let serverBox = LocalIMAPServerBox()
        let server = LocalIMAPServer(
            username: "callback-stop@example.com",
            password: "callback-stop-secret",
            message: PlainpostFixtures.aliceMessage,
            onSessionStart: {
                callbackEntered.signal()
                serverBox.server?.stop()
                callbackReturned.signal()
            }
        )
        serverBox.server = server
        try await server.start()
        defer {
            serverBox.server = nil
            server.stop()
        }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IMAPClientError.connectionFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = server.port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(descriptor)
            throw IMAPClientError.connectionFailed
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw IMAPClientError.connectionFailed
        }
        defer {
            if descriptor >= 0 {
                Darwin.shutdown(descriptor, SHUT_RDWR)
                Darwin.close(descriptor)
            }
        }

        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            callbackReturned.wait(timeout: .now() + 1),
            .success,
            "stop() must return when called inline by onSessionStart"
        )
    }

    func testStoppedServerCannotServeAReplacementThatReusesItsDescriptor() async throws {
        let sessionEnded = DispatchSemaphore(value: 0)
        let allowAcceptLoopToFinish = DispatchSemaphore(value: 0)
        let serverBox = LocalIMAPServerBox()
        let server = LocalIMAPServer(
            username: "same-instance@example.com",
            password: "same-instance-secret",
            message: PlainpostFixtures.aliceMessage,
            onSessionEnd: {
                serverBox.server?.stop()
                sessionEnded.signal()
                _ = allowAcceptLoopToFinish.wait(timeout: .now() + 2)
            }
        )
        serverBox.server = server
        try await server.start()
        defer {
            allowAcceptLoopToFinish.signal()
            serverBox.server = nil
            server.stop()
        }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "same-instance@example.com", password: "same-instance-secret")
        await client.disconnect()
        XCTAssertEqual(sessionEnded.wait(timeout: .now() + 2), .success)

        let restartCompleted = DispatchSemaphore(value: 0)
        let restart = Task {
            defer { restartCompleted.signal() }
            try await server.start()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            restartCompleted.wait(timeout: .now()),
            .timedOut,
            "restart must wait for the live previous accept loop"
        )

        allowAcceptLoopToFinish.signal()
        try await restart.value
        let replacement = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await replacement.login(username: "same-instance@example.com", password: "same-instance-secret")
        let messageUIDs = try await replacement.allMessageUIDs()
        XCTAssertEqual(messageUIDs, [1])
        await replacement.disconnect()
    }

    func testCanceledReplacementStartCannotServeAfterStoppedLoopUnwinds() async throws {
        let sessionEnded = DispatchSemaphore(value: 0)
        let allowAcceptLoopToFinish = DispatchSemaphore(value: 0)
        let serverBox = LocalIMAPServerBox()
        let server = LocalIMAPServer(
            username: "cancel-start@example.com",
            password: "cancel-start-secret",
            message: PlainpostFixtures.aliceMessage,
            onSessionEnd: {
                serverBox.server?.stop()
                sessionEnded.signal()
                _ = allowAcceptLoopToFinish.wait(timeout: .now() + 2)
            }
        )
        serverBox.server = server
        try await server.start()
        defer {
            allowAcceptLoopToFinish.signal()
            serverBox.server = nil
            server.stop()
        }

        do {
            try await server.start()
            XCTFail("duplicate start while running must fail promptly")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .connectionFailed)
        }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "cancel-start@example.com", password: "cancel-start-secret")
        await client.disconnect()
        XCTAssertEqual(sessionEnded.wait(timeout: .now() + 2), .success)

        let stoppedPort = server.port
        let replacementFinished = DispatchSemaphore(value: 0)
        let replacement = Task { () -> Result<Void, Error> in
            defer { replacementFinished.signal() }
            do {
                try await server.start()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            replacementFinished.wait(timeout: .now()),
            .timedOut,
            "replacement start must remain pending while the old loop is live"
        )

        let cancelStopFinished = DispatchSemaphore(value: 0)
        let cancelStop = Task {
            server.stop()
            cancelStopFinished.signal()
        }
        allowAcceptLoopToFinish.signal()
        XCTAssertEqual(cancelStopFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(replacementFinished.wait(timeout: .now() + 2), .success)
        if case .success = await replacement.value {
            XCTFail("stop-canceled replacement start must fail")
        }

        let staleClient = PlaintextIMAPClient(host: "127.0.0.1", port: stoppedPort)
        do {
            try await staleClient.login(
                username: "cancel-start@example.com",
                password: "cancel-start-secret"
            )
            XCTFail("a canceled replacement start must not serve the old port")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .unreachableBeforeCommand, "a sign-in that never connected")
        }
        await staleClient.disconnect()
        _ = await cancelStop.value
    }

    func testStoppingServerDuringActiveSessionReturnsClientFailure() async throws {
        let sessionEntered = DispatchSemaphore(value: 0)
        let sessionEnded = DispatchSemaphore(value: 0)
        let callbackGate = DispatchGroup()
        callbackGate.enter()
        let callbackReturned = LifecycleCompletionProbe()
        let stopCompleted = LifecycleCompletionProbe()
        let stopReturned = DispatchSemaphore(value: 0)
        let server = LocalIMAPServer(
            username: "race@example.com",
            password: "race-secret",
            message: PlainpostFixtures.aliceMessage,
            onSessionStart: {
                sessionEntered.signal()
                callbackGate.wait()
                callbackReturned.mark()
            },
            onSessionEnd: {
                sessionEnded.signal()
            }
        )
        try await server.start()
        defer { server.stop() }

        let clientBox = PlaintextIMAPClientBox(
            PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        )
        let loginFinished = DispatchSemaphore(value: 0)
        let loginOutcome = IMAPLoginOutcomeBox()
        let loginTask = Task {
            defer { loginFinished.signal() }
            do {
                try await clientBox.client.login(username: "race@example.com", password: "race-secret")
                loginOutcome.set(.success)
            } catch {
                loginOutcome.set(.failure(error))
            }
        }

        XCTAssertEqual(
            sessionEntered.wait(timeout: .now() + 2),
            .success,
            "the accept loop must claim the active session before stop races it"
        )
        DispatchQueue.global().async {
            server.stop()
            stopCompleted.mark()
            stopReturned.signal()
        }
        XCTAssertEqual(loginFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            stopCompleted.isCompleted,
            false,
            "stop must not return while onSessionStart is blocked"
        )
        XCTAssertEqual(callbackReturned.isCompleted, false)
        callbackGate.leave()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 2), .success)
        _ = await loginTask.value
        switch loginOutcome.get() {
        case .success:
            XCTFail("a login on an active session must fail after concurrent stop")
        case let .failure(error):
            XCTAssertEqual(error as? IMAPClientError, .unreachableBeforeCommand, "the sign-in was cut off")
        case nil:
            XCTFail("the login task did not publish an outcome")
        }
        await clientBox.client.disconnect()
        XCTAssertEqual(
            sessionEnded.wait(timeout: .now() + 2),
            .success,
            "stop must wait for the active session to finish"
        )

        // The same server instance must be reusable after the stopped
        // generation has fully unwound.
        try await server.start()
        let replacement = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await replacement.login(username: "race@example.com", password: "race-secret")
        let replacementUIDs = try await replacement.allMessageUIDs()
        XCTAssertEqual(replacementUIDs, [1])
        await replacement.disconnect()
    }

    func testSecureIMAPClientRejectsSelfSignedCertificateByDefault() async throws {
        let server = try LocalImplicitTLSIMAPServer(username: "me@example.com", password: "secret")
        try server.start()
        defer { server.stop() }

        let client = SecureIMAPClient(host: "127.0.0.1", port: server.port)

        do {
            try await client.login(username: "me@example.com", password: "secret")
            XCTFail("Expected self-signed certificate rejection.")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .tlsFailed)
        }
    }

    func testSecureIMAPClientUsesImplicitTLSHarnessWithExplicitTestTrustOverride() async throws {
        let server = try LocalImplicitTLSIMAPServer(username: "me@example.com", password: "secret")
        try server.start()
        defer { server.stop() }

        let client = SecureIMAPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )

        try await client.login(username: "me@example.com", password: "secret")
        let mailboxes = try await client.listMailboxes()
        let selected = try await client.selectMailbox("INBOX")
        let header = try await client.fetchHeader(uid: 1)
        let body = try await client.fetchBody(uid: 1)

        XCTAssertEqual(mailboxes.map(\.path), ["INBOX"])
        XCTAssertTrue(selected.contains("EXISTS"), selected)
        XCTAssertTrue(header.contains("Subject: TLS IMAP"), header)
        XCTAssertTrue(body.contains("Body over IMAP TLS."), body)
    }

    func testSecureIMAPClientEncodesCredentialsContainingSpacesQuotesAndBackslashes() async throws {
        let username = "user name@example.com"
        let password = "space quote\" slash\\ secret"
        let server = try LocalImplicitTLSIMAPServer(username: username, password: password)
        try server.start()
        defer { server.stop() }

        let client = SecureIMAPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )

        try await client.login(username: username, password: password)
    }

    func testSecureIMAPClientTimesOutWhenTLSIMAPServerWithholdsGreeting() async throws {
        let server = try LocalImplicitTLSIMAPServer(
            username: "me@example.com",
            password: "secret",
            withholdsGreeting: true
        )
        try server.start()
        defer { server.stop() }

        let client = SecureIMAPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )
        let startedAt = Date()

        do {
            try await client.login(username: "me@example.com", password: "secret")
            XCTFail("Expected the missing greeting to time out.")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .unreachableBeforeCommand, "a greeting that never came timed out before any command")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 31)
    }

    func testTLSIMAPClientsReportAClosedPortAsUnreachableWithoutHanging() async throws {
        let clients: [(String, @Sendable () -> any IMAPClientProtocol)] = [
            ("implicit TLS", { SecureIMAPClient(host: "127.0.0.1", port: 1, certificateValidation: .disabledForLocalTesting) }),
            ("STARTTLS", { StartTLSIMAPClient(host: "127.0.0.1", port: 1) }),
        ]
        for (label, makeClient) in clients {
            // A refused port used to block the first read forever: run the
            // login detached and give up waiting after a deadline, so a
            // regression fails instead of hanging the suite.
            let outcome = LockedIMAPLoginOutcome()
            let started = ContinuousClock.now
            Task.detached {
                do {
                    try await makeClient().login(username: "me@example.com", password: "secret")
                    outcome.set(.success)
                } catch {
                    outcome.set(.failure(error))
                }
            }
            let deadline = ContinuousClock.now + .seconds(45)
            while outcome.value == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            // A refused port fails at once; the 30 s open wait is only the
            // bound for a connection that never settles.
            XCTAssertLessThan(started.duration(to: .now), .seconds(10), "\(label): a refused port must not wait for the open bound")
            switch outcome.value {
            case nil:
                XCTFail("\(label): connecting to a closed port hung")
            case .success:
                XCTFail("\(label): expected a failure")
            case let .failure(error):
                XCTAssertEqual(error as? IMAPClientError, .unreachableBeforeCommand, "\(label): \(error)")
            }
        }
    }

    func testEveryIMAPClientTimesOutOnAServerThatAcceptsAndStaysSilent() async throws {
        let server = try SilentTCPServer(behavior: .holdOpen)
        defer { server.stop() }
        let port = server.port
        let clients: [(String, @Sendable () -> any IMAPClientProtocol)] = [
            ("plaintext", { PlaintextIMAPClient(host: "127.0.0.1", port: port, commandTimeout: 1) }),
            ("implicit TLS", { SecureIMAPClient(host: "127.0.0.1", port: port, certificateValidation: .disabledForLocalTesting, commandTimeout: 1) }),
            ("STARTTLS", { StartTLSIMAPClient(host: "127.0.0.1", port: port, certificateValidation: .disabledForLocalTesting, commandTimeout: 1) }),
        ]
        for (label, makeClient) in clients {
            let outcome = LockedIMAPLoginOutcome()
            let started = ContinuousClock.now
            Task.detached {
                do {
                    try await makeClient().login(username: "me@example.com", password: "secret")
                    outcome.set(.success)
                } catch {
                    outcome.set(.failure(error))
                }
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while outcome.value == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            switch outcome.value {
            case nil:
                XCTFail("\(label): a silent server hung the sign-in")
            case .success:
                XCTFail("\(label): expected a failure")
            case let .failure(error):
                XCTAssertEqual(error as? IMAPClientError, .unreachableBeforeCommand, "\(label): \(error)")
                XCTAssertLessThan(started.duration(to: .now), .seconds(10), "\(label): the 1 s read timeout applies from the first read")
            }
        }
    }

    func testASignInTheServerDropsIsUnreachableBeforeAnyCommand() async throws {
        let server = try SilentTCPServer(behavior: .closeOnAccept)
        defer { server.stop() }
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)

        do {
            try await client.login(username: "me@example.com", password: "secret")
            XCTFail("expected the dropped greeting to fail the sign-in")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .unreachableBeforeCommand)
        }
    }

    func testADropAfterAMutatingCommandWasSentStaysAConnectionFailure() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        server.stop()

        do {
            try await client.markRead(uid: 1)
            XCTFail("a stopped server accepted a STORE")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .connectionFailed, "the STORE may have acted: never 'before any command'")
        }
    }

    func testIMAPStreamErrorsAreClassedByDomain() {
        XCTAssertEqual(imapStreamErrorClass(domain: NSPOSIXErrorDomain, code: 61), .connectionFailed)
        XCTAssertEqual(imapStreamErrorClass(domain: kCFErrorDomainCFNetwork as String, code: 2), .connectionFailed)
        XCTAssertEqual(imapStreamErrorClass(domain: NSURLErrorDomain, code: -1004), .connectionFailed)
        XCTAssertEqual(imapStreamErrorClass(domain: NSOSStatusErrorDomain, code: -9807), .tlsFailed)
        XCTAssertEqual(imapStreamErrorClass(domain: NSOSStatusErrorDomain, code: Int(errSecNotTrusted)), .tlsFailed)
        XCTAssertEqual(imapStreamErrorClass(domain: kCFErrorDomainCFNetwork as String, code: -9813), .tlsFailed)
        XCTAssertEqual(imapStreamErrorClass(domain: NSURLErrorDomain, code: -1202), .tlsFailed)
        XCTAssertEqual(imapStreamErrorClass(domain: "SomethingElse", code: 1), .tlsFailed)
        XCTAssertEqual(imapStreamErrorClass(domain: NSOSStatusErrorDomain, code: -9806, handshakeCompleted: true), .connectionFailed,
                       "an established TLS session dropped is the network")
    }

    func testStartTLSIMAPClientUpgradesBeforeLoginAndUsesHarness() async throws {
        let server = try LocalSTARTTLSIMAPServer(username: "me@example.com", password: "secret")
        try server.start()
        defer { server.stop() }

        let client = StartTLSIMAPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )

        try await client.login(username: "me@example.com", password: "secret")
        let mailboxes = try await client.listMailboxes()
        let selected = try await client.selectMailbox("INBOX")
        let header = try await client.fetchHeader(uid: 1)
        let body = try await client.fetchBody(uid: 1)

        XCTAssertEqual(mailboxes.map(\.path), ["INBOX"])
        XCTAssertTrue(selected.contains("EXISTS"), selected)
        XCTAssertTrue(header.contains("Subject: STARTTLS IMAP"), header)
        XCTAssertTrue(body.contains("Body over IMAP STARTTLS."), body)
    }

    func testStartTLSIMAPClientEncodesCredentialsContainingSpacesQuotesAndBackslashes() async throws {
        let username = "user name@example.com"
        let password = "space quote\" slash\\ secret"
        let server = try LocalSTARTTLSIMAPServer(username: username, password: password)
        try server.start()
        defer { server.stop() }

        let client = StartTLSIMAPClient(
            host: "127.0.0.1",
            port: server.port,
            certificateValidation: .disabledForLocalTesting
        )

        try await client.login(username: username, password: password)
    }

    func testLoginSuccessListsSeededInbox() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")

        let mailboxes = try await client.listMailboxes()

        XCTAssertEqual(mailboxes.map(\.path), ["INBOX"])
    }

    func testLoginEncodesCredentialsContainingSpacesQuotesAndBackslashes() async throws {
        let username = "user name@example.com"
        let password = "space quote\" slash\\ secret"
        let server = LocalIMAPServer(
            username: username,
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: username, password: password)

        XCTAssertEqual(server.loginAttempts, [
            LocalIMAPLoginAttempt(username: username, password: password)
        ])
    }

    func testLoginAcceptsNonControlUnicodeCredentials() async throws {
        let username = "mélanie@example.com"
        let password = "秘密 🔐"
        let server = LocalIMAPServer(
            username: username,
            password: password,
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: username, password: password)

        XCTAssertEqual(server.loginAttempts, [
            LocalIMAPLoginAttempt(username: username, password: password)
        ])
    }

    func testLoginRejectsControlCharactersBeforeSendingLoginCommand() async throws {
        let cases: [(username: String, password: String)] = [
            ("user\r@example.com", "secret"),
            ("user\n@example.com", "secret"),
            ("user\0@example.com", "secret"),
            ("user\u{001F}@example.com", "secret"),
            ("user\u{007F}@example.com", "secret"),
            ("user\u{0085}@example.com", "secret"),
            ("me@example.com", "secret\r"),
            ("me@example.com", "secret\n"),
            ("me@example.com", "secret\0"),
            ("me@example.com", "secret\u{001F}"),
            ("me@example.com", "secret\u{007F}"),
            ("me@example.com", "secret\u{0085}")
        ]

        for credentials in cases {
            let server = LocalIMAPServer(
                username: "me@example.com",
                password: "secret",
                message: PlainpostFixtures.aliceMessage
            )
            try await server.start()

            let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
            do {
                try await client.login(username: credentials.username, password: credentials.password)
                XCTFail("Expected a protocol error for control-character credentials.")
            } catch {
                XCTAssertEqual(
                    error as? IMAPClientError,
                    .protocolError("IMAP login credentials cannot contain control characters.")
                )
            }

            XCTAssertEqual(server.loginCommandCount, 0)
            await client.disconnect()
            server.stop()
        }
    }

    func testLoginTreatsNOStatusAsAuthenticationFailureWithoutRetainingEchoedCredentials() async throws {
        let username = "private-user@example.com"
        let password = "private-password"
        let server = LocalIMAPServer(
            username: username,
            password: password,
            message: PlainpostFixtures.aliceMessage,
            forcedLoginResponse: "NO \(username) \(password)"
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        do {
            try await client.login(username: username, password: password)
            XCTFail("Expected an authentication failure.")
        } catch IMAPClientError.authenticationFailed {
            // Expected fixed classification with no associated response text.
        } catch {
            XCTFail("Expected an authentication failure without retained response text.")
        }
    }

    func testLoginRejectsBADOtherAndMalformedStatusesWithoutRetainingEchoedCredentials() async throws {
        let username = "private-user@example.com"
        let password = "private-password"
        let responses = [
            "BAD \(username) \(password)",
            "BROKEN text containing OK and NO \(username) \(password)",
            "OKAY text containing OK \(username) \(password)",
            ""
        ]

        for response in responses {
            let server = LocalIMAPServer(
                username: username,
                password: password,
                message: PlainpostFixtures.aliceMessage,
                forcedLoginResponse: response
            )
            try await server.start()

            let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
            do {
                try await client.login(username: username, password: password)
                XCTFail("Expected a fixed protocol error for an invalid LOGIN status.")
            } catch IMAPClientError.protocolError(let message) {
                if message != "Malformed IMAP LOGIN response." {
                    XCTFail("Expected a fixed protocol error without retained response text.")
                }
                XCTAssertFalse(message.contains(username))
                XCTAssertFalse(message.contains(password))
            } catch {
                XCTFail("Expected a fixed protocol error for an invalid LOGIN status.")
            }

            await client.disconnect()
            server.stop()
        }
    }

    func testLoginArgumentParsersRejectMalformedQuotedStrings() throws {
        let malformedArguments = [
            #""user" "bad\x""#,
            #""user""password""#,
            #""user" "password" trailing"#,
            #""user" "unterminated"#,
            "\"user\"\t\"password\"",
            "\"user\"  \"password\"",
            "\"user\" \"bad\u{007F}\""
        ]

        for arguments in malformedArguments {
            XCTAssertNil(LocalIMAPLoginArgumentParser.parse(arguments))
            XCTAssertTrue(try pythonLoginParserRejects(arguments))
        }
    }

    private func pythonLoginParserRejects(_ arguments: String) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = [
            "-c",
            pythonIMAPLoginParserSource + "\nimport sys\nraise SystemExit(0 if parse_login_arguments(sys.argv[1]) is None else 1)",
            arguments
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    func testLoginFailureReturnsAuthError() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)

        do {
            try await client.login(username: "me@example.com", password: "wrong")
            XCTFail("Expected auth failure")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .authenticationFailed)
        }
    }

    func testLoginTreatsConnectionLimitNOAsAuthenticationFailureWithoutRetainingRawResponse() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage,
            forcedLoginFailure: "[ALERT] Too many simultaneous connections. (Failure)"
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        do {
            try await client.login(username: "me@example.com", password: "secret")
            XCTFail("Expected authentication rejection")
        } catch IMAPClientError.authenticationFailed {
            // Expected: LOGIN NO has one fixed classification.
        } catch {
            XCTFail("Expected authentication rejection without retained response text.")
        }
    }

    func testLoginTreatsThrottlingNOAsAuthenticationFailureWithoutRetainingRawResponse() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage,
            forcedLoginFailure: "[RATE] Account exceeded command or bandwidth limits"
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        do {
            try await client.login(username: "me@example.com", password: "secret")
            XCTFail("Expected authentication rejection")
        } catch IMAPClientError.authenticationFailed {
            // Expected: LOGIN NO has one fixed classification.
        } catch {
            XCTFail("Expected authentication rejection without retained response text.")
        }
    }

    func testFetchHeaderAndBodyReturnsSeededMessage() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        let header = try await client.fetchHeader(uid: 1)
        let body = try await client.fetchBody(uid: 1)

        XCTAssertTrue(header.contains("From: alice@example.com"))
        XCTAssertTrue(header.contains("Subject: Availability"))
        XCTAssertTrue(body.contains("Can you meet next Tuesday?"))
    }

    func testMarkReadAndUnreadMutateSeenFlagOnServer() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        try await client.markUnread(uid: 1)
        let unreadHeader = try await client.fetchHeader(uid: 1)
        XCTAssertFalse(unreadHeader.contains("\\Seen"))

        try await client.markRead(uid: 1)
        let readHeader = try await client.fetchHeader(uid: 1)
        XCTAssertTrue(readHeader.contains("\\Seen"))
    }

    func testArchiveCopiesToArchiveAndExpungesInboxMessage() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        try await client.archive(uid: 1, archiveMailbox: "Archive")

        XCTAssertEqual(server.archivedUIDs, [1])
        XCTAssertTrue(server.deletedUIDs.contains(1))
        XCTAssertEqual(server.expungeCount, 1)
    }

    func testDeleteMarksDeletedAndExpungesMessage() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        try await client.delete(uid: 1)

        XCTAssertEqual(server.deletedUIDs, [1])
        XCTAssertEqual(server.expungeCount, 1)
    }

    private func trashServer(capabilities: [String], mailboxes: [LocalIMAPPeerResponse.Mailbox]) -> LocalIMAPServer {
        LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage,
            peer: LocalIMAPPeerResponse(
                capabilities: capabilities,
                mailboxes: [.init(path: "INBOX", specialUse: "\\Inbox")] + mailboxes,
                uidValidity: 7,
                messageUID: 1,
                messageData: Data("Subject: Trash me\r\n\r\nbody".utf8)
            )
        )
    }

    func testGmailMoveToTrashUsesUIDMoveAndReportsTheNewUID() async throws {
        let server = trashServer(
            capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE", "X-GM-EXT-1"],
            mailboxes: [.init(path: "[Gmail]/Trash", specialUse: "\\Trash")]
        )
        try await server.start()
        defer { server.stop() }
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        let result = try await client.move(uid: 1, to: "[Gmail]/Trash")

        XCTAssertEqual(result, IMAPMoveResult(mailbox: "[Gmail]/Trash", uidValidity: 7, uid: 501))
        XCTAssertEqual(server.uidCommands, [#"MOVE 1 "[Gmail]/Trash""#], "one quoted UID MOVE")
        XCTAssertEqual(server.moves, [LocalIMAPCopyAttempt(uid: 1, mailbox: "[Gmail]/Trash")])
        XCTAssertTrue(server.copyAttempts.isEmpty)
        XCTAssertTrue(server.deletedUIDs.isEmpty, "a move is not an erase")
        XCTAssertEqual(server.broadExpungeCount, 0)
        let remaining = try await client.allMessageUIDs()
        XCTAssertEqual(remaining, [], "the message left the Inbox")
    }

    func testMoveWithoutMOVECopiesToQuotedMailboxThenExpungesOnlyThatUID() async throws {
        let server = trashServer(
            capabilities: ["IMAP4rev1", "UIDPLUS"],
            mailboxes: [.init(path: "Deleted Messages", specialUse: "\\Trash")]
        )
        try await server.start()
        defer { server.stop() }
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        let result = try await client.move(uid: 1, to: "Deleted Messages")

        XCTAssertEqual(result, IMAPMoveResult(mailbox: "Deleted Messages", uidValidity: nil, uid: nil))
        // Quoted, and the copy lands before the source copy is marked and expunged.
        XCTAssertEqual(server.uidCommands, [
            #"COPY 1 "Deleted Messages""#,
            #"STORE 1 +FLAGS.SILENT (\Deleted)"#,
            "EXPUNGE 1",
        ])
        XCTAssertEqual(server.copyAttempts, [LocalIMAPCopyAttempt(uid: 1, mailbox: "Deleted Messages")])
        XCTAssertEqual(server.deletedUIDs, [1])
        XCTAssertEqual(server.expungeCount, 1)
        XCTAssertEqual(server.broadExpungeCount, 0)
    }

    func testMoveWithoutMOVEOrUIDPLUSFailsBeforeTouchingTheMessage() async throws {
        let server = trashServer(
            capabilities: ["IMAP4rev1"],
            mailboxes: [.init(path: "Trash", specialUse: "\\Trash")]
        )
        try await server.start()
        defer { server.stop() }
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        do {
            _ = try await client.move(uid: 1, to: "Trash")
            XCTFail("a move the server can't finish must refuse up front")
        } catch is IMAPClientError {}

        XCTAssertTrue(server.copyAttempts.isEmpty)
        XCTAssertTrue(server.storeCommands.isEmpty)
        XCTAssertEqual(server.expungeCount, 0)
        let remaining = try await client.allMessageUIDs()
        XCTAssertEqual(remaining, [1])
    }

    func testRefusedMoveLeavesTheMessageInPlace() async throws {
        let server = trashServer(capabilities: ["IMAP4rev1", "UIDPLUS", "MOVE"], mailboxes: [])
        try await server.start()
        defer { server.stop() }
        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")
        _ = try await client.selectMailbox("INBOX")

        do {
            _ = try await client.move(uid: 1, to: "Trash")
            XCTFail("a NO [TRYCREATE] must surface")
        } catch let IMAPClientError.protocolError(line) {
            XCTAssertTrue(line.contains("TRYCREATE"), line)
        }

        XCTAssertTrue(server.moves.isEmpty)
        XCTAssertEqual(server.expungeCount, 0)
        let remaining = try await client.allMessageUIDs()
        XCTAssertEqual(remaining, [1])
    }

    func testAppendMessageStoresRemoteSentMessage() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")

        let result = try await client.appendMessage(
            to: "Sent",
            flags: ["\\Seen"],
            data: "Subject: Remote Sent\r\n\r\nSaved remotely."
        )

        XCTAssertEqual(result.mailbox, "Sent")
        XCTAssertEqual(result.uid, 1001)
        let appended = server.appendedMessages
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended[0].uid, 1001)
        XCTAssertEqual(appended[0].mailbox, "Sent")
        XCTAssertEqual(appended[0].flags, ["\\Seen"])
        XCTAssertTrue(appended[0].data.contains("Subject: Remote Sent"))
        XCTAssertTrue(appended[0].data.contains("Saved remotely."))
    }

    func testAppendMessageSupportsMailboxNamesWithSpaces() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")

        try await client.appendMessage(
            to: "Sent Items",
            flags: ["\\Seen"],
            data: "Subject: Remote Sent Items\r\n\r\nSaved remotely."
        )

        let appended = server.appendedMessages
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended[0].mailbox, "Sent Items")
        XCTAssertEqual(appended[0].flags, ["\\Seen"])
        XCTAssertTrue(appended[0].data.contains("Subject: Remote Sent Items"))
    }

    func testAppendMessageRejectsMailboxNamesWithControlCharacters() async throws {
        let server = LocalIMAPServer(
            username: "me@example.com",
            password: "secret",
            message: PlainpostFixtures.aliceMessage
        )
        try await server.start()
        defer { server.stop() }

        let client = PlaintextIMAPClient(host: "127.0.0.1", port: server.port)
        try await client.login(username: "me@example.com", password: "secret")

        do {
            try await client.appendMessage(
                to: "Sent\r\nA002 LOGOUT",
                flags: ["\\Seen"],
                data: "Subject: Invalid mailbox\r\n\r\nShould not append."
            )
            XCTFail("Expected control-character mailbox name to be rejected.")
        } catch {
            XCTAssertEqual(error as? IMAPClientError, .protocolError("Mailbox names cannot contain control characters."))
        }

        XCTAssertEqual(server.appendedMessages, [])
    }
}

private actor IdleTestVaultKeyProvider: VaultKeyProvider {
    private let key = Data(repeating: 0x49, count: 32)

    func createIfMissing() async throws {}
    func load(interactive: Bool, prompt: String?) async throws -> Data? { key }
    func countMatchingItems() async throws -> Int { 1 }
}

private actor IdleFallbackSignalRecorder {
    private(set) var values: [AccountID] = []
    var count: Int { values.count }

    func record(_ accountID: AccountID) {
        values.append(accountID)
    }
}

private actor IdleInitialSignalBarrier {
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivalCount += 1
        guard arrivalCount < 2 else {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class IdleFallbackClock: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var recordedDurations: [Duration] = []
    private var waiters: [Waiter] = []

    var durations: [Duration] { lock.withLock { recordedDurations } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    recordedDurations.append(duration)
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            self.cancel(id: id)
        }
        try Task.checkCancellation()
    }

    func resumeNext() {
        let waiter = lock.withLock {
            waiters.isEmpty ? nil : waiters.removeFirst()
        }
        waiter?.continuation.resume()
    }

    private func cancel(id: UUID) {
        let waiter = lock.withLock { () -> Waiter? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume()
    }
}

private final class LocalIMAPServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: LocalIMAPServer?

    var server: LocalIMAPServer? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class PlaintextIMAPClientBox: @unchecked Sendable {
    let client: PlaintextIMAPClient

    init(_ client: PlaintextIMAPClient) {
        self.client = client
    }
}

private final class IMAPLoginOutcomeBox: @unchecked Sendable {
    enum Outcome {
        case success
        case failure(Error)
    }

    private let lock = NSLock()
    private var outcome: Outcome?

    func set(_ outcome: Outcome) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    func get() -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

private final class LifecycleCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func mark() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

private let pythonIMAPLoginParserSource = #"""
import unicodedata

def parse_login_arguments(arguments):
    if any(unicodedata.category(character) == "Cc" for character in arguments):
        return None

    def parse_argument(index):
        if index >= len(arguments):
            return None

        if arguments[index] != '"':
            start = index
            atom_specials = set('(){} %*"\\]')
            while index < len(arguments) and arguments[index] not in atom_specials:
                index += 1
            return (arguments[start:index], index) if start != index else None

        index += 1
        value = []
        while index < len(arguments):
            character = arguments[index]
            index += 1
            if character == '\\':
                if index == len(arguments):
                    return None
                escaped = arguments[index]
                if escaped not in ('"', '\\'):
                    return None
                value.append(escaped)
                index += 1
            elif character == '"':
                return ("".join(value), index)
            else:
                value.append(character)
        return None

    username = parse_argument(0)
    if username is None or username[1] >= len(arguments) or arguments[username[1]] != " ":
        return None
    password = parse_argument(username[1] + 1)
    if password is None or password[1] != len(arguments):
        return None
    return [username[0], password[0]]
"""#

final class LocalImplicitTLSIMAPServer {
    private let username: String
    private let password: String
    private let withholdsGreeting: Bool
    private let tempDirectory: URL
    private let portFile: URL
    private let certificateFile: URL
    private let keyFile: URL
    private var process: Process?

    private(set) var port: UInt16 = 0

    init(username: String, password: String, withholdsGreeting: Bool = false) throws {
        self.username = username
        self.password = password
        self.withholdsGreeting = withholdsGreeting
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-tls-imap-\(UUID().uuidString)", isDirectory: true)
        portFile = tempDirectory.appendingPathComponent("port.txt")
        certificateFile = tempDirectory.appendingPathComponent("cert.pem")
        keyFile = tempDirectory.appendingPathComponent("key.pem")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try generateCertificate()
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = [
            "-u",
            "-c",
            Self.pythonServerScript,
            certificateFile.path,
            keyFile.path,
            portFile.path,
            username,
            password,
            withholdsGreeting ? "1" : "0"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let portText = try? String(contentsOf: portFile, encoding: .utf8),
               let parsedPort = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                port = parsedPort
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop()
        throw IMAPClientError.connectionFailed
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func generateCertificate() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/openssl")
        process.arguments = [
            "req",
            "-x509",
            "-newkey", "rsa:2048",
            "-nodes",
            "-keyout", keyFile.path,
            "-out", certificateFile.path,
            "-days", "1",
            "-subj", "/CN=localhost"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IMAPClientError.connectionFailed
        }
    }

    private static let pythonServerScript = #"""
import socket
import ssl
import sys
import time

\#(pythonIMAPLoginParserSource)

cert_path, key_path, port_path, username, password, withholds_greeting = sys.argv[1:]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certfile=cert_path, keyfile=key_path)
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_path, "w", encoding="utf-8") as port_file:
    port_file.write(str(server.getsockname()[1]))
    port_file.flush()

conn, _ = server.accept()
try:
    with context.wrap_socket(conn, server_side=True) as tls:
        stream = tls.makefile("rwb", buffering=0)

        if withholds_greeting == "1":
            time.sleep(32)
            raise SystemExit(0)

        def write_line(line):
            stream.write((line + "\r\n").encode("utf-8"))

        def read_line():
            data = stream.readline()
            if not data:
                raise SystemExit(20)
            return data.decode("utf-8").rstrip("\r\n")

        write_line("* OK Plainpost TLS IMAP ready")
        selected = False
        while True:
            line = read_line()
            parts = line.split(" ", 2)
            if len(parts) < 2:
                raise SystemExit(21)
            tag = parts[0]
            command = parts[1].upper()
            rest = parts[2] if len(parts) > 2 else ""

            if command == "LOGIN":
                login = parse_login_arguments(rest)
                if login == [username, password]:
                    write_line(tag + " OK LOGIN completed")
                else:
                    write_line(tag + " NO LOGIN failed")
            elif command == "LIST":
                write_line('* LIST (\\Inbox) "/" "INBOX"')
                write_line(tag + " OK LIST completed")
            elif command == "SELECT":
                selected = True
                write_line("* 1 EXISTS")
                write_line("* OK [UIDVALIDITY 7] UIDs valid")
                write_line(tag + " OK [READ-WRITE] SELECT completed")
            elif command == "UID" and rest.upper().startswith("FETCH 1"):
                if not selected:
                    write_line(tag + " NO SELECT required")
                elif "HEADER.FIELDS" in rest.upper():
                    if "X-PLAINPOST-ACCOUNT-VERIFICATION" not in rest.upper():
                        write_line(tag + " BAD verification marker header must be requested")
                        continue
                    write_line("* 1 FETCH (UID 1 FLAGS (\\Seen) BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {74}")
                    write_line("From: alice@example.com")
                    write_line("Subject: TLS IMAP")
                    write_line("Date: Thu, 9 Jul 2026 08:00:00 +0200")
                    write_line(")")
                    write_line(tag + " OK UID FETCH completed")
                elif "BODY.PEEK[]" not in rest.upper():
                    write_line(tag + " BAD body fetch must not set the Seen flag")
                else:
                    write_line("* 1 FETCH (UID 1 BODY[] {58}")
                    write_line("From: alice@example.com")
                    write_line("Subject: TLS IMAP")
                    write_line("")
                    write_line("Body over IMAP TLS.")
                    write_line(")")
                    write_line(tag + " OK UID FETCH completed")
            elif command == "LOGOUT":
                write_line("* BYE")
                write_line(tag + " OK LOGOUT completed")
                break
            else:
                write_line(tag + " BAD unsupported")
finally:
    server.close()
"""#
}

private final class LocalSTARTTLSIMAPServer {
    private let username: String
    private let password: String
    private let tempDirectory: URL
    private let portFile: URL
    private let certificateFile: URL
    private let keyFile: URL
    private var process: Process?

    private(set) var port: UInt16 = 0

    init(username: String, password: String) throws {
        self.username = username
        self.password = password
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-starttls-imap-\(UUID().uuidString)", isDirectory: true)
        portFile = tempDirectory.appendingPathComponent("port.txt")
        certificateFile = tempDirectory.appendingPathComponent("cert.pem")
        keyFile = tempDirectory.appendingPathComponent("key.pem")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        try generateCertificate()
    }

    func start() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = [
            "-u",
            "-c",
            Self.pythonServerScript,
            certificateFile.path,
            keyFile.path,
            portFile.path,
            username,
            password
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let portText = try? String(contentsOf: portFile, encoding: .utf8),
               let parsedPort = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                port = parsedPort
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop()
        throw IMAPClientError.connectionFailed
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func generateCertificate() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/openssl")
        process.arguments = [
            "req",
            "-x509",
            "-newkey", "rsa:2048",
            "-nodes",
            "-keyout", keyFile.path,
            "-out", certificateFile.path,
            "-days", "1",
            "-subj", "/CN=localhost"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw IMAPClientError.connectionFailed
        }
    }

    private static let pythonServerScript = #"""
import socket
import ssl
import sys

\#(pythonIMAPLoginParserSource)

cert_path, key_path, port_path, username, password = sys.argv[1:]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certfile=cert_path, keyfile=key_path)
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_path, "w", encoding="utf-8") as port_file:
    port_file.write(str(server.getsockname()[1]))
    port_file.flush()

conn, _ = server.accept()
try:
    stream = conn.makefile("rwb", buffering=0)

    def write_line(line):
        stream.write((line + "\r\n").encode("utf-8"))

    def read_line():
        data = stream.readline()
        if not data:
            raise SystemExit(20)
        return data.decode("utf-8").rstrip("\r\n")

    write_line("* OK Plainpost STARTTLS IMAP ready")
    line = read_line()
    parts = line.split(" ", 2)
    if len(parts) < 2 or parts[1].upper() != "STARTTLS":
        tag = parts[0] if parts else "A000"
        write_line(tag + " BAD STARTTLS required before authentication")
        raise SystemExit(21)
    tag = parts[0]
    write_line(tag + " OK Begin TLS negotiation now")

    with context.wrap_socket(conn, server_side=True) as tls:
        stream = tls.makefile("rwb", buffering=0)
        selected = False

        while True:
            line = read_line()
            parts = line.split(" ", 2)
            if len(parts) < 2:
                raise SystemExit(22)
            tag = parts[0]
            command = parts[1].upper()
            rest = parts[2] if len(parts) > 2 else ""

            if command == "LOGIN":
                login = parse_login_arguments(rest)
                if login == [username, password]:
                    write_line(tag + " OK LOGIN completed")
                else:
                    write_line(tag + " NO LOGIN failed")
            elif command == "LIST":
                write_line('* LIST (\\Inbox) "/" "INBOX"')
                write_line(tag + " OK LIST completed")
            elif command == "SELECT":
                selected = True
                write_line("* 1 EXISTS")
                write_line("* OK [UIDVALIDITY 9] UIDs valid")
                write_line(tag + " OK [READ-WRITE] SELECT completed")
            elif command == "UID" and rest.upper().startswith("FETCH 1"):
                if not selected:
                    write_line(tag + " NO SELECT required")
                elif "HEADER.FIELDS" in rest.upper():
                    write_line("* 1 FETCH (UID 1 FLAGS (\\Seen) BODY[HEADER.FIELDS (FROM SUBJECT DATE)] {79}")
                    write_line("From: alice@example.com")
                    write_line("Subject: STARTTLS IMAP")
                    write_line("Date: Thu, 9 Jul 2026 08:30:00 +0200")
                    write_line(")")
                    write_line(tag + " OK UID FETCH completed")
                elif "BODY.PEEK[]" not in rest.upper():
                    write_line(tag + " BAD body fetch must not set the Seen flag")
                else:
                    write_line("* 1 FETCH (UID 1 BODY[] {68}")
                    write_line("From: alice@example.com")
                    write_line("Subject: STARTTLS IMAP")
                    write_line("")
                    write_line("Body over IMAP STARTTLS.")
                    write_line(")")
                    write_line(tag + " OK UID FETCH completed")
            elif command == "LOGOUT":
                write_line("* BYE")
                write_line(tag + " OK LOGOUT completed")
                break
            else:
                write_line(tag + " BAD unsupported")
finally:
    server.close()
"""#
}

private final class LockedIMAPLoginOutcome: @unchecked Sendable {
    enum Outcome { case success, failure(Error) }
    private let lock = NSLock()
    private var stored: Outcome?
    var value: Outcome? { lock.withLock { stored } }
    func set(_ outcome: Outcome) { lock.withLock { stored = outcome } }
}
