import Foundation
import XCTest
import PlainpostCore
@testable import PlainpostCLI
import PlainpostOperations
import PlainpostServiceIPC

final class PlainpostCLIRoutingTests: XCTestCase {
    func testCredentialCommandUsesInjectedServiceWithoutSpawningExecutable() async throws {
        let client = RecordingPlainpostServiceClient()
        let output = CLIOutputRecorder()
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError
        )

        let status = try await cli.run([
            "account", "sync", "account-1", "--json",
        ])

        XCTAssertEqual(status, 0)
        let performedKinds = await client.performedKinds
        XCTAssertEqual(performedKinds, [.inboxSync])
        XCTAssertEqual(output.stderr, [])
        XCTAssertTrue(output.stdout.joined().contains(#""account":"account-1""#))
    }

    func testLockedCredentialCommandNeverRequestsForegroundAuthorization() async throws {
        let client = RecordingPlainpostServiceClient(performError: .vaultLocked)
        let output = CLIOutputRecorder()
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError
        )

        let status = try await cli.run([
            "account", "sync", "account-1", "--json",
        ])

        XCTAssertEqual(status, 1)
        let unlockReasons = await client.unlockReasons
        XCTAssertEqual(unlockReasons, [])
        XCTAssertTrue(output.stdout.joined().contains(#""code":"VAULT_LOCKED""#))
    }

    func testUnavailableServiceFailsClosedForEveryMailAction() async throws {
        let client = RecordingPlainpostServiceClient(
            performError: .serviceUnavailable
        )
        let output = CLIOutputRecorder()
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError
        )

        let commands: [([String], PlainpostForegroundOperationKind)] = [
            (["mail", "mark-read", "msg_alice_1", "--json"], .markRead),
            (["mail", "mark-unread", "msg_alice_1", "--json"], .markUnread),
            (["mail", "archive", "msg_alice_1", "--json"], .archive),
            (["mail", "delete", "msg_alice_1", "--json"], .delete),
        ]

        for (command, _) in commands {
            let status = try await cli.run(command)
            XCTAssertEqual(status, 1, command.joined(separator: " "))
        }

        let performedKinds = await client.performedKinds
        XCTAssertEqual(performedKinds, commands.map(\.1))
        XCTAssertTrue(
            output.stdout.joined().contains(
                #""code":"SERVICE_UNAVAILABLE""#
            )
        )
        let combinedOutput = output.stdout.joined()
        XCTAssertFalse(combinedOutput.contains(#""seen":true"#))
        XCTAssertFalse(combinedOutput.contains(#""deleted":true"#))
    }

    func testVaultUnlockIsTheOnlyCLICommandThatRequestsForegroundAuthorization() async throws {
        let client = RecordingPlainpostServiceClient()
        let output = CLIOutputRecorder()
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError
        )

        _ = try await cli.run(["vault", "status", "--json"])
        _ = try await cli.run(["account", "sync", "account-1", "--json"])
        _ = try await cli.run(["vault", "unlock", "--json"])

        let unlockReasons = await client.unlockReasons
        XCTAssertEqual(unlockReasons, ["Unlock Plainpost for this service session"])
    }

    func testEveryCredentialCommandUsesAClosedTypedServiceOperation()
        async throws
    {
        let client = RecordingPlainpostServiceClient()
        let output = CLIOutputRecorder()
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
                "--password", "test-secret",
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
                "--password", "add-secret",
                "--json",
            ],
            ["account", "sync", "account-1", "--json"],
            [
                "draft", "sync", "draft-1",
                "--to-server", "--json",
            ],
            ["mail", "mark-read", "message-1", "--json"],
            ["mail", "mark-unread", "message-1", "--json"],
            [
                "mail", "archive", "message-1",
                "--archive-mailbox", "Processed/2026",
                "--json",
            ],
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
            XCTAssertEqual(status, 0, command.joined(separator: " "))
        }

        let kinds = await client.performedKinds
        XCTAssertEqual(
            kinds,
            [
                .accountTest, .accountAdd, .inboxSync,
                .markRead, .markUnread, .archive, .delete,
            ]
        )
        let syncedDraftIDs = await client.syncedDraftIDs
        XCTAssertEqual(syncedDraftIDs, ["draft-1"])
        let archiveMailboxes = await client.archiveMailboxes
        XCTAssertEqual(archiveMailboxes, ["Processed/2026"])
        let batchRequests = await client.smartInboxBatchRequests
        XCTAssertEqual(
            batchRequests,
            [
                .init(
                    accountID: "account-1",
                    category: "seen",
                    action: "archive_read",
                    archiveMailbox: "Archive"
                ),
            ]
        )
        XCTAssertFalse(output.stdout.joined().contains("test-secret"))
        XCTAssertFalse(output.stdout.joined().contains("add-secret"))
    }

    func testDeleteErasesOnlyWithAnExplicitPermanentFlagOrField() async throws {
        let client = RecordingPlainpostServiceClient()
        let output = CLIOutputRecorder()
        let input = MCPLineInput([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.delete","arguments":{"message_id":"message-1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.delete","arguments":{"message_id":"message-1","permanent":true}}}"#,
        ])
        let cli = PlainpostCLI(
            serviceClient: client, stdout: output.writeOut, stderr: output.writeError, mcpReadLine: input.next
        )

        _ = try await cli.run(["mail", "delete", "message-1", "--json"])
        _ = try await cli.run(["mail", "delete", "message-1", "--permanent", "--json"])
        _ = try await cli.run(["mcp", "serve"])

        let flags = await client.deletePermanentFlags
        XCTAssertEqual(flags, [false, true, false, true])
    }

    func testDeleteNamesTheCopyToActOnFromCLIAndMCP() async throws {
        let client = RecordingPlainpostServiceClient()
        let output = CLIOutputRecorder()
        let input = MCPLineInput([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.delete","arguments":{"message_id":"message-1","source_mailbox":"Sent"}}}"#,
        ])
        let cli = PlainpostCLI(
            serviceClient: client, stdout: output.writeOut, stderr: output.writeError, mcpReadLine: input.next
        )

        _ = try await cli.run(["mail", "delete", "message-1", "--source-mailbox", "INBOX", "--json"])
        _ = try await cli.run(["mail", "delete", "message-1", "--json"])
        _ = try await cli.run(["mcp", "serve"])

        let mailboxes = await client.sourceMailboxes
        XCTAssertEqual(mailboxes, ["INBOX", nil, "Sent"])
    }

    func testDeleteRepliesSayWhatHappened() {
        func reply(_ result: PlainpostMailActionSemanticResult) -> [String: Any] {
            var payload: [String: Any] = [:]
            PlainpostCLIDeleteReply.describe(result, into: &payload)
            return payload
        }
        let moved = reply(.init(messageID: "m", mailboxPath: "Trash", isDeleted: false, deleteOutcome: .movedToTrash))
        XCTAssertEqual(moved["outcome"] as? String, "moved_to_trash")
        XCTAssertEqual(moved["deleted"] as? Bool, false)
        XCTAssertEqual(moved["mailbox"] as? String, "Trash")
        // An erase of the Trash copy while the message keeps a copy in Sent.
        let partial = reply(.init(messageID: "m", mailboxPath: "Sent", isDeleted: false, deleteOutcome: .deletedPermanently))
        XCTAssertEqual(partial["deleted"] as? Bool, true, "that copy was erased")
        XCTAssertEqual(partial["remaining_mailbox"] as? String, "Sent")
        XCTAssertNil(partial["mailbox"])
    }

    func testCLIShowsARefusalThatCrossedXPC() async throws {
        let client = RecordingPlainpostServiceClient()
        await client.failDeletes(with: PlainpostServiceClientError.mailActionRefused(.noTrash))
        let output = CLIOutputRecorder()
        let cli = PlainpostCLI(serviceClient: client, stdout: output.writeOut, stderr: output.writeError)

        _ = try await cli.run(["mail", "delete", "message-1", "--json"])

        let printed = output.stdout.joined() + output.stderr.joined()
        XCTAssertTrue(printed.contains("VALIDATION_FAILED"), printed)
        XCTAssertTrue(printed.contains("no Trash mailbox"), printed)
    }

    func testCLIShowsAServiceRefusalInsteadOfServiceUnavailable() async throws {
        let client = RecordingPlainpostServiceClient()
        await client.failDeletes(with: PlainpostError.validationFailed(TrashDelete.noTrashMessage))
        let output = CLIOutputRecorder()
        let cli = PlainpostCLI(serviceClient: client, stdout: output.writeOut, stderr: output.writeError)

        _ = try await cli.run(["mail", "delete", "message-1", "--json"])

        let printed = output.stdout.joined() + output.stderr.joined()
        XCTAssertTrue(printed.contains("VALIDATION_FAILED"), printed)
        XCTAssertTrue(printed.contains("no Trash mailbox"), printed)
        XCTAssertFalse(printed.contains("SERVICE_UNAVAILABLE"), printed)
    }

    func testAccountScopedMCPBatchUsesDedicatedTypedServiceOperation()
        async throws
    {
        let client = RecordingPlainpostServiceClient()
        let output = CLIOutputRecorder()
        let input = MCPLineInput([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.smart_inbox_batch","arguments":{"category":"seen","action":"archive_read","account_id":"account-1","archive_mailbox":"Archive"}}}"#,
        ])
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError,
            mcpReadLine: input.next
        )

        let status = try await cli.run(["mcp", "serve"])

        XCTAssertEqual(status, 0)
        let batchRequests = await client.smartInboxBatchRequests
        XCTAssertEqual(
            batchRequests,
            [
                .init(
                    accountID: "account-1",
                    category: "seen",
                    action: "archive_read",
                    archiveMailbox: "Archive"
                ),
            ]
        )
        XCTAssertTrue(
            output.stdout.joined().contains(#""affected_count":1"#),
            output.stdout.joined()
        )
    }

    func testAccountScopedBatchFailsClosedWhenServiceIsLockedOrUnavailable()
        async throws
    {
        for serviceError in [
            PlainpostServiceClientError.vaultLocked,
            .serviceUnavailable,
        ] {
            let client = RecordingPlainpostServiceClient(
                smartInboxBatchError: serviceError
            )
            let output = CLIOutputRecorder()
            let cli = PlainpostCLI(
                serviceClient: client,
                stdout: output.writeOut,
                stderr: output.writeError
            )

            let status = try await cli.run([
                "smart-inbox", "batch", "seen",
                "--action", "archive-read",
                "--account", "account-1",
                "--json",
            ])

            XCTAssertEqual(status, 1)
            let snapshot = await client.smartInboxBatchRequests
            XCTAssertEqual(snapshot.count, 1)
            let unlockReasons = await client.unlockReasons
            XCTAssertEqual(unlockReasons, [])
            XCTAssertFalse(
                output.stdout.joined().contains(#""affected_count""#)
            )
        }
    }

    func testEveryRoutedCLIAndMCPRoutePreservesExactCompatibilityEnvelope()
        async throws
    {
        let client = RecordingPlainpostServiceClient()
        let output = CLIOutputRecorder()
        let cli = PlainpostCLI(
            serviceClient: client,
            stdout: output.writeOut,
            stderr: output.writeError
        )
        let cliCases: [([String], [String: Any])] = [
            (
                [
                    "account", "test",
                    "--imap-host", "imap.example.com",
                    "--imap-port", "993",
                    "--smtp-host", "smtp.example.com",
                    "--smtp-port", "465",
                    "--username", "me@example.com",
                    "--password", "secret",
                    "--json",
                ],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "account_test",
                        "imap": true,
                        "smtp": true,
                    ],
                ]
            ),
            (
                [
                    "account", "add",
                    "--display-name", "Me",
                    "--email", "me@example.com",
                    "--imap-host", "imap.example.com",
                    "--imap-port", "993",
                    "--smtp-host", "smtp.example.com",
                    "--smtp-port", "465",
                    "--username", "me@example.com",
                    "--password", "secret",
                    "--json",
                ],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "account_add",
                        "account_id": "account-1",
                        "email": "me@example.com",
                        "imap_verified": true,
                        "smtp_verified": true,
                        "synced_message_count": 0,
                    ],
                ]
            ),
            (
                ["account", "sync", "account-1", "--json"],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "sync_inbox",
                        "account": "account-1",
                        "synced_message_count": 1,
                        "newly_discovered_message_count": 1,
                        "message_ids": ["message-1"],
                        "mailboxes": [["path": "INBOX"]],
                        "messages": [[
                            "message_id": "message-1",
                            "subject": "Service sync",
                            "preview": "Synced through PlainpostService.",
                            "path": "INBOX",
                        ]],
                        "job_id": "job-1",
                    ],
                ]
            ),
            (
                [
                    "draft", "sync", "draft-1",
                    "--to-server", "--json",
                ],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "draft_sync",
                        "draft_id": "draft-1",
                        "mailbox": "Drafts",
                        "server_draft_mailbox_id": "Drafts",
                        "server_draft_uid": 7,
                        "synced_to_server": true,
                    ],
                ]
            ),
            (
                ["mail", "mark-read", "message-1", "--json"],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "mark_read",
                        "message_id": "message-1",
                        "seen": true,
                        "deleted": false,
                    ],
                ]
            ),
            (
                ["mail", "mark-unread", "message-1", "--json"],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "mark_unread",
                        "message_id": "message-1",
                        "seen": false,
                        "deleted": false,
                    ],
                ]
            ),
            (
                [
                    "mail", "archive", "message-1",
                    "--archive-mailbox", "Processed/2026",
                    "--json",
                ],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "archive",
                        "message_id": "message-1",
                        "mailbox": "Processed/2026",
                        "archived": true,
                        "deleted": false,
                    ],
                ]
            ),
            (
                ["mail", "delete", "message-1", "--json"],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "delete",
                        "message_id": "message-1",
                        "deleted": true,
                    ],
                ]
            ),
            (
                [
                    "smart-inbox", "batch", "seen",
                    "--action", "archive-read",
                    "--account", "account-1",
                    "--archive-mailbox", "Processed/2026",
                    "--json",
                ],
                [
                    "ok": true,
                    "data": [
                        "service": "PlainpostService",
                        "action": "smart_inbox_batch",
                        "requested_action": "archive_read",
                        "category": "seen",
                        "message_ids": ["message-1"],
                        "affected_count": 1,
                        "mailbox": "Processed/2026",
                    ],
                ]
            ),
        ]

        for (arguments, expected) in cliCases {
            let before = output.stdout.count
            let status = try await cli.run(arguments)
            XCTAssertEqual(status, 0, arguments.joined(separator: " "))
            XCTAssertEqual(output.stdout.count, before + 1)
            try assertJSONEqual(
                try XCTUnwrap(output.stdout.last),
                expected
            )
        }

        let mcpOutput = CLIOutputRecorder()
        let mcpInput = MCPLineInput([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.mark_seen","arguments":{"message_id":"message-1","seen":true}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.mark_seen","arguments":{"message_id":"message-1","seen":false}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"email.archive","arguments":{"message_id":"message-1","archive_mailbox":"Processed/2026"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"email.delete","arguments":{"message_id":"message-1"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"email.sync_draft","arguments":{"draft_id":"draft-1","drafts_mailbox":"Drafts/Work"}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"email.smart_inbox_batch","arguments":{"category":"seen","action":"archive_read","account_id":"account-1","archive_mailbox":"Processed/2026"}}}"#,
        ])
        let mcpCLI = PlainpostCLI(
            serviceClient: client,
            stdout: mcpOutput.writeOut,
            stderr: mcpOutput.writeError,
            mcpReadLine: mcpInput.next
        )

        let mcpStatus = try await mcpCLI.run(["mcp", "serve"])
        XCTAssertEqual(mcpStatus, 0)
        let expectedMCPPayloads: [[String: Any]] = [
            [
                "service": "PlainpostService",
                "action": "mark_read",
                "message_id": "message-1",
                "seen": true,
            ],
            [
                "service": "PlainpostService",
                "action": "mark_unread",
                "message_id": "message-1",
                "seen": false,
            ],
            [
                "service": "PlainpostService",
                "action": "archive",
                "message_id": "message-1",
                "mailbox": "Processed/2026",
                "archived": true,
                "deleted": false,
            ],
            [
                "service": "PlainpostService",
                "action": "delete",
                "message_id": "message-1",
                "deleted": true,
            ],
            [
                "service": "PlainpostService",
                "action": "draft_sync",
                "draft_id": "draft-1",
                "mailbox": "Drafts/Work",
                "server_draft_mailbox_id": "Drafts/Work",
                "server_draft_uid": 7,
                "synced_to_server": true,
            ],
            [
                "service": "PlainpostService",
                "action": "smart_inbox_batch",
                "requested_action": "archive_read",
                "category": "seen",
                "message_ids": ["message-1"],
                "affected_count": 1,
                "mailbox": "Processed/2026",
            ],
        ]
        XCTAssertEqual(mcpOutput.stdout.count, expectedMCPPayloads.count)
        for (index, expected) in expectedMCPPayloads.enumerated() {
            try assertExactMCPResult(
                mcpOutput.stdout[index],
                id: index + 1,
                structuredContent: expected
            )
        }
    }

    func testEveryRoutedCLIAndMCPRoutePreservesExactLockedAndUnavailableErrors()
        async throws
    {
        let serviceCases: [
            (
                error: PlainpostServiceClientError,
                code: String,
                message: String
            )
        ] = [
            (
                .vaultLocked,
                "VAULT_LOCKED",
                "Plainpost is locked. Unlock it explicitly before retrying."
            ),
            (
                .serviceUnavailable,
                "SERVICE_UNAVAILABLE",
                "PlainpostService is unavailable."
            ),
        ]
        let cliCases: [[String]] = [
            [
                "account", "test",
                "--imap-host", "imap.example.com",
                "--imap-port", "993",
                "--smtp-host", "smtp.example.com",
                "--smtp-port", "465",
                "--username", "me@example.com",
                "--password", "secret",
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
                "--password", "secret",
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
                "--json",
            ],
        ]
        let mcpLines = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"email.smart_inbox_batch","arguments":{"category":"seen","action":"archive_read","account_id":"account-1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"email.mark_seen","arguments":{"message_id":"message-1","seen":true}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"email.archive","arguments":{"message_id":"message-1"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"email.delete","arguments":{"message_id":"message-1"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"email.sync_draft","arguments":{"draft_id":"draft-1"}}}"#,
        ]

        for serviceCase in serviceCases {
            let client = RecordingPlainpostServiceClient(
                performError: serviceCase.error,
                smartInboxBatchError: serviceCase.error,
                draftSyncError: serviceCase.error
            )
            let cliOutput = CLIOutputRecorder()
            let cli = PlainpostCLI(
                serviceClient: client,
                stdout: cliOutput.writeOut,
                stderr: cliOutput.writeError
            )
            let expectedCLIError: [String: Any] = [
                "ok": false,
                "error": [
                    "code": serviceCase.code,
                    "message": serviceCase.message,
                ],
            ]

            for arguments in cliCases {
                let before = cliOutput.stdout.count
                let status = try await cli.run(arguments)
                XCTAssertEqual(status, 1, arguments.joined(separator: " "))
                XCTAssertEqual(cliOutput.stdout.count, before + 1)
                try assertJSONEqual(
                    try XCTUnwrap(cliOutput.stdout.last),
                    expectedCLIError
                )
            }

            let mcpOutput = CLIOutputRecorder()
            let mcpInput = MCPLineInput(mcpLines)
            let mcpCLI = PlainpostCLI(
                serviceClient: client,
                stdout: mcpOutput.writeOut,
                stderr: mcpOutput.writeError,
                mcpReadLine: mcpInput.next
            )
            let mcpStatus = try await mcpCLI.run(["mcp", "serve"])
            XCTAssertEqual(mcpStatus, 0)
            XCTAssertEqual(mcpOutput.stdout.count, mcpLines.count)
            for (index, line) in mcpOutput.stdout.enumerated() {
                try assertJSONEqual(
                    line,
                    [
                        "jsonrpc": "2.0",
                        "id": index + 1,
                        "error": [
                            "code": -32003,
                            "message": serviceCase.message,
                            "data": ["code": serviceCase.code],
                        ],
                    ]
                )
            }
        }
    }
}

