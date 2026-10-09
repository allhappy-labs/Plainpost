import Darwin
import Foundation
import XCTest
import PlainpostBrowserIntegration
import PlainpostCore
import PlainpostDB
import PlainpostLocalAPI
import PlainpostLocalServer
import PlainpostOperationRuntime
import PlainpostOperations
import PlainpostSecrets
import PlainpostTestSupport

final class BrowserExtensionLocalAPITests: XCTestCase, @unchecked Sendable {
    func testOverlappingIncrementalRoutesPerformOneLocalIMAPSync() async throws {
        let fixture = try await BrowserExtensionLocalAPIFixture.make()
        defer { XCTAssertNoThrow(try fixture.stop()) }
        let loginCountBeforeSync = fixture.imap.loginAttempts.count
        let route = IncrementalSyncAllRoute(
            accountIDs: { [fixture.accountID] },
            syncer: LocalOperationClient(runtime: fixture.runtime)
        )

        async let first = Self.invokeIncrementalSync(route)
        async let second = Self.invokeIncrementalSync(route)
        let results = try await [first, second]

        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[0].completedAccountIDs, [fixture.accountID.rawValue])
        XCTAssertEqual(fixture.imap.loginAttempts.count, loginCountBeforeSync + 1)
        let syncJobs = try fixture.store.jobs(limit: 100).filter { job in
            guard let input = try? JSONDecoder().decode(
                PlainpostInboxSyncInput.self,
                from: Data(job.payloadJSON.utf8)
            ) else { return false }
            return input.accountID == fixture.accountID && input.scope == .incremental
        }
        XCTAssertEqual(syncJobs.count, 1)
    }

    func testLocalMailWorkflowThroughNativeBridgeFrames() async throws {
        let fixture = try await BrowserExtensionLocalAPIFixture.make()
        defer { XCTAssertNoThrow(try fixture.stop()) }
        let bridge = TestUnlockedNativeBridge(
            socketURL: fixture.localAPISocketURL
        )

        let unread: LocalAPIUnreadListResult = try bridge.request(
            method: .mailUnreadList,
            parameters: LocalAPIUnreadListParameters(limit: 10)
        )
        XCTAssertEqual(unread.messages.count, 1)
        XCTAssertFalse(try XCTUnwrap(fixture.store.messageSummary(id: fixture.messageID)).isSeen)

        let opened: LocalAPIMessageDetail = try bridge.request(
            method: .mailOpen,
            parameters: LocalAPIOpenMessageParameters(messageID: fixture.messageID.rawValue)
        )
        XCTAssertTrue(opened.isSeen)
        XCTAssertTrue(try XCTUnwrap(fixture.store.messageSummary(id: fixture.messageID)).isSeen)

        let mailboxFlagJob = try XCTUnwrap(
            try fixture.store.job(
                idempotencyKey: "mailbox-flag:\(fixture.accountID.rawValue):INBOX:1:1:\(fixture.messageID.rawValue):true"
            )
        )
        _ = try await fixture.runtime.runUntilTerminal(jobID: mailboxFlagJob.id)
        let imap = PlaintextIMAPClient(host: "127.0.0.1", port: fixture.imap.port)
        try await imap.login(username: fixture.username, password: fixture.password)
        _ = try await imap.selectMailbox("INBOX")
        let remoteHeader = try await imap.fetchHeader(uid: 1)
        XCTAssertTrue(remoteHeader.contains("\\Seen"))
        await imap.disconnect()

        let summary: LocalAPISummaryResult = try bridge.request(
            method: .aiSummarize,
            parameters: LocalAPIAISummarizeParameters(messageID: fixture.messageID.rawValue)
        )
        XCTAssertFalse(summary.summary.isEmpty)

        let initialDraft: LocalAPIDraftResult = try bridge.request(
            method: .replyBegin,
            parameters: LocalAPIReplyBeginParameters(messageID: fixture.messageID.rawValue)
        )
        let aiDraft: LocalAPIDraftResult = try bridge.request(
            method: .aiDraftReply,
            parameters: LocalAPIAIDraftReplyParameters(
                draftID: initialDraft.id,
                messageID: fixture.messageID.rawValue,
                instruction: "Confirm Friday and thank Maya",
                expectedHash: initialDraft.contentHash
            )
        )
        XCTAssertTrue(aiDraft.body.contains("Friday"))

        let sendParameters = LocalAPISendParameters(
            draftID: aiDraft.id,
            expectedHash: aiDraft.contentHash,
            idempotencyKey: "browser-local-e2e-send"
        )
        let delivery: LocalAPIDeliveryResult = try bridge.request(
            method: .replySend,
            parameters: sendParameters
        )
        XCTAssertEqual(delivery.state, .sent)
        let acceptedAfterSend = await fixture.smtp.acceptedMessages()
        XCTAssertEqual(acceptedAfterSend.count, 1)

        let replayed: LocalAPIDeliveryResult = try bridge.request(
            method: .replySend,
            parameters: sendParameters
        )
        XCTAssertEqual(replayed, delivery)
        let acceptedAfterReplay = await fixture.smtp.acceptedMessages()
        XCTAssertEqual(acceptedAfterReplay.count, 1)

        let mcpOutputs = try MCPEmailReadProcess.invokeTwice(messageID: MessageID("msg_alice_1"))
        XCTAssertEqual(mcpOutputs.count, 2, mcpOutputs.joined(separator: "\n"))
        for output in mcpOutputs {
            XCTAssertTrue(output.contains(#""message":{"body":"Can you meet next Tuesday?""#), output)
            XCTAssertTrue(output.contains(#""seen":false"#), output)
        }
        let descriptor = try XCTUnwrap(
            MCPToolRegistry.default.tools.first { $0.name == "email.read" }
        )
        XCTAssertTrue(descriptor.annotations.readOnlyHint)
    }

    private static func invokeIncrementalSync(
        _ route: IncrementalSyncAllRoute
    ) async throws -> LocalAPISyncResult {
        let requestID = UUID().uuidString
        let request = LocalAPIRequest(
            requestID: requestID,
            method: .syncIncrementalAll,
            parameters: LocalAPIEmptyParameters()
        )
        let response = try await route.handle(
            requestData: JSONEncoder().encode(request),
            requestID: requestID
        )
        return try JSONDecoder().decode(
            LocalAPISuccess<LocalAPISyncResult>.self,
            from: response
        ).result
    }

    func testFixtureCleanupRemovesOnlyItsOwnedChild() async throws {
        let coordinationRoot = try makeTemporaryDirectory(prefix: "plainpost-browser-coordination")
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let sentinel = coordinationRoot.appendingPathComponent("caller-sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)

        let fixture = try await BrowserExtensionLocalAPIFixture.make(rootURL: coordinationRoot)
        let ownedRoot = fixture.rootURL
        XCTAssertEqual(ownedRoot.deletingLastPathComponent(), coordinationRoot.resolvingSymlinksInPath())
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedRoot.path))

        try fixture.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: coordinationRoot.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
    }

    func testOwnedFixtureDirectoryRejectsUnsafeRootsAliasesAndPreexistingChildren() throws {
        let fileManager = FileManager.default
        let coordinationRoot = try makeTemporaryDirectory(prefix: "plainpost-browser-safety")
        defer { try? fileManager.removeItem(at: coordinationRoot) }
        let sentinel = coordinationRoot.appendingPathComponent("caller-sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)
        let childName = "ebe-fixed"
        let preexistingChild = coordinationRoot.appendingPathComponent(childName, isDirectory: true)
        try fileManager.createDirectory(at: preexistingChild, withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try OwnedFixtureDirectory.create(
                coordinationRootURL: coordinationRoot,
                childName: childName
            )
        )
        XCTAssertTrue(fileManager.fileExists(atPath: preexistingChild.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))

        let alias = coordinationRoot.deletingLastPathComponent()
            .appendingPathComponent("plainpost-browser-alias-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: coordinationRoot)
        defer { try? fileManager.removeItem(at: alias) }
        XCTAssertThrowsError(
            try OwnedFixtureDirectory.create(
                coordinationRootURL: alias,
                childName: "ebe-alias"
            )
        )

        let unsafeRoots = [
            URL(fileURLWithPath: "/", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
        ]
        for unsafeRoot in unsafeRoots {
            XCTAssertThrowsError(
                try OwnedFixtureDirectory.create(
                    coordinationRootURL: unsafeRoot,
                    childName: "ebe-unsafe"
                ),
                unsafeRoot.path
            )
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
    }

    func testOwnedFixtureDirectoryReportsExternalRenameWithoutDeletingRenamedChild() throws {
        let coordinationRoot = try makeTemporaryDirectory(prefix: "plainpost-browser-rename")
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let ownedDirectory = try OwnedFixtureDirectory.create(
            coordinationRootURL: coordinationRoot,
            childName: "ebe-rename"
        )
        let renamedURL = coordinationRoot.appendingPathComponent("caller-renamed-child")
        try FileManager.default.moveItem(at: ownedDirectory.rootURL, to: renamedURL)

        XCTAssertThrowsError(try ownedDirectory.remove()) { error in
            guard case NativeBridgeTestError.fixtureDirectoryChanged = error else {
                return XCTFail("Expected fixture directory identity failure, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
    }

    func testOwnedReadyMarkerRefusesReplacementDirectoryWithoutDeletingCallerContent() throws {
        let coordinationRoot = try makeTemporaryDirectory(prefix: "plainpost-browser-marker")
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let markerURL = coordinationRoot.appendingPathComponent("ready")
        let marker = try OwnedCoordinationMarker.create(
            at: markerURL,
            contents: Data("fixture-root".utf8)
        )
        try FileManager.default.removeItem(at: markerURL)
        try FileManager.default.createDirectory(at: markerURL, withIntermediateDirectories: false)
        let sentinel = markerURL.appendingPathComponent("caller-sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)

        XCTAssertThrowsError(try marker.remove()) { error in
            guard case NativeBridgeTestError.fixtureDirectoryChanged = error else {
                return XCTFail("Expected marker identity failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
    }

    func testFixtureSetupFailureRollsBackCredentialsServersAndOwnedDirectory() async throws {
        let coordinationRoot = try makeTemporaryDirectory(prefix: "plainpost-browser-rollback")
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let sentinel = coordinationRoot.appendingPathComponent("caller-sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)
        let credentials = InMemoryCredentialVault()
        do {
            _ = try await BrowserExtensionLocalAPIFixture.make(
                rootURL: coordinationRoot,
                credentials: credentials,
                failAt: .afterCredentialsSaved
            )
            XCTFail("Expected injected fixture setup failure.")
        } catch NativeBridgeTestError.injectedSetupFailure {
            // Expected.
        }

        let imapCredential = try await credentials.load(
            CredentialRecordKey(rawValue: "account:account-browser-e2e:imap-password")
        )
        let smtpCredential = try await credentials.load(
            CredentialRecordKey(rawValue: "account:account-browser-e2e:smtp-password")
        )
        XCTAssertNil(imapCredential)
        XCTAssertNil(smtpCredential)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
        let ownedChildren = try FileManager.default.contentsOfDirectory(
            at: coordinationRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("ebe-") }
        XCTAssertTrue(ownedChildren.isEmpty, ownedChildren.map(\.path).joined(separator: "\n"))
    }

    func testNativeBridgeRequestTimesOutAndReapsSilentChildIgnoringSIGTERM() throws {
        let child = try NativeBridgeProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec /usr/bin/tail -f /dev/null"],
            homeURL: FileManager.default.temporaryDirectory,
            requestTimeout: 0.1,
            terminationGrace: 0.1
        )
        let startedAt = Date()
        XCTAssertThrowsError(
            try child.request(
                method: .mailUnreadList,
                parameters: LocalAPIUnreadListParameters(limit: 1)
            ) as LocalAPIUnreadListResult
        ) { error in
            guard case NativeBridgeTestError.processTimeout = error else {
                return XCTFail("Expected process timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertFalse(child.isRunning)
    }

    func testNativeBridgeTruncatedFrameReapsChildIgnoringSIGTERM() throws {
        let child = try NativeBridgeProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec 1>&-; exec /usr/bin/tail -f /dev/null"],
            homeURL: FileManager.default.temporaryDirectory,
            requestTimeout: 1,
            terminationGrace: 0.1
        )
        defer { XCTAssertNoThrow(try child.stop()) }

        XCTAssertThrowsError(
            try child.request(
                method: .mailUnreadList,
                parameters: LocalAPIUnreadListParameters(limit: 1)
            ) as LocalAPIUnreadListResult
        ) { error in
            guard case NativeBridgeTestError.truncatedFrame = error else {
                return XCTFail("Expected truncated frame, got \(error)")
            }
        }
        XCTAssertFalse(child.isRunning)
    }

    func testNativeBridgeStopSurfacesReapFailureAfterReapingChild() throws {
        let child = try NativeBridgeProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec /usr/bin/tail -f /dev/null"],
            homeURL: FileManager.default.temporaryDirectory,
            requestTimeout: 1,
            terminationGrace: 0.1,
            terminateAndReap: { process, input, grace in
                try BoundedProcessLifecycle.terminateAndReap(process, input: input, grace: grace)
                throw NativeBridgeTestError.injectedReapFailure
            }
        )

        XCTAssertThrowsError(try child.stop()) { error in
            guard case NativeBridgeTestError.injectedReapFailure = error else {
                return XCTFail("Expected injected reap failure, got \(error)")
            }
        }
        XCTAssertFalse(child.isRunning)
    }

    func testProcessCleanupAggregatesSIGTERMFailureThenKillsAndReaps() throws {
        var sentSignals: [Int32] = []
        let child = try NativeBridgeProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec /usr/bin/tail -f /dev/null"],
            homeURL: FileManager.default.temporaryDirectory,
            requestTimeout: 1,
            terminationGrace: 0.1,
            terminateAndReap: { process, input, grace in
                try BoundedProcessLifecycle.terminateAndReap(
                    process,
                    input: input,
                    grace: grace,
                    signalSender: { pid, signal in
                        sentSignals.append(signal)
                        if signal == SIGTERM {
                            errno = EPERM
                            return -1
                        }
                        return Darwin.kill(pid, signal)
                    }
                )
            }
        )

        XCTAssertThrowsError(try child.stop()) { error in
            guard let aggregate = error as? ProcessCleanupError else {
                return XCTFail("Expected process cleanup aggregate, got \(error)")
            }
            XCTAssertEqual(aggregate.failures.map(\.step), [.gracefulTerminate])
        }
        XCTAssertEqual(sentSignals, [SIGTERM, SIGKILL])
        XCTAssertFalse(child.isRunning)
    }

    func testProcessCleanupTreatsAlreadyExitedESRCHAsBenign() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec /usr/bin/tail -f /dev/null"]
        try process.run()
        var sentSignals: [Int32] = []

        XCTAssertNoThrow(
            try BoundedProcessLifecycle.terminateAndReap(
                process,
                input: nil,
                grace: 0.2,
                signalSender: { pid, signal in
                    sentSignals.append(signal)
                    if signal == SIGTERM {
                        _ = Darwin.kill(pid, SIGKILL)
                        errno = ESRCH
                        return -1
                    }
                    return Darwin.kill(pid, signal)
                }
            )
        )
        XCTAssertEqual(sentSignals.first, SIGTERM)
        XCTAssertFalse(process.isRunning)
    }

    func testMCPTimeoutKillsAndReapsChildIgnoringSIGTERM() throws {
        var childPID: Int32?
        let startedAt = Date()
        XCTAssertThrowsError(
            try MCPEmailReadProcess.invokeTwice(
                messageID: MessageID("msg_alice_1"),
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; exec /usr/bin/tail -f /dev/null"],
                timeout: 0.1,
                terminationGrace: 0.1,
                onLaunch: { childPID = $0 }
            )
        ) { error in
            guard case NativeBridgeTestError.processTimeout = error else {
                return XCTFail("Expected process timeout, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        let pid = try XCTUnwrap(childPID)
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testMCPWriteFailureKillsAndReapsChildIgnoringSIGTERM() throws {
        var childPID: Int32?
        defer {
            if let childPID, Darwin.kill(childPID, 0) == 0 {
                Darwin.kill(childPID, SIGKILL)
            }
        }

        XCTAssertThrowsError(
            try MCPEmailReadProcess.invokeTwice(
                messageID: MessageID("msg_alice_1"),
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; exec /usr/bin/tail -f /dev/null"],
                timeout: 1,
                terminationGrace: 0.1,
                onLaunch: { childPID = $0 },
                writeRequests: { _, _ in throw NativeBridgeTestError.injectedWriteFailure }
            )
        ) { error in
            guard case NativeBridgeTestError.injectedWriteFailure = error else {
                return XCTFail("Expected injected write failure, got \(error)")
            }
        }
        let pid = try XCTUnwrap(childPID)
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testFixtureStopReportsOwnedDirectoryReplacement() async throws {
        let coordinationRoot = try makeTemporaryDirectory(prefix: "plainpost-browser-replaced")
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let fixture = try await BrowserExtensionLocalAPIFixture.make(rootURL: coordinationRoot)
        let ownedRoot = fixture.rootURL
        try FileManager.default.removeItem(at: ownedRoot)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: false)

        XCTAssertThrowsError(try fixture.stop()) { error in
            guard let aggregate = error as? FixtureCleanupError else {
                return XCTFail("Expected aggregate cleanup error, got \(error)")
            }
            XCTAssertEqual(aggregate.failures.map(\.step), [.ownedDirectory])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedRoot.path))
    }

    func testFixtureStopAggregatesFailuresAndContinuesAllCleanup() async throws {
        let coordinationRoot = try makeTemporaryDirectory(prefix: "plainpost-browser-cleanup")
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let sentinel = coordinationRoot.appendingPathComponent("caller-sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)
        let fixture = try await BrowserExtensionLocalAPIFixture.make(
            rootURL: coordinationRoot,
            credentialDelete: { record in
                if record.rawValue.hasSuffix(":imap-password") {
                    throw NativeBridgeTestError.injectedCredentialDeleteFailure
                }
            },
            bridgeTerminator: { process, input, grace in
                try BoundedProcessLifecycle.terminateAndReap(process, input: input, grace: grace)
                throw NativeBridgeTestError.injectedReapFailure
            }
        )
        let ownedRoot = fixture.rootURL
        let readyURL = coordinationRoot.appendingPathComponent("ready")
        let readyMarker = try OwnedCoordinationMarker.create(
            at: readyURL,
            contents: Data(ownedRoot.path.utf8)
        )
        fixture.registerOwnedMarker(readyMarker, step: .readyMarker)
        try FileManager.default.removeItem(at: readyURL)
        try FileManager.default.createDirectory(at: readyURL, withIntermediateDirectories: false)
        let replacementSentinel = readyURL.appendingPathComponent("caller-sentinel")
        try Data("preserve-me-too".utf8).write(to: replacementSentinel)

        XCTAssertThrowsError(try fixture.stop()) { error in
            guard let aggregate = error as? FixtureCleanupError else {
                return XCTFail("Expected aggregate cleanup error, got \(error)")
            }
            XCTAssertEqual(
                aggregate.failures.map(\.step),
                [.bridgeProcess, .imapCredential, .readyMarker]
            )
        }
        XCTAssertFalse(fixture.bridge.isRunning)
        let imapCredential = try await fixture.credentials.load(
            CredentialRecordKey(rawValue: "account:account-browser-e2e:imap-password")
        )
        let smtpCredential = try await fixture.credentials.load(
            CredentialRecordKey(rawValue: "account:account-browser-e2e:smtp-password")
        )
        XCTAssertNil(imapCredential)
        XCTAssertNil(smtpCredential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
        XCTAssertEqual(try Data(contentsOf: replacementSentinel), Data("preserve-me-too".utf8))
    }

    func testSetupFailurePreservesPrimaryAndAggregatesCleanupFailures() async throws {
        let coordinationRoot = try makeTemporaryDirectory(prefix: "plainpost-browser-setup-cleanup")
        defer { try? FileManager.default.removeItem(at: coordinationRoot) }
        let sentinel = coordinationRoot.appendingPathComponent("caller-sentinel")
        try Data("preserve-me".utf8).write(to: sentinel)
        let credentials = InMemoryCredentialVault()
        do {
            _ = try await BrowserExtensionLocalAPIFixture.make(
                rootURL: coordinationRoot,
                credentials: credentials,
                failAt: .afterCredentialsSaved,
                credentialDelete: { record in
                    if record.rawValue.hasSuffix(":imap-password") {
                        throw NativeBridgeTestError.injectedCredentialDeleteFailure
                    }
                }
            )
            XCTFail("Expected setup and cleanup failure.")
        } catch let error as FixtureSetupAndCleanupError {
            guard case NativeBridgeTestError.injectedSetupFailure = error.primary else {
                return XCTFail("Expected preserved primary setup failure, got \(error)")
            }
            XCTAssertEqual(error.cleanup.failures.map(\.step), [.imapCredential])
        }

        let imapCredential = try await credentials.load(
            CredentialRecordKey(rawValue: "account:account-browser-e2e:imap-password")
        )
        let smtpCredential = try await credentials.load(
            CredentialRecordKey(rawValue: "account:account-browser-e2e:smtp-password")
        )
        XCTAssertNil(imapCredential)
        XCTAssertNil(smtpCredential)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve-me".utf8))
        let ownedChildren = try FileManager.default.contentsOfDirectory(
            at: coordinationRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("ebe-") }
        XCTAssertTrue(ownedChildren.isEmpty, ownedChildren.map(\.lastPathComponent).joined(separator: ","))
    }

    func testInteractiveBrowserSmokeFixture() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["PLAINPOST_BROWSER_SMOKE_ROOT"] else {
            throw XCTSkip("Opt-in fixture for isolated interactive browser smoke.")
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let fixture = try await BrowserExtensionLocalAPIFixture.make(rootURL: rootURL)
        defer { XCTAssertNoThrow(try fixture.stop()) }
        let readyURL = rootURL.appendingPathComponent("ready")
        let doneURL = rootURL.appendingPathComponent("done")
        guard !pathExistsIncludingSymbolicLink(doneURL) else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(rootURL.path)
        }
        let readyMarker = try OwnedCoordinationMarker.create(
            at: readyURL,
            contents: Data(fixture.rootURL.path.utf8)
        )
        fixture.registerOwnedMarker(readyMarker, step: .readyMarker)

        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: doneURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: doneURL.path),
            "Interactive browser smoke did not signal completion."
        )

        while try await fixture.runtime.processNextJob() != nil {}
        XCTAssertTrue(try XCTUnwrap(fixture.store.messageSummary(id: fixture.messageID)).isSeen)
        let acceptedMessages = await fixture.smtp.acceptedMessages()
        XCTAssertEqual(acceptedMessages.count, 1)
        XCTAssertTrue(try XCTUnwrap(acceptedMessages.first).data.contains("Friday"))
        let summaryRequest = try await fixture.ollama.request(at: 0)
        let draftRequest = try await fixture.ollama.request(at: 1)
        XCTAssertEqual(summaryRequest.path, "/api/generate")
        XCTAssertEqual(draftRequest.path, "/api/generate")
    }
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
    let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("t-\(prefix.prefix(4))-\(token)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url.resolvingSymlinksInPath()
}

private final class OwnedFixtureDirectory: @unchecked Sendable {
    let coordinationRootURL: URL
    let rootURL: URL

    private let identity: FileIdentity
    private let lock = NSLock()
    private var removed = false

    private init(coordinationRootURL: URL, rootURL: URL, identity: FileIdentity) {
        self.coordinationRootURL = coordinationRootURL
        self.rootURL = rootURL
        self.identity = identity
    }

    static func create(
        coordinationRootURL requestedRootURL: URL,
        childName: String = "ebe-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    ) throws -> OwnedFixtureDirectory {
        let fileManager = FileManager.default
        guard requestedRootURL.isFileURL, requestedRootURL.path.hasPrefix("/") else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(requestedRootURL.path)
        }
        let standardizedRoot = requestedRootURL.standardizedFileURL
        let canonicalRoot = standardizedRoot.resolvingSymlinksInPath()
        guard standardizedRoot.path == canonicalRoot.path else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(requestedRootURL.path)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(canonicalRoot.path)
        }

        let unsafeRoots = [
            URL(fileURLWithPath: "/", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.resolvingSymlinksInPath(),
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                .resolvingSymlinksInPath(),
        ]
        guard !unsafeRoots.contains(where: { $0.standardizedFileURL.path == canonicalRoot.path }) else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(canonicalRoot.path)
        }
        guard childName.hasPrefix("ebe-"),
              !childName.contains("/"),
              childName != ".",
              childName != ".."
        else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(childName)
        }

        let childURL = canonicalRoot.appendingPathComponent(childName, isDirectory: true)
            .standardizedFileURL
        guard childURL.deletingLastPathComponent().path == canonicalRoot.path,
              !unsafeRoots.contains(where: { $0.standardizedFileURL.path == childURL.path })
        else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(childURL.path)
        }
        guard !pathExistsIncludingSymbolicLink(childURL) else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(childURL.path)
        }

        try fileManager.createDirectory(at: childURL, withIntermediateDirectories: false)
        do {
            let identity = try FileIdentity.directory(at: childURL)
            guard childURL.resolvingSymlinksInPath().path == childURL.path else {
                throw NativeBridgeTestError.unsafeFixtureDirectory(childURL.path)
            }
            return OwnedFixtureDirectory(
                coordinationRootURL: canonicalRoot,
                rootURL: childURL,
                identity: identity
            )
        } catch {
            try? fileManager.removeItem(at: childURL)
            throw error
        }
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        guard pathExistsIncludingSymbolicLink(rootURL) else {
            throw NativeBridgeTestError.fixtureDirectoryChanged(rootURL.path)
        }
        guard rootURL.deletingLastPathComponent().standardizedFileURL.path == coordinationRootURL.path,
              rootURL.resolvingSymlinksInPath().path == rootURL.path,
              try FileIdentity.directory(at: rootURL) == identity
        else {
            throw NativeBridgeTestError.fixtureDirectoryChanged(rootURL.path)
        }
        try FileManager.default.removeItem(at: rootURL)
        removed = true
    }
}

private final class OwnedCoordinationMarker: @unchecked Sendable {
    private let url: URL
    private let identity: FileIdentity
    private let lock = NSLock()
    private var removed = false

    private init(url: URL, identity: FileIdentity) {
        self.url = url
        self.identity = identity
    }

    static func create(at url: URL, contents: Data) throws -> OwnedCoordinationMarker {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(url.path)
        }
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NativeBridgeTestError.markerFailure("open failed with errno \(errno): \(url.path)")
        }
        var identity: FileIdentity?
        var descriptorIsOpen = true
        do {
            let createdIdentity = try FileIdentity.regularFile(descriptor: descriptor, path: url.path)
            identity = createdIdentity
            var offset = 0
            try contents.withUnsafeBytes { bytes in
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        bytes.baseAddress?.advanced(by: offset),
                        bytes.count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw NativeBridgeTestError.markerFailure(
                            "write failed with errno \(errno): \(url.path)"
                        )
                    }
                    offset += written
                }
            }
            let closeResult = Darwin.close(descriptor)
            descriptorIsOpen = false
            guard closeResult == 0 else {
                throw NativeBridgeTestError.markerFailure("close failed with errno \(errno): \(url.path)")
            }
            return OwnedCoordinationMarker(url: url, identity: createdIdentity)
        } catch {
            if descriptorIsOpen {
                Darwin.close(descriptor)
            }
            if let identity,
               (try? FileIdentity.regularFile(at: url)) == identity
            {
                Darwin.unlink(url.path)
            }
            throw error
        }
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        guard pathExistsIncludingSymbolicLink(url),
              try FileIdentity.regularFile(at: url) == identity
        else {
            throw NativeBridgeTestError.fixtureDirectoryChanged(url.path)
        }
        guard Darwin.unlink(url.path) == 0 else {
            throw NativeBridgeTestError.markerFailure("unlink failed with errno \(errno): \(url.path)")
        }
        removed = true
    }
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    static func directory(at url: URL) throws -> FileIdentity {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR
        else {
            throw NativeBridgeTestError.unsafeFixtureDirectory(url.path)
        }
        return FileIdentity(device: information.st_dev, inode: information.st_ino)
    }

    static func regularFile(at url: URL) throws -> FileIdentity {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG
        else {
            throw NativeBridgeTestError.fixtureDirectoryChanged(url.path)
        }
        return FileIdentity(device: information.st_dev, inode: information.st_ino)
    }

    static func regularFile(descriptor: Int32, path: String) throws -> FileIdentity {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG
        else {
            throw NativeBridgeTestError.markerFailure("fstat failed with errno \(errno): \(path)")
        }
        return FileIdentity(device: information.st_dev, inode: information.st_ino)
    }
}

private func pathExistsIncludingSymbolicLink(_ url: URL) -> Bool {
    var information = stat()
    if Darwin.lstat(url.path, &information) == 0 {
        return true
    }
    return errno != ENOENT
}

private enum BrowserExtensionFixtureFailurePoint {
    case afterCredentialsSaved
}

private enum FixtureCleanupStep: String, Equatable, Sendable {
    case bridgeProcess
    case localAPIServer
    case imapServer
    case smtpServer
    case ollamaServer
    case imapCredential
    case smtpCredential
    case readyMarker
    case ownedDirectory
}

private struct FixtureCleanupFailure: Equatable, Sendable {
    let step: FixtureCleanupStep
    let category: String
}

private struct FixtureCleanupError: Error, Equatable, CustomStringConvertible, Sendable {
    let failures: [FixtureCleanupFailure]

    var description: String {
        let steps = failures.map { "\($0.step.rawValue)[\($0.category)]" }.joined(separator: ",")
        return "Fixture cleanup failed: \(steps)"
    }
}

private struct FixtureSetupAndCleanupError: Error, CustomStringConvertible {
    let primary: Error
    let cleanup: FixtureCleanupError

    var description: String {
        "Fixture setup and cleanup failed: primary=\(safeErrorCategory(primary)); cleanup=\(cleanup)"
    }
}

private struct FixtureCleanupCollector {
    private(set) var failures: [FixtureCleanupFailure] = []

    mutating func attempt(_ step: FixtureCleanupStep, _ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            failures.append(FixtureCleanupFailure(step: step, category: safeErrorCategory(error)))
        }
    }

    func error() -> FixtureCleanupError? {
        failures.isEmpty ? nil : FixtureCleanupError(failures: failures)
    }
}

private func safeErrorCategory(_ error: Error) -> String {
    if let processCleanup = error as? ProcessCleanupError {
        return processCleanup.failures
            .map { "\($0.step.rawValue)-\($0.category)" }
            .joined(separator: "+")
    }
    guard let nativeError = error as? NativeBridgeTestError else {
        return String(describing: type(of: error))
    }
    return switch nativeError {
    case .apiFailure: "apiFailure"
    case .correlationMismatch: "correlationMismatch"
    case .fixtureDirectoryChanged: "fixtureDirectoryChanged"
    case .injectedCredentialDeleteFailure: "injectedCredentialDeleteFailure"
    case .injectedReapFailure: "injectedReapFailure"
    case .injectedSetupFailure: "injectedSetupFailure"
    case .injectedWriteFailure: "injectedWriteFailure"
    case .markerFailure: "markerFailure"
    case .mcpFailure: "mcpFailure"
    case .missingExecutable: "missingExecutable"
    case .processDidNotExit: "processDidNotExit"
    case .processTimeout: "processTimeout"
    case .truncatedFrame: "truncatedFrame"
    case .unsafeFixtureDirectory: "unsafeFixtureDirectory"
    }
}

private typealias CredentialDelete = (CredentialRecordKey) throws -> Void
private typealias NativeBridgeTerminator = (Process, FileHandle?, TimeInterval) throws -> Void
private typealias ProcessSignalSender = (pid_t, Int32) -> Int32

private func cleanupStep(for record: CredentialRecordKey) -> FixtureCleanupStep {
    record.rawValue.hasSuffix(":imap-password") ? .imapCredential : .smtpCredential
}

private final class BrowserExtensionLocalAPIFixture: @unchecked Sendable {
    private let ownedDirectory: OwnedFixtureDirectory
    private let credentialDelete: CredentialDelete
    private let markerLock = NSLock()
    private var ownedMarkers: [(FixtureCleanupStep, OwnedCoordinationMarker)] = []
    let rootURL: URL
    let databaseURL: URL
    let store: SQLiteMailStore
    let imap: LocalIMAPServer
    let smtp: LocalSMTPServer
    let ollama: LocalOllamaServer
    let runtime: LocalOperationRuntime
    let server: LocalAPIUnixServer
    let bridge: NativeBridgeProcess
    let credentials: InMemoryCredentialVault
    private let credentialKeys: [CredentialRecordKey]
    let accountID = AccountID("account-browser-e2e")
    let messageID = MessageID("message-browser-e2e")
    let username = "me@example.com"
    let password = "local-browser-e2e-secret"
    var localAPISocketURL: URL {
        rootURL.appendingPathComponent(
            "home/Library/Application Support/Plainpost/LocalAPI-v1.sock"
        )
    }

    private init(
        ownedDirectory: OwnedFixtureDirectory,
        databaseURL: URL,
        store: SQLiteMailStore,
        imap: LocalIMAPServer,
        smtp: LocalSMTPServer,
        ollama: LocalOllamaServer,
        runtime: LocalOperationRuntime,
        server: LocalAPIUnixServer,
        bridge: NativeBridgeProcess,
        credentials: InMemoryCredentialVault,
        credentialKeys: [CredentialRecordKey],
        credentialDelete: @escaping CredentialDelete
    ) {
        self.ownedDirectory = ownedDirectory
        self.rootURL = ownedDirectory.rootURL
        self.databaseURL = databaseURL
        self.store = store
        self.imap = imap
        self.smtp = smtp
        self.ollama = ollama
        self.runtime = runtime
        self.server = server
        self.bridge = bridge
        self.credentials = credentials
        self.credentialKeys = credentialKeys
        self.credentialDelete = credentialDelete
    }

    static func make(
        rootURL requestedCoordinationRootURL: URL? = nil,
        credentials suppliedCredentials: InMemoryCredentialVault? = nil,
        failAt failurePoint: BrowserExtensionFixtureFailurePoint? = nil,
        credentialDelete: @escaping CredentialDelete = { _ in },
        bridgeTerminator: @escaping NativeBridgeTerminator = { process, input, grace in
            try BoundedProcessLifecycle.terminateAndReap(process, input: input, grace: grace)
        }
    ) async throws -> BrowserExtensionLocalAPIFixture {
        let coordinationRootURL =
            requestedCoordinationRootURL
            ?? URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let ownedDirectory = try OwnedFixtureDirectory.create(
            coordinationRootURL: coordinationRootURL
        )
        let rootURL = ownedDirectory.rootURL
        let homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        let socketURL = homeURL.appendingPathComponent(
            "Library/Application Support/Plainpost/LocalAPI-v1.sock"
        )
        var cleanupIMAP: LocalIMAPServer?
        var cleanupSMTP: LocalSMTPServer?
        var cleanupOllama: LocalOllamaServer?
        let credentials = suppliedCredentials ?? InMemoryCredentialVault()
        let credentialKeys = [
            CredentialRecordKey(rawValue: "account:account-browser-e2e:imap-password"),
            CredentialRecordKey(rawValue: "account:account-browser-e2e:smtp-password"),
        ]
        var imapStarted = false
        var smtpStarted = false
        var ollamaStarted = false
        var server: LocalAPIUnixServer?
        var bridge: NativeBridgeProcess?
        do {
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: false)

            let message = MessageSummary(
                id: MessageID("message-browser-e2e"),
                threadID: ThreadID("thread-browser-e2e"),
                from: EmailAddress("maya@example.com"),
                fromDisplayName: "Maya",
                subject: "Friday plans",
                preview: "Can you confirm Friday?",
                smartCategory: .personal,
                labels: [],
                isSeen: false,
                mailboxPath: "INBOX",
                isDeleted: false,
                body: "Can you confirm Friday?",
                rfcMessageID: "<browser-e2e@example.com>",
                replyTo: EmailAddress("maya@example.com"),
                to: [EmailAddress("me@example.com")]
            )
            let imap = LocalIMAPServer(
                username: "me@example.com",
                password: "local-browser-e2e-secret",
                message: message
            )
            cleanupIMAP = imap
            let smtp = LocalSMTPServer(
                username: "me@example.com",
                password: "local-browser-e2e-secret"
            )
            cleanupSMTP = smtp
            let ollama = LocalOllamaServer()
            ollama.generateResponseText = "Friday works for me. Thank you, Maya."
            cleanupOllama = ollama
            try await imap.start()
            imapStarted = true
            try await smtp.start()
            smtpStarted = true
            try await ollama.start()
            ollamaStarted = true

            let seedIMAP = PlaintextIMAPClient(host: "127.0.0.1", port: imap.port)
            do {
                try await seedIMAP.login(
                    username: "me@example.com",
                    password: "local-browser-e2e-secret"
                )
                _ = try await seedIMAP.selectMailbox("INBOX")
                try await seedIMAP.markUnread(uid: 1)
            } catch {
                await seedIMAP.disconnect()
                throw error
            }
            await seedIMAP.disconnect()

            let databaseURL = rootURL.appendingPathComponent("Plainpost.sqlite")
            let store = try SQLiteMailStore(path: databaseURL.path)
            try store.migrate()
            let account = Account(
                id: AccountID("account-browser-e2e"),
                displayName: "Me",
                email: EmailAddress("me@example.com"),
                imapHost: "127.0.0.1",
                imapPort: imap.port,
                smtpHost: "127.0.0.1",
                smtpPort: smtp.port
            )
            try store.cacheAccounts([account])
            try store.cacheThreads([
                MailThread(
                    id: ThreadID("thread-browser-e2e"),
                    accountID: account.id,
                    subjectNormalized: "Friday plans",
                    participantEmails: [account.email, EmailAddress("maya@example.com")]
                )
            ])
            try store.cacheMessageReliably(message)
            try store.recordCachedUID(
                accountID: account.id,
                mailboxPath: "INBOX",
                uidValidity: 1,
                uid: 1,
                messageID: message.id
            )

            let imapCredentialKey = credentialKeys[0]
            try await credentials.store(
                Data("local-browser-e2e-secret".utf8),
                for: imapCredentialKey
            )
            let smtpCredentialKey = credentialKeys[1]
            try await credentials.store(
                Data("local-browser-e2e-secret".utf8),
                for: smtpCredentialKey
            )
            if failurePoint == .afterCredentialsSaved {
                throw NativeBridgeTestError.injectedSetupFailure
            }
            let runtime = LocalOperationRuntime(
                store: store,
                credentials: credentials,
                environment: [
                    "PLAINPOST_OLLAMA_URL": "http://127.0.0.1:\(ollama.port)",
                    "PLAINPOST_OLLAMA_CHAT_MODEL": "qwen3:8b",
                    "PLAINPOST_OLLAMA_EMBEDDING_MODEL": "mxbai-embed-large",
                ],
                allowedJobKinds: [.inboxSync, .mailboxFlag, .aiOperation, .approvedDelivery]
            )
            let operationClient = LocalOperationClient(runtime: runtime)
            let createdServer = try PlainpostLocalServerFactory.make(
                socketURL: socketURL,
                store: store,
                lastSync: { Date(timeIntervalSince1970: 1_752_422_400) },
                messageOpening: MessageOpeningService(
                    store: store,
                    scheduler: DurableMailboxFlagScheduler(store: store)
                ),
                inboxSyncer: operationClient,
                aiClient: operationClient,
                selectedProviderID: { "ollama" },
                deliveryService: BrowserReplyDeliveryService(store: store, runtime: runtime)
            )
            server = createdServer
            try createdServer.start()
            let createdBridge = try NativeBridgeProcess(
                homeURL: homeURL,
                terminateAndReap: bridgeTerminator
            )
            bridge = createdBridge

            let fixture = BrowserExtensionLocalAPIFixture(
                ownedDirectory: ownedDirectory,
                databaseURL: databaseURL,
                store: store,
                imap: imap,
                smtp: smtp,
                ollama: ollama,
                runtime: runtime,
                server: createdServer,
                bridge: createdBridge,
                credentials: credentials,
                credentialKeys: credentialKeys,
                credentialDelete: credentialDelete
            )
            return fixture
        } catch {
            let primaryError = error
            var cleanup = FixtureCleanupCollector()
            if let bridge {
                cleanup.attempt(.bridgeProcess) { try bridge.stop() }
            }
            if let server {
                cleanup.attempt(.localAPIServer) { server.stop() }
            }
            if imapStarted, let cleanupIMAP {
                cleanup.attempt(.imapServer) { cleanupIMAP.stop() }
            }
            if smtpStarted, let cleanupSMTP {
                cleanup.attempt(.smtpServer) { cleanupSMTP.stop() }
            }
            if ollamaStarted, let cleanupOllama {
                cleanup.attempt(.ollamaServer) { cleanupOllama.stop() }
            }
            for record in credentialKeys {
                cleanup.attempt(cleanupStep(for: record)) {
                    try Self.removeCredential(
                        record,
                        from: credentials,
                        postDelete: credentialDelete
                    )
                }
            }
            cleanup.attempt(.ownedDirectory) { try ownedDirectory.remove() }
            if let cleanupError = cleanup.error() {
                throw FixtureSetupAndCleanupError(
                    primary: primaryError,
                    cleanup: cleanupError
                )
            }
            throw primaryError
        }
    }

    func stop() throws {
        var cleanup = FixtureCleanupCollector()
        cleanup.attempt(.bridgeProcess) { try bridge.stop() }
        cleanup.attempt(.localAPIServer) { server.stop() }
        cleanup.attempt(.imapServer) { imap.stop() }
        cleanup.attempt(.smtpServer) { smtp.stop() }
        cleanup.attempt(.ollamaServer) { ollama.stop() }
        for record in credentialKeys {
                cleanup.attempt(cleanupStep(for: record)) {
                try Self.removeCredential(
                    record,
                    from: credentials,
                    postDelete: credentialDelete
                )
            }
        }
        markerLock.lock()
        let markers = ownedMarkers
        markerLock.unlock()
        for (step, marker) in markers {
            cleanup.attempt(step) { try marker.remove() }
        }
        cleanup.attempt(.ownedDirectory) { try ownedDirectory.remove() }
        if let cleanupError = cleanup.error() {
            throw cleanupError
        }
    }

    func registerOwnedMarker(
        _ marker: OwnedCoordinationMarker,
        step: FixtureCleanupStep
    ) {
        markerLock.lock()
        ownedMarkers.append((step, marker))
        markerLock.unlock()
    }

    private static func removeCredential(
        _ record: CredentialRecordKey,
        from credentials: InMemoryCredentialVault,
        postDelete: @escaping CredentialDelete
    ) throws {
        let deletion = FixtureCredentialDeletion()
        Task {
            do {
                try await credentials.remove(record)
                deletion.finish()
            } catch {
                deletion.finish(error: error)
            }
        }
        try deletion.wait()
        try postDelete(record)
    }
}

private final class FixtureCredentialDeletion: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var error: Error?

    func finish(error: Error? = nil) {
        lock.withLock { self.error = error }
        completion.signal()
    }

    func wait() throws {
        completion.wait()
        if let error = lock.withLock({ error }) {
            throw error
        }
    }
}

private enum ProcessCleanupStep: String, Equatable, Sendable {
    case inputClose
    case gracefulTerminate
    case forceKill
    case reap
}

private struct ProcessCleanupFailure: Equatable, Sendable {
    let step: ProcessCleanupStep
    let category: String
}

private struct ProcessCleanupError: Error, Equatable, CustomStringConvertible, Sendable {
    let failures: [ProcessCleanupFailure]

    var description: String {
        let steps = failures.map { "\($0.step.rawValue)[\($0.category)]" }.joined(separator: ",")
        return "Process cleanup failed: \(steps)"
    }
}

private enum BoundedProcessLifecycle {
    static func terminateAndReap(
        _ process: Process,
        input: FileHandle?,
        grace: TimeInterval,
        signalSender: ProcessSignalSender = { pid, signal in
            Darwin.kill(pid, signal)
        }
    ) throws {
        var failures: [ProcessCleanupFailure] = []
        if let input {
            do {
                try input.close()
            } catch {
                failures.append(ProcessCleanupFailure(
                    step: .inputClose,
                    category: String(describing: type(of: error))
                ))
            }
        }
        if process.isRunning {
            errno = 0
            let terminateResult = signalSender(process.processIdentifier, SIGTERM)
            let terminateErrno = errno
            if terminateResult != 0, terminateErrno != ESRCH {
                failures.append(ProcessCleanupFailure(
                    step: .gracefulTerminate,
                    category: "errno-\(terminateErrno)"
                ))
            }
            if !waitForExit(process, timeout: grace) {
                errno = 0
                let killResult = signalSender(process.processIdentifier, SIGKILL)
                let killErrno = errno
                if killResult != 0, killErrno != ESRCH {
                    failures.append(ProcessCleanupFailure(
                        step: .forceKill,
                        category: "errno-\(killErrno)"
                    ))
                }
                if !waitForExit(process, timeout: grace) {
                    failures.append(ProcessCleanupFailure(
                        step: .reap,
                        category: "deadlineExceeded"
                    ))
                }
            }
        }
        if !process.isRunning {
            process.waitUntilExit()
        }
        if !failures.isEmpty {
            throw ProcessCleanupError(failures: failures)
        }
    }

    static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return !process.isRunning
    }
}

private final class TestUnlockedNativeBridge {
    private let client: LocalAPIUnixClient
    private var requestNumber = 0

    init(socketURL: URL) {
        client = LocalAPIUnixClient(socketURL: socketURL)
    }

    func request<Parameters, Result>(
        method: LocalAPIMethod,
        parameters: Parameters
    ) throws -> Result
    where Parameters: Codable & Sendable, Result: Codable & Sendable {
        requestNumber += 1
        let requestID = "browser-e2e-\(requestNumber)"
        let request = LocalAPIRequest(
            requestID: requestID,
            method: method,
            parameters: parameters
        )
        let requestPayload = try LocalAPIJSON.makeEncoder().encode(request)
        let framedRequest = try NativeMessagingFrameCodec.encode(requestPayload)
        let forwardedRequest = try decodeSingleFrame(framedRequest)
        guard BrowserBridgeResponse.isRequestAllowedForForwarding(
            forwardedRequest
        ) else {
            throw NativeBridgeTestError.apiFailure(
                .invalidRequest,
                "The request is invalid."
            )
        }

        let responsePayload = try client.request(forwardedRequest)
        let framedResponse = try NativeMessagingFrameCodec.encode(responsePayload)
        let response = try decodeSingleFrame(framedResponse)
        if let failure = try? JSONDecoder().decode(
            LocalAPIFailure.self,
            from: response
        ), !failure.ok {
            throw NativeBridgeTestError.apiFailure(
                failure.error.code,
                failure.error.message
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            LocalAPISuccess<Result>.self,
            from: response
        )
        guard decoded.requestID == requestID else {
            throw NativeBridgeTestError.correlationMismatch
        }
        return decoded.result
    }

    private func decodeSingleFrame(_ frame: Data) throws -> Data {
        var offset = 0
        let payload = try NativeMessagingFrameCodec.readFrame { count in
            guard offset < frame.count else { return Data() }
            let end = min(offset + count, frame.count)
            defer { offset = end }
            return frame.subdata(in: offset ..< end)
        }
        guard let payload, offset == frame.count else {
            throw NativeBridgeTestError.truncatedFrame(
                "test native bridge frame was incomplete"
            )
        }
        return payload
    }
}

private final class NativeBridgeProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let requestTimeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let terminateAndReap: NativeBridgeTerminator
    private var requestNumber = 0

    var isRunning: Bool { process.isRunning }

    convenience init(
        homeURL: URL,
        terminateAndReap: @escaping NativeBridgeTerminator = { process, input, grace in
            try BoundedProcessLifecycle.terminateAndReap(process, input: input, grace: grace)
        }
    ) throws {
        try self.init(
            executableURL: Self.productURL(named: "PlainpostBrowserBridge"),
            arguments: [BrowserCallerValidator.chromiumOrigin],
            homeURL: homeURL,
            terminateAndReap: terminateAndReap
        )
    }

    init(
        executableURL: URL,
        arguments: [String],
        homeURL: URL,
        requestTimeout: TimeInterval = 5,
        terminationGrace: TimeInterval = 0.25,
        terminateAndReap: @escaping NativeBridgeTerminator = { process, input, grace in
            try BoundedProcessLifecycle.terminateAndReap(process, input: input, grace: grace)
        }
    ) throws {
        self.requestTimeout = requestTimeout
        self.terminationGrace = terminationGrace
        self.terminateAndReap = terminateAndReap
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": homeURL.path,
        ]) { _, new in new }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
    }

    func request<Parameters, Result>(
        method: LocalAPIMethod,
        parameters: Parameters
    ) throws -> Result
    where Parameters: Codable & Sendable, Result: Codable & Sendable {
        requestNumber += 1
        let requestID = "browser-e2e-\(requestNumber)"
        let request = LocalAPIRequest(
            requestID: requestID,
            method: method,
            parameters: parameters
        )
        let payload = try LocalAPIJSON.makeEncoder().encode(request)
        let response: Data
        do {
            try stdin.fileHandleForWriting.write(contentsOf: NativeMessagingFrameCodec.encode(payload))
            let deadline = Date().addingTimeInterval(requestTimeout)
            let header = try readExactly(NativeMessagingFrameCodec.headerSize, deadline: deadline)
            let length = try NativeMessagingFrameCodec.decodeLength(header)
            response = try readExactly(length, deadline: deadline)
        } catch {
            let transportError = error
            try terminateAndReap(
                process,
                stdin.fileHandleForWriting,
                terminationGrace
            )
            if case NativeBridgeTestError.processTimeout = transportError {
                let diagnostics = String(
                    decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
                throw NativeBridgeTestError.processTimeout(diagnostics)
            }
            throw transportError
        }
        if let failure = try? JSONDecoder().decode(LocalAPIFailure.self, from: response), !failure.ok {
            throw NativeBridgeTestError.apiFailure(failure.error.code, failure.error.message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            LocalAPISuccess<Result>.self,
            from: response
        )
        guard decoded.requestID == requestID else {
            throw NativeBridgeTestError.correlationMismatch
        }
        return decoded.result
    }

    func stop() throws {
        try terminateAndReap(
            process,
            stdin.fileHandleForWriting,
            terminationGrace
        )
    }

    private func readExactly(_ count: Int, deadline: Date) throws -> Data {
        var data = Data()
        while data.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw NativeBridgeTestError.processTimeout("")
            }
            var descriptor = pollfd(
                fd: stdout.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let milliseconds = Int32(min(
                Double(Int32.max),
                max(1, ceil(remaining * 1_000))
            ))
            let pollResult = Darwin.poll(&descriptor, 1, milliseconds)
            if pollResult == 0 {
                throw NativeBridgeTestError.processTimeout("")
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw NativeBridgeTestError.truncatedFrame("poll failed with errno \(errno)")
            }
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    stdout.fileHandleForReading.fileDescriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if bytesRead < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw NativeBridgeTestError.truncatedFrame("read failed with errno \(errno)")
            }
            guard bytesRead > 0 else {
                throw NativeBridgeTestError.truncatedFrame("native bridge closed stdout")
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return data
    }

    fileprivate static func productURL(named name: String) throws -> URL {
        let candidate = Bundle(for: BrowserExtensionLocalAPITests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw NativeBridgeTestError.missingExecutable(candidate.path)
        }
        return candidate
    }
}

private enum MCPEmailReadProcess {
    static func invokeTwice(
        messageID: MessageID,
        executableURL requestedExecutableURL: URL? = nil,
        arguments requestedArguments: [String]? = nil,
        timeout: TimeInterval = 10,
        terminationGrace: TimeInterval = 0.25,
        onLaunch: (Int32) -> Void = { _ in },
        writeRequests: (FileHandle, Data) throws -> Void = { handle, data in
            try handle.write(contentsOf: data)
        }
    ) throws -> [String] {
        let process = Process()
        process.executableURL = try requestedExecutableURL
            ?? NativeBridgeProcess.productURL(named: "plainpost")
        process.arguments = requestedArguments ?? ["mcp", "serve"]
        let stdin = Pipe()
        let output = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = output
        try process.run()
        onLaunch(process.processIdentifier)
        let requests = (1 ... 2).map { requestID in
            #"{"jsonrpc":"2.0","id":\#(requestID),"method":"tools/call","params":{"name":"email.read","arguments":{"message_id":"\#(messageID.rawValue)","include":"body"}}}"#
        }
        do {
            try writeRequests(
                stdin.fileHandleForWriting,
                Data((requests.joined(separator: "\n") + "\n").utf8)
            )
            try stdin.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !process.isRunning else {
                throw NativeBridgeTestError.processTimeout("")
            }
            try BoundedProcessLifecycle.terminateAndReap(
                process,
                input: stdin.fileHandleForWriting,
                grace: terminationGrace
            )
            let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw NativeBridgeTestError.mcpFailure(value)
            }
            return value.split(separator: "\n").map(String.init)
        } catch {
            let invocationError = error
            try BoundedProcessLifecycle.terminateAndReap(
                process,
                input: stdin.fileHandleForWriting,
                grace: terminationGrace
            )
            if case NativeBridgeTestError.processTimeout = invocationError {
                let diagnostics = String(
                    decoding: output.fileHandleForReading.readDataToEndOfFile(),
                    as: UTF8.self
                )
                throw NativeBridgeTestError.processTimeout(diagnostics)
            }
            throw invocationError
        }
    }
}

private enum NativeBridgeTestError: Error {
    case apiFailure(LocalAPIErrorCode, String)
    case correlationMismatch
    case fixtureDirectoryChanged(String)
    case injectedCredentialDeleteFailure
    case injectedReapFailure
    case injectedSetupFailure
    case injectedWriteFailure
    case markerFailure(String)
    case mcpFailure(String)
    case missingExecutable(String)
    case processDidNotExit(Int32)
    case processTimeout(String)
    case truncatedFrame(String)
    case unsafeFixtureDirectory(String)
}
