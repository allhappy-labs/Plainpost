import Darwin
import Foundation
import XCTest
import PlainpostCLI
import PlainpostCore
import PlainpostDB
import PlainpostOperations
import PlainpostServiceIPC
import PlainpostTestSupport

/// Signed-service CLI integration harness.
///
/// The retired harness launched an unsigned service child and passed
/// credential capabilities through inherited descriptors. These tests keep
/// the public CLI/MCP shapes active while exercising credential commands only
/// through an injected, bounded service client. No test touches a user
/// Keychain.
final class PlainpostCLIServiceBoundaryTests: XCTestCase {
    func testProductionVaultBoundary() throws {
        let repositoryRoot = Self.repositoryRoot
        let process = Process()
        process.currentDirectoryURL = repositoryRoot
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appendingPathComponent(
                "Scripts/plainpost/assert-service-vault-boundary.sh"
            ).path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        let completeOutput = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, completeOutput)
    }

    func testEveryCredentialCommandUsesInjectedTypedServiceOperations()
        async throws
    {
        let client = HarnessServiceClient()
        let output = HarnessOutput()
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError
        )
        let commands: [[String]] = [
            [
                "account", "test",
                "--imap-host", "imap.example.com",
                "--imap-port", "993",
                "--smtp-host", "smtp.example.com",
                "--smtp-port", "465",
                "--username", "me@example.com",
                "--password", "account-test-secret",
                "--json",
            ],
            [
                "account", "add",
                "--display-name", "Me",
                "--email", "me@example.com",
                "--imap-host", "imap.example.com",
                "--imap-port", "993",
                "--smtp-host", "smtp.example.com",
                "--smtp-port", "465",
                "--username", "me@example.com",
                "--password", "account-add-secret",
                "--json",
            ],
            ["account", "sync", "account-1", "--json"],
            ["draft", "sync", "draft-1", "--to-server", "--json"],
            ["mail", "mark-read", "message-1", "--json"],
            ["mail", "mark-unread", "message-1", "--json"],
            ["mail", "archive", "message-1", "--json"],
            ["mail", "delete", "message-1", "--json"],
            [
                "smart-inbox", "batch", "seen",
                "--action", "archive-read",
                "--account", "account-1",
                "--archive-mailbox", "Archive",
                "--json",
            ],
        ]

        for command in commands {
            let status = try await cli.run(command)
            XCTAssertEqual(
                status,
                0,
                command.joined(separator: " ")
            )
        }

        let snapshot = await client.snapshot()
        XCTAssertEqual(
            snapshot.operationKinds,
            [
                .accountTest,
                .accountAdd,
                .inboxSync,
                .markRead,
                .markUnread,
                .archive,
                .delete,
            ]
        )
        XCTAssertEqual(snapshot.syncedDraftIDs, ["draft-1"])
        XCTAssertEqual(
            snapshot.smartInboxBatchRequests,
            [
                PlainpostSmartInboxBatchRequest(
                    accountID: "account-1",
                    category: "seen",
                    action: "archive_read",
                    archiveMailbox: "Archive"
                ),
            ]
        )
        XCTAssertEqual(snapshot.unlockReasons, [])
        XCTAssertTrue(output.stderr.isEmpty)
        XCTAssertFalse(output.stdout.joined().contains("account-test-secret"))
        XCTAssertFalse(output.stdout.joined().contains("account-add-secret"))
    }

    func testUnavailableServiceFailsClosedWithoutLocalExecution() async throws {
        let client = HarnessServiceClient(performError: .serviceUnavailable)
        let output = HarnessOutput()
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError
        )

        let status = try await cli.run([
            "mail", "mark-read", "msg_alice_1", "--json",
        ])

        XCTAssertEqual(status, 1)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.operationKinds, [.markRead])
        XCTAssertTrue(
            output.stdout.joined().contains(
                #""code":"SERVICE_UNAVAILABLE""#
            )
        )
        XCTAssertFalse(output.stdout.joined().contains(#""seen":true"#))
    }

    func testLockedCredentialCommandsStayQuietUntilExplicitUnlock()
        async throws
    {
        let client = HarnessServiceClient(performError: .vaultLocked)
        let output = HarnessOutput()
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError
        )

        let lockedStatus = try await cli.run([
            "account", "sync", "account-1", "--json",
        ])
        XCTAssertEqual(lockedStatus, 1)
        let lockedSnapshot = await client.snapshot()
        XCTAssertEqual(lockedSnapshot.unlockReasons, [])
        XCTAssertTrue(
            output.stdout.joined().contains(#""code":"VAULT_LOCKED""#)
        )

        _ = try await cli.run(["vault", "unlock", "--json"])
        let unlockedSnapshot = await client.snapshot()
        XCTAssertEqual(
            unlockedSnapshot.unlockReasons,
            ["Unlock Plainpost for this service session"]
        )
    }

    func testServiceFailuresPreserveTypedUserFacingCodes() async throws {
        let cases: [(PlainpostServiceClientError, String)] = [
            (.vaultKeyMissing, "VAULT_KEY_MISSING"),
            (.vaultKeyAmbiguous, "VAULT_KEY_AMBIGUOUS"),
            (.ciphertextInvalid, "VAULT_CIPHERTEXT_INVALID"),
            (.unsupportedVaultVersion(7), "VAULT_VERSION_UNSUPPORTED"),
            (.authorizationCancelled, "AUTHORIZATION_CANCELLED"),
            (.authorizationFailed, "AUTHORIZATION_FAILED"),
        ]

        for (serviceError, expectedCode) in cases {
            let client = HarnessServiceClient(performError: serviceError)
            let output = HarnessOutput()
            let cli = PlainpostCLI(
                serviceClient: client,
                stdout: output.writeOut,
                stderr: output.writeError
            )

            let status = try await cli.run([
                "account", "sync", "account-1", "--json",
            ])
            XCTAssertEqual(
                status,
                1
            )
            XCTAssertTrue(
                output.stdout.joined().contains(
                    #""code":"\#(expectedCode)""#
                ),
                output.stdout.joined()
            )
        }
    }

    func testMCPStdinRemainsUsableWithoutCredentialDescriptors() throws {
        let request =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
            + "\n"
        let result = try PlainpostProductProcess.run(
            ["mcp", "serve"],
            standardInput: request
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(
            result.output.contains(#""protocolVersion":"2024-11-05""#),
            result.output
        )
        XCTAssertFalse(
            result.output.localizedCaseInsensitiveContains("credential"),
            result.output
        )
        XCTAssertFalse(
            result.output.localizedCaseInsensitiveContains("password"),
            result.output
        )
    }

    func testDefaultCLIAndMCPSearchUseNormalApplicationSupportDatabase()
        throws
    {
        let homeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "plainpost-default-search-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let applicationSupportURL = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
            .appendingPathComponent("Plainpost", isDirectory: true)
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        let store = try SQLiteMailStore(
            path: applicationSupportURL
                .appendingPathComponent("Plainpost.sqlite").path
        )
        try store.migrate()
        try store.cacheAccounts([PlainpostFixtures.personalAccount])
        try store.cacheMailboxes([PlainpostFixtures.inboxMailbox])
        try store.cacheThread(PlainpostFixtures.aliceThread)
        let message = MessageSummary(
            id: MessageID("message-default-application-support"),
            threadID: PlainpostFixtures.aliceThread.id,
            from: EmailAddress("database@example.com"),
            subject: "Workspace Default Sentinel",
            preview: "Only the normal Application Support database has this.",
            smartCategory: .personal
        )
        _ = try store.commitIncomingMessage(
            message,
            metadata: IncomingMessageSearchMetadata(
                to: [],
                cc: [],
                bcc: [],
                attachments: [],
                messageIdentifiers: []
            ),
            accountID: PlainpostFixtures.personalAccount.id,
            mailboxPath: "INBOX",
            uidValidity: 1,
            uid: 55,
            notificationEligible: false
        )
        let environment = [
            "HOME": homeURL.path,
            "PLAINPOST_SERVICE_EXECUTABLE":
                "/missing/PlainpostService",
        ]

        let result = try PlainpostProductProcess.run(
            ["mail", "search", "workspace default sentinel", "--json"],
            environment: [
                "HOME": homeURL.path,
                "PLAINPOST_SERVICE_EXECUTABLE":
                    "/missing/PlainpostService",
            ]
        )
        let mcpRequest =
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.search","arguments":{"query":"workspace default sentinel"}}}"#
        let mcp = try PlainpostProductProcess.run(
            ["mcp", "serve"],
            standardInput: mcpRequest + "\n",
            environment: environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains(#""ok":true"#), result.output)
        XCTAssertTrue(
            result.output.contains(
                "message-default-application-support"
            ),
            result.output
        )
        XCTAssertFalse(result.output.contains("msg_alice_1"), result.output)
        XCTAssertFalse(
            result.output.contains("SERVICE_UNAVAILABLE"),
            result.output
        )
        XCTAssertEqual(mcp.status, 0, mcp.output)
        XCTAssertTrue(
            mcp.output.contains(
                "message-default-application-support"
            ),
            mcp.output
        )
        XCTAssertFalse(mcp.output.contains("msg_alice_1"), mcp.output)
    }

    func testSignedClientsContainNoSubprocessOrCredentialCapabilityBridge()
        throws
    {
        for relativePath in [
            "Sources/PlainpostCLI/PlainpostCLI.swift",
            "Sources/plainpost/main.swift",
            "Sources/PlainpostBackgroundAgent/main.swift",
            "Sources/PlainpostBrowserBridge/main.swift",
        ] {
            let source = try String(
                contentsOf: Self.repositoryRoot.appendingPathComponent(
                    relativePath
                ),
                encoding: .utf8
            )
            for forbidden in [
                "PlainpostServiceBridge",
                "runPlainpostService",
                "plainpostServicePayload",
                "InheritedCredentialCapability",
                "SQLiteCredentialVaultAssembly",
                "KeychainCredentialStore",
                "posix_spawn",
                "Process()",
            ] {
                XCTAssertFalse(
                    source.contains(forbidden),
                    "\(relativePath) retained \(forbidden)"
                )
            }
        }

        for deletedLegacyRuntime in [
            "Sources/PlainpostDeviceRuntime/PlainpostDeviceCompanionRuntime.swift",
            "Sources/PlainpostDeviceRuntime/PlainpostServiceDeviceCompanionController.swift",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: Self.repositoryRoot.appendingPathComponent(deletedLegacyRuntime).path
                ),
                "legacy runtime was restored: \(deletedLegacyRuntime)"
            )
        }

        let package = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        for deletedLegacyTarget in [
            "PlainpostDeviceRuntime",
            "PlainpostDeviceProtocol",
            "PlainpostMobileClient",
        ] {
            XCTAssertFalse(
                package.contains("name: \"\(deletedLegacyTarget)\""),
                "legacy package target was restored: \(deletedLegacyTarget)"
            )
        }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor HarnessServiceClient: PlainpostServiceClientProtocol {
    struct Snapshot: Sendable {
        let operationKinds: [PlainpostForegroundOperationKind]
        let syncedDraftIDs: [String]
        let smartInboxBatchRequests:
            [PlainpostSmartInboxBatchRequest]
        let unlockReasons: [String]
    }

    private let performError: PlainpostServiceClientError?
    private var operationKinds: [PlainpostForegroundOperationKind] = []
    private var syncedDraftIDs: [String] = []
    private var smartInboxBatchRequests:
        [PlainpostSmartInboxBatchRequest] = []
    private var unlockReasons: [String] = []

    init(performError: PlainpostServiceClientError? = nil) {
        self.performError = performError
    }

    func snapshot() -> Snapshot {
        Snapshot(
            operationKinds: operationKinds,
            syncedDraftIDs: syncedDraftIDs,
            smartInboxBatchRequests: smartInboxBatchRequests,
            unlockReasons: unlockReasons
        )
    }

    func status() async throws -> PlainpostVaultStatus {
        PlainpostVaultStatus(
            availability: .unlocked,
            matchingKeyItemCount: 1
        )
    }

    func unlock(reason: String) async throws {
        unlockReasons.append(reason)
    }

    func lock() async throws {}

    func syncDraftToServer(
        draftID: String,
        mailbox: String
    ) async throws -> PlainpostDraftSyncResult {
        if let performError {
            throw performError
        }
        syncedDraftIDs.append(draftID)
        return PlainpostDraftSyncResult(
            draftID: draftID,
            mailbox: mailbox,
            serverDraftUID: 41
        )
    }

    func performSmartInboxBatch(
        _ request: PlainpostSmartInboxBatchRequest
    ) async throws -> PlainpostSmartInboxBatchResult {
        if let performError {
            throw performError
        }
        smartInboxBatchRequests.append(request)
        return PlainpostSmartInboxBatchResult(
            accountID: request.accountID,
            category: request.category,
            action: request.action,
            affectedMessageIDs: ["message-1"],
            archiveMailbox: request.archiveMailbox
        )
    }

    func perform(
        _ operation: PlainpostForegroundOperation
    ) async throws -> PlainpostForegroundOperationResult {
        operationKinds.append(operation.kind)
        if let performError {
            throw performError
        }
        switch operation {
        case .accountTest:
            return .accountTest(
                PlainpostAccountTestSemanticResult(
                    isIMAPVerified: true,
                    isSMTPVerified: true
                )
            )
        case .accountAdd(let input):
            return .accountAdd(
                PlainpostAccountSetupSemanticResult(
                    accountID: "account-1",
                    email: input.email,
                    isIMAPVerified: true,
                    isSMTPVerified: true,
                    syncedMessageCount: 0
                )
            )
        case .inboxSync(let input):
            return .inboxSync(
                PlainpostInboxSyncResult(
                    accountID: input.accountID,
                    syncedMessageCount: 1,
                    jobID: "job-1"
                )
            )
        case .markRead(let input):
            return .markRead(
                PlainpostMailActionSemanticResult(
                    messageID: input.messageID,
                    seen: true,
                    isDeleted: false
                )
            )
        case .markUnread(let input):
            return .markUnread(
                PlainpostMailActionSemanticResult(
                    messageID: input.messageID,
                    seen: false,
                    isDeleted: false
                )
            )
        case .archive(let input):
            return .archive(
                PlainpostMailActionSemanticResult(
                    messageID: input.messageID,
                    mailboxPath: "Archive",
                    isDeleted: false
                )
            )
        case .delete(let input):
            return .delete(
                PlainpostMailActionSemanticResult(
                    messageID: input.messageID,
                    isDeleted: true
                )
            )
        default:
            throw PlainpostServiceClientError.operationFailed
        }
    }
}

private final class HarnessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedStdout: [String] = []
    private var capturedStderr: [String] = []

    var stdout: [String] {
        lock.withLock { capturedStdout }
    }

    var stderr: [String] {
        lock.withLock { capturedStderr }
    }

    func writeOut(_ value: String) {
        lock.withLock { capturedStdout.append(value) }
    }

    func writeError(_ value: String) {
        lock.withLock { capturedStderr.append(value) }
    }
}

private enum PlainpostProductProcess {
    struct Result {
        let status: Int32
        let output: String
    }

    static func run(
        _ arguments: [String],
        standardInput: String? = nil,
        environment: [String: String] = [:]
    ) throws -> Result {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent(
            "plainpost"
        )
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment
        ) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = standardInput.map { _ in Pipe() }
        process.standardInput = input

        try process.run()
        if let standardInput, let input {
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            output: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private static var productsDirectory: URL {
        for bundle in Bundle.allBundles
        where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Could not find the SwiftPM products directory.")
    }
}

/// Legacy integration-test executable helper retained for source compatibility
/// with pre-XPC search transport tests in this test target. Task 5 does not run
/// or use it for credential operations.
enum PlainpostServiceBoundaryProcess {
    static func run(
        _ arguments: [String],
        executableURL: URL? = nil,
        timeout: TimeInterval = 10
    ) throws -> String {
        let executable =
            executableURL
            ?? productsDirectory.appendingPathComponent("PlainpostService")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }

        try process.run()
        let timedOut =
            termination.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 1)
            }
        }
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        if timedOut || text.isEmpty || process.terminationStatus != 0 {
            return text
                + "\n<PlainpostService status=\(process.terminationStatus)"
                + " reason=\(process.terminationReason.rawValue)"
                + " timedOut=\(timedOut)>"
        }
        return text
    }

    static func runStdio(
        _ arguments: [String],
        input: String
    ) throws -> String {
        let process = Process()
        process.executableURL = productsDirectory.appendingPathComponent(
            "PlainpostService"
        )
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        let standardInput = Pipe()
        let output = Pipe()
        process.standardInput = standardInput
        process.standardOutput = output
        process.standardError = output

        try process.run()
        standardInput.fileHandleForWriting.write(Data(input.utf8))
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    }

    private static var productsDirectory: URL {
        for bundle in Bundle.allBundles
        where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Could not find the SwiftPM products directory.")
    }
}