private actor RecordingPlainpostServiceClient: PlainpostServiceClientProtocol {
    private let performError: PlainpostServiceClientError?
    private let smartInboxBatchError: PlainpostServiceClientError?
    private let draftSyncError: PlainpostServiceClientError?
    private(set) var performedKinds: [PlainpostForegroundOperationKind] = []
    private(set) var unlockReasons: [String] = []
    private(set) var syncedDraftIDs: [String] = []
    private(set) var archiveMailboxes: [String] = []
    private(set) var deletePermanentFlags: [Bool] = []
    private(set) var sourceMailboxes: [String?] = []
    /// When set, `.delete` throws it, as the service does for a refusal.
    var deleteError: (any Error)?
    func failDeletes(with error: any Error) { deleteError = error }
    private(set) var smartInboxBatchRequests:
        [PlainpostSmartInboxBatchRequest] = []

    init(
        performError: PlainpostServiceClientError? = nil,
        smartInboxBatchError: PlainpostServiceClientError? = nil,
        draftSyncError: PlainpostServiceClientError? = nil
    ) {
        self.performError = performError
        self.smartInboxBatchError = smartInboxBatchError
        self.draftSyncError = draftSyncError
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
        syncedDraftIDs.append(draftID)
        if let draftSyncError {
            throw draftSyncError
        }
        return PlainpostDraftSyncResult(
            draftID: draftID,
            mailbox: mailbox,
            serverDraftUID: 7
        )
    }

    func performSmartInboxBatch(
        _ request: PlainpostSmartInboxBatchRequest
    ) async throws -> PlainpostSmartInboxBatchResult {
        smartInboxBatchRequests.append(request)
        if let smartInboxBatchError {
            throw smartInboxBatchError
        }
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
        performedKinds.append(operation.kind)
        if let performError {
            throw performError
        }
        switch operation {
        case .inboxSync(let input):
            return .inboxSync(
                PlainpostInboxSyncResult(
                    accountID: input.accountID,
                    syncedMessageCount: 1,
                    newMessageIDs: [MessageID("message-1")],
                    jobID: "job-1",
                    mailboxes: [
                        PlainpostInboxSyncMailboxMetadata(path: "INBOX"),
                    ],
                    messages: [
                        PlainpostInboxSyncMessageMetadata(
                            messageID: MessageID("message-1"),
                            subject: "Service sync",
                            preview: "Synced through PlainpostService.",
                            path: "INBOX"
                        ),
                    ]
                )
            )
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
            archiveMailboxes.append(input.archiveMailbox ?? "Archive")
            return .archive(
                PlainpostMailActionSemanticResult(
                    messageID: input.messageID,
                    mailboxPath: input.archiveMailbox ?? "Archive",
                    isDeleted: false
                )
            )
        case .delete(let input):
            deletePermanentFlags.append(input.permanent)
            sourceMailboxes.append(input.sourceMailbox)
            if let deleteError { throw deleteError }
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

private final class MCPLineInput: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String]

    init(_ lines: [String]) {
        self.lines = lines
    }

    func next() -> String? {
        lock.withLock {
            lines.isEmpty ? nil : lines.removeFirst()
        }
    }
}

private final class CLIOutputRecorder: @unchecked Sendable {
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
        lock.withLock {
            capturedStdout.append(value)
        }
    }

    func writeError(_ value: String) {
        lock.withLock {
            capturedStderr.append(value)
        }
    }
}

private func assertJSONEqual(
    _ actual: String,
    _ expected: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let actualObject = try JSONSerialization.jsonObject(
        with: Data(actual.utf8)
    )
    let actualData = try JSONSerialization.data(
        withJSONObject: actualObject,
        options: [.sortedKeys]
    )
    let expectedData = try JSONSerialization.data(
        withJSONObject: expected,
        options: [.sortedKeys]
    )
    XCTAssertEqual(actualData, expectedData, file: file, line: line)
}

private func assertExactMCPResult(
    _ actual: String,
    id: Int,
    structuredContent expected: [String: Any],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: Data(actual.utf8)
        ) as? [String: Any],
        file: file,
        line: line
    )
    XCTAssertEqual(object["jsonrpc"] as? String, "2.0", file: file, line: line)
    XCTAssertEqual(object["id"] as? Int, id, file: file, line: line)
    XCTAssertNil(object["error"], file: file, line: line)

    let result = try XCTUnwrap(
        object["result"] as? [String: Any],
        file: file,
        line: line
    )
    XCTAssertEqual(
        Set(result.keys),
        Set(["content", "structuredContent"]),
        file: file,
        line: line
    )
    let structuredContent = try XCTUnwrap(
        result["structuredContent"] as? [String: Any],
        file: file,
        line: line
    )
    try assertJSONObjectEqual(
        structuredContent,
        expected,
        file: file,
        line: line
    )

    let content = try XCTUnwrap(
        result["content"] as? [[String: Any]],
        file: file,
        line: line
    )
    XCTAssertEqual(content.count, 1, file: file, line: line)
    XCTAssertEqual(content.first?["type"] as? String, "text", file: file, line: line)
    let text = try XCTUnwrap(
        content.first?["text"] as? String,
        file: file,
        line: line
    )
    let textObject = try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: Data(text.utf8)
        ) as? [String: Any],
        file: file,
        line: line
    )
    try assertJSONObjectEqual(textObject, expected, file: file, line: line)
}

private func assertJSONObjectEqual(
    _ actual: [String: Any],
    _ expected: [String: Any],
    file: StaticString,
    line: UInt
) throws {
    let actualData = try JSONSerialization.data(
        withJSONObject: actual,
        options: [.sortedKeys]
    )
    let expectedData = try JSONSerialization.data(
        withJSONObject: expected,
        options: [.sortedKeys]
    )
    XCTAssertEqual(actualData, expectedData, file: file, line: line)
}
