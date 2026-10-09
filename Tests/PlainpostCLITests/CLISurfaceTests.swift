import XCTest
import Darwin
import PlainpostTestSupport
@testable import PlainpostCore

final class CLISurfaceTests: XCTestCase {
    func testCLISourceDoesNotRetainObsoleteAgentAIEnvironmentPolicies() throws {
        let repositoryRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sourceURL = repositoryRoot.appendingPathComponent("Sources/PlainpostCLI/PlainpostCLI.swift")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceURL.path),
            "Expected CLI source file at \(sourceURL.path)"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("PLAINPOST_AGENT_USE_AI_"))
    }

    func testPlainpostCLISurfaceDoesNotExposeUnsafeSendCommands() {
        let surface = PlainpostCLICommandSurface.availableCommands

        XCTAssertTrue(surface.contains("send request"))
        XCTAssertTrue(surface.contains("send status"))
        XCTAssertTrue(surface.contains("smart-inbox batch"))
        XCTAssertFalse(surface.contains { $0.hasPrefix("ai ") })
        XCTAssertFalse(surface.contains("ai provider status"))
        XCTAssertFalse(surface.contains("send now"))
        XCTAssertFalse(surface.contains("send --yes"))
        XCTAssertFalse(surface.contains("approval approve"))
    }

    func testSendRequestHelpIsAvailableFromExecutable() throws {
        let output = try PlainpostCLIProcess.run(["send", "request", "--help"])

        XCTAssertTrue(output.contains("plainpost send request"))
        XCTAssertTrue(output.contains("requires local user approval"))
        XCTAssertFalse(output.contains("send now"))
    }

    func testCLIProcessTimesOutAndReapsAnUnresponsiveChild() throws {
        let startedAt = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; exec /usr/bin/tail -f /dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier

        XCTAssertThrowsError(
            try PlainpostProcessWaiter.waitForExit(process, timeout: 0.1)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH, "timed-out child still exists or was not reaped")
    }

    func testPlainpostServiceVersionOutputIsExact() throws {
        let result = try PlainpostServiceProcess.run(["--version"])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "PlainpostService 0.1.0\n")
    }

    func testPlainpostServiceRejectsHealthAndOtherModesWithEXUsage() throws {
        for arguments in [
            ["--health", "--json"],
            ["serve", "--stdio", "--json"],
            ["account", "list", "--json"],
        ] {
            let result = try PlainpostServiceProcess.run(arguments)

            XCTAssertEqual(
                result.status,
                64,
                "\(arguments): \(result.output)"
            )
            XCTAssertEqual(
                result.output,
                "PlainpostService supports only --xpc-service and --version.\n",
                "\(arguments)"
            )
        }
    }

    func testAccountListReturnsJSONWithoutSecrets() throws {
        let output = try PlainpostCLIProcess.run(["account", "list", "--json"])

        XCTAssertTrue(output.contains(#""ok":true"#))
        XCTAssertTrue(output.contains(#""email":"me@example.com""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
    }

    func testMailboxListReturnsSeededInboxJSON() throws {
        let output = try PlainpostCLIProcess.run(["mailbox", "list", "--json"])

        XCTAssertTrue(output.contains(#""ok":true"#))
        XCTAssertTrue(output.contains(#""path":"INBOX""#))
    }

    func testMailReadAndThreadReturnJSON() throws {
        let read = try PlainpostCLIProcess.run(["mail", "read", "msg_alice_1", "--include", "body", "--json"])
        XCTAssertTrue(read.contains(#""body":"Can you meet next Tuesday?""#))

        let thread = try PlainpostCLIProcess.run(["mail", "thread", "thr_alice_1", "--json"])
        XCTAssertTrue(thread.contains(#""participants":["alice@example.com","me@example.com"]"#))
    }

    func testMailSearchHelpDocumentsEveryRegisteredField() throws {
        let output = try PlainpostCLIProcess.run(["mail", "search", "--help"])

        XCTAssertTrue(output.contains("plainpost mail search QUERY"), output)
        for field in MailSearchFieldRegistry.all {
            XCTAssertTrue(output.contains("\(field.name):"), field.name)
            for example in field.examples {
                XCTAssertTrue(output.contains(example), example)
            }
        }
        XCTAssertTrue(output.contains("AND, OR, NOT, minus, and parentheses"), output)
        XCTAssertTrue(output.contains("Conversations are returned by default"), output)
        XCTAssertTrue(output.contains("next cursor"), output)
        XCTAssertTrue(output.contains("stale cursor"), output)
        XCTAssertTrue(output.contains("--account ACCOUNT_ID"), output)
        XCTAssertTrue(output.contains("--mailbox MAILBOX_ID"), output)
        XCTAssertTrue(output.contains("--mode conversations|messages"), output)
        XCTAssertTrue(output.contains("--limit 1...100"), output)
        XCTAssertTrue(output.contains("64 unique account IDs"), output)
        XCTAssertTrue(output.contains("256 unique mailbox IDs"), output)
        XCTAssertTrue(output.contains("256 UTF-8 bytes"), output)
    }

    func testMailSearchRejectsExcessAndLongScopesBeforeStartingService() throws {
        let tooManyAccounts = ["mail", "search", "project"] +
            (0 ... MailSearchScopeContract.maximumAccountCount).flatMap {
                ["--account", "account-\($0)"]
            } + ["--json"]
        let longID = String(
            repeating: "x",
            count: MailSearchScopeContract.maximumIdentifierUTF8Length + 1
        )

        for arguments in [
            tooManyAccounts,
            ["mail", "search", "project", "--mailbox", longID, "--json"],
        ] {
            let output = try PlainpostCLIProcess.run(
                arguments,
                environment: ["PLAINPOST_SERVICE_EXECUTABLE": "/missing/PlainpostService"]
            )
            XCTAssertTrue(output.contains(#""code":"VALIDATION_FAILED""#), output)
            XCTAssertFalse(output.contains("SERVICE_UNAVAILABLE"), output)
        }
    }

    func testMailSearchRemainsLocalWhenServiceExecutableIsMissing() throws {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let output = try PlainpostCLIProcess.run(
            ["mail", "search", "alice", "--json"],
            environment: [
                "PLAINPOST_APPLICATION_SUPPORT_DIR": applicationSupport.path,
                "PLAINPOST_SERVICE_EXECUTABLE": "/missing/PlainpostService",
            ]
        )

        XCTAssertTrue(output.contains(#""ok":true"#), output)
        XCTAssertTrue(output.contains(#""hits":[]"#), output)
        XCTAssertFalse(output.contains("msg_alice_1"), output)
        XCTAssertFalse(output.contains("SERVICE_UNAVAILABLE"), output)
    }

    func testMailSearchAcceptsLeadingMinusQuerySyntax() throws {
        let output = try PlainpostCLIProcess.run(
            ["mail", "search", "-from:alice", "--json"],
            environment: ["PLAINPOST_SERVICE_EXECUTABLE": "/missing/PlainpostService"]
        )

        XCTAssertTrue(output.contains(#""ok":true"#), output)
        XCTAssertFalse(output.contains(#""code":"VALIDATION_FAILED""#), output)
    }

    func testMailSearchRejectsOldQueryFlagAndUnknownOptions() throws {
        for arguments in [
            ["mail", "search", "--query", "alice", "--json"],
            ["mail", "search", "alice", "--unknown", "value", "--json"],
            ["mail", "search", "alice", "extra", "--json"],
            ["mail", "search", "alice", "--mode", "threads", "--json"],
            ["mail", "search", "alice", "--limit", "0", "--json"],
            ["mail", "search", "alice", "--limit", "101", "--json"],
            ["mail", "search", "alice", "--account"],
        ] {
            let output = try PlainpostCLIProcess.run(arguments)

            XCTAssertTrue(output.contains(#""code":"VALIDATION_FAILED""#), output)
        }
    }

    func testMailReadBodyHonorsRestrictedAgentPermission() throws {
        let output = try PlainpostCLIProcess.run(
            ["mail", "read", "msg_alice_1", "--include", "body", "--json"],
            environment: ["PLAINPOST_AGENT_READ_BODY": "false"]
        )

        XCTAssertTrue(output.contains(#""ok":false"#))
        XCTAssertTrue(output.contains(#""code":"PERMISSION_DENIED""#))
        XCTAssertTrue(output.contains("Actor is not allowed to read message bodies."))
        XCTAssertFalse(output.contains("Can you meet next Tuesday?"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testMailReadAttachmentsHonorsRestrictedAgentPermission() throws {
        let output = try PlainpostCLIProcess.run(
            ["mail", "read", "msg_alice_1", "--include", "attachments", "--json"],
            environment: ["PLAINPOST_AGENT_READ_ATTACHMENTS": "false"]
        )

        XCTAssertTrue(output.contains(#""ok":false"#))
        XCTAssertTrue(output.contains(#""code":"PERMISSION_DENIED""#))
        XCTAssertTrue(output.contains("Actor is not allowed to read attachments."))
        XCTAssertFalse(output.contains(#""attachments""#))
        XCTAssertFalse(output.contains("Can you meet next Tuesday?"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testSmartInboxAndDraftCommandsReturnJSON() throws {
        let smartInbox = try PlainpostCLIProcess.run(["smart-inbox", "show", "--category", "personal", "--json"])
        XCTAssertTrue(smartInbox.contains(#""category":"personal""#))
        XCTAssertTrue(smartInbox.contains(#""subject":"Availability""#))

        let batch = try PlainpostCLIProcess.run([
            "smart-inbox", "batch",
            "newsletters",
            "--action", "archive-read",
            "--json"
        ])
        XCTAssertTrue(batch.contains(#""ok":true"#))
        XCTAssertTrue(batch.contains(#""category":"newsletter""#))
        XCTAssertTrue(batch.contains(#""action":"archive_read""#))
        XCTAssertTrue(batch.contains(#""affected_count":1"#))
        XCTAssertTrue(batch.contains(#""message_ids":["msg_newsletter_1"]"#))
        XCTAssertTrue(batch.contains(#""mailbox":"Archive""#))
        XCTAssertFalse(batch.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(batch.localizedCaseInsensitiveContains("secret"))

        let bodyFile = try TemporaryBodyFile.write("Following up from the CLI.")
        let draft = try PlainpostCLIProcess.run([
            "draft", "create",
            "--to", "alice@example.com",
            "--subject", "CLI Follow up",
            "--body-file", bodyFile.path,
            "--json"
        ])
        XCTAssertTrue(draft.contains(#""ok":true"#))
        XCTAssertTrue(draft.contains(#""draft_id":"drf_cli_1""#))
    }

    func testSmartInboxBatchValidatesInputsAndHonorsMarkSeenPermission() throws {
        let unsupportedAction = try PlainpostCLIProcess.run([
            "smart-inbox", "batch",
            "newsletters",
            "--action", "delete-all",
            "--json"
        ])
        XCTAssertTrue(unsupportedAction.contains(#""ok":false"#))
        XCTAssertTrue(unsupportedAction.contains(#""code":"VALIDATION_FAILED""#))
        XCTAssertTrue(unsupportedAction.contains("Unsupported Smart Inbox batch action."))

        let unsupportedCategory = try PlainpostCLIProcess.run([
            "smart-inbox", "batch",
            "pinned",
            "--action", "archive-read",
            "--json"
        ])
        XCTAssertTrue(unsupportedCategory.contains(#""ok":false"#))
        XCTAssertTrue(unsupportedCategory.contains(#""code":"VALIDATION_FAILED""#))
        XCTAssertTrue(unsupportedCategory.contains("Unsupported Smart Inbox category."))

        let restricted = try PlainpostCLIProcess.run(
            [
                "smart-inbox", "batch",
                "newsletters",
                "--action", "archive-read",
                "--json"
            ],
            environment: ["PLAINPOST_AGENT_MARK_SEEN": "false"]
        )
        XCTAssertTrue(restricted.contains(#""ok":false"#))
        XCTAssertTrue(restricted.contains(#""code":"PERMISSION_DENIED""#))
        XCTAssertTrue(restricted.contains("Actor is not allowed to change seen state."))
        XCTAssertFalse(restricted.contains(#""affected_count":1"#))
        XCTAssertFalse(restricted.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(restricted.localizedCaseInsensitiveContains("secret"))
    }

    func testDraftCreateHonorsRestrictedAgentPermission() throws {
        let bodyFile = try TemporaryBodyFile.write("Restricted agents cannot create this.")
        let output = try PlainpostCLIProcess.run(
            [
                "draft", "create",
                "--to", "alice@example.com",
                "--subject", "Restricted draft",
                "--body-file", bodyFile.path,
                "--json"
            ],
            environment: ["PLAINPOST_AGENT_CREATE_DRAFTS": "false"]
        )

        XCTAssertTrue(output.contains(#""ok":false"#))
        XCTAssertTrue(output.contains(#""code":"PERMISSION_DENIED""#))
        XCTAssertTrue(output.contains("Actor is not allowed to create drafts."))
        XCTAssertFalse(output.contains(#""draft_id":"drf_cli_1""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testSendRequestHonorsRestrictedAgentPermission() throws {
        let output = try PlainpostCLIProcess.run(
            [
                "send", "request",
                "--draft", "drf_reply_1",
                "--agent", "codex",
                "--reason", "User asked me to reply",
                "--json"
            ],
            environment: ["PLAINPOST_AGENT_REQUEST_SEND": "false"]
        )

        XCTAssertTrue(output.contains(#""ok":false"#))
        XCTAssertTrue(output.contains(#""code":"PERMISSION_DENIED""#))
        XCTAssertTrue(output.contains("Actor is not allowed to request sends."))
        XCTAssertFalse(output.contains(#""request_id":"srq_drf_reply_1""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
    }

    func testDraftUpdateAndDeleteCommandsReturnJSONWithoutSending() throws {
        let update = try PlainpostCLIProcess.run([
            "draft", "update",
            "drf_reply_1",
            "--subject", "Updated availability",
            "--body", "Updated local body.",
            "--json"
        ])
        XCTAssertTrue(update.contains(#""draft_id":"drf_reply_1""#))
        XCTAssertTrue(update.contains(#""subject":"Updated availability""#))
        XCTAssertTrue(update.contains(#""sent":false"#))

        let delete = try PlainpostCLIProcess.run(["draft", "delete", "drf_reply_1", "--json"])
        XCTAssertTrue(delete.contains(#""draft_id":"drf_reply_1""#))
        XCTAssertTrue(delete.contains(#""status":"deleted""#))
        XCTAssertFalse(update.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(delete.localizedCaseInsensitiveContains("secret"))
    }

    func testLabelAndRecategorizeCommandsReturnJSONWithoutSecrets() throws {
        let add = try PlainpostCLIProcess.run(["label", "add", "msg_alice_1", "Needs Reply", "--json"])
        XCTAssertTrue(add.contains(#""message_id":"msg_alice_1""#))
        XCTAssertTrue(add.contains(#""labels":["Needs Reply"]"#))

        let remove = try PlainpostCLIProcess.run(["label", "remove", "msg_alice_1", "Needs Reply", "--json"])
        XCTAssertTrue(remove.contains(#""message_id":"msg_alice_1""#))
        XCTAssertTrue(remove.contains(#""labels":[]"#))

        let recategorize = try PlainpostCLIProcess.run([
            "smart-inbox", "recategorize",
            "msg_alice_1",
            "--category", "support",
            "--json"
        ])
        XCTAssertTrue(recategorize.contains(#""message_id":"msg_alice_1""#))
        XCTAssertTrue(recategorize.contains(#""category":"support""#))
        XCTAssertFalse(add.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(recategorize.localizedCaseInsensitiveContains("password"))
    }

    func testLocalMessageMutationCommandsHonorRestrictedAgentPermissions() throws {
        let label = try PlainpostCLIProcess.run(
            ["label", "add", "msg_alice_1", "Needs Reply", "--json"],
            environment: ["PLAINPOST_AGENT_ADD_LABELS": "false"]
        )
        let recategorize = try PlainpostCLIProcess.run(
            ["smart-inbox", "recategorize", "msg_alice_1", "--category", "support", "--json"],
            environment: ["PLAINPOST_AGENT_RECATEGORIZE": "false"]
        )
        XCTAssertTrue(label.contains(#""ok":false"#))
        XCTAssertTrue(label.contains(#""code":"PERMISSION_DENIED""#))
        XCTAssertTrue(label.contains("Actor is not allowed to modify labels."))
        XCTAssertFalse(label.contains(#""labels":["Needs Reply"]"#))

        XCTAssertTrue(recategorize.contains(#""ok":false"#))
        XCTAssertTrue(recategorize.contains(#""code":"PERMISSION_DENIED""#))
        XCTAssertTrue(recategorize.contains("Actor is not allowed to recategorize messages."))
        XCTAssertFalse(recategorize.contains(#""category":"support""#))

        XCTAssertFalse(label.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(recategorize.localizedCaseInsensitiveContains("secret"))
    }

    func testFormerAICommandsUseUnsupportedCommandBehavior() throws {
        for command in [
            ["ai", "summarize-thread", "thr_alice_1", "--json"],
            ["ai", "draft-reply", "thr_alice_1", "--tone", "friendly", "--json"],
            ["ai", "semantic-search", "--query", "Tuesday", "--json"],
            ["ai", "ask", "--question", "What needs a reply?", "--json"],
            ["ai", "index", "status", "--json"],
            ["ai", "provider", "status", "--json"]
        ] {
            let output = try PlainpostCLIProcess.run(command)
            XCTAssertTrue(output.contains(#""code":"VALIDATION_FAILED""#))
            XCTAssertTrue(output.contains("Unsupported command."))
        }
    }

    func testMCPSchemaListsSafeToolsOnly() throws {
        let output = try PlainpostCLIProcess.run(["mcp", "serve", "--schema", "--json"])

        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        let tools = try XCTUnwrap(data["tools"] as? [[String: Any]])
        let search = try XCTUnwrap(tools.first { $0["name"] as? String == "email.search" })
        let schema = try XCTUnwrap(search["input_schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

        XCTAssertTrue(output.contains(#""ok":true"#))
        XCTAssertTrue(output.contains(#""name":"email.search""#))
        XCTAssertFalse(output.contains("email.ai."))
        XCTAssertTrue(output.contains(#""name":"email.smart_inbox_batch""#))
        XCTAssertTrue(output.contains(#""name":"email.request_send""#))
        XCTAssertTrue(output.contains(#""annotations":{"destructiveHint":false,"idempotentHint":false,"openWorldHint":false,"readOnlyHint":true}"#))
        XCTAssertTrue(output.contains("This tool never sends email directly"))
        XCTAssertFalse(output.contains(#""email.send_now""#))
        XCTAssertFalse(output.contains(#""email.approve_send""#))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(output.localizedCaseInsensitiveContains("secret"))
        XCTAssertNil(schema["required"])
        XCTAssertEqual((schema["anyOf"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual((properties["mode"] as? [String: Any])?["enum"] as? [String], ["conversations", "messages"])
        XCTAssertEqual((properties["limit"] as? [String: Any])?["maximum"] as? Int, 100)
        let description = try XCTUnwrap(search["description"] as? String)
        for field in MailSearchFieldRegistry.all {
            XCTAssertTrue(description.contains("\(field.name):"), field.name)
            for example in field.examples {
                XCTAssertTrue(description.contains(example), example)
            }
        }
        XCTAssertTrue(description.contains("next_cursor"))
    }

    func testMCPKeepsStdinWithoutConstructingCredentialDescriptors() throws {
        let request =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
            + "\n"
        let output = try PlainpostCLIProcess.run(
            ["mcp", "serve"],
            standardInput: request
        )

        XCTAssertTrue(
            output.contains(#""protocolVersion":"2024-11-05""#),
            output
        )
        XCTAssertFalse(
            output.localizedCaseInsensitiveContains("password"),
            output
        )
        XCTAssertFalse(
            output.localizedCaseInsensitiveContains("credential"),
            output
        )

        let repositoryRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/PlainpostCLI/PlainpostCLI.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("PlainpostServiceBridge"))
        XCTAssertFalse(source.contains("runPlainpostService"))
        XCTAssertFalse(source.contains("Process()"))
        XCTAssertFalse(source.contains("standardInput ="))
    }

    func testSendRequestStatusAndCancelReturnJSONWithoutDirectSend() throws {
        let request = try PlainpostCLIProcess.run([
            "send", "request",
            "--draft", "drf_reply_1",
            "--agent", "codex",
            "--reason", "User asked me to reply",
            "--json"
        ])
        XCTAssertTrue(request.contains(#""request_id":"srq_drf_reply_1""#))
        XCTAssertFalse(request.contains("sent"))

        let status = try PlainpostCLIProcess.run(["send", "status", "srq_drf_reply_1", "--json"])
        XCTAssertTrue(status.contains(#""status":"pending""#))

        let cancel = try PlainpostCLIProcess.run(["send", "cancel", "srq_drf_reply_1", "--json"])
        XCTAssertTrue(cancel.contains(#""status":"cancelled""#))

        let missingStatus = try PlainpostCLIProcess.run(["send", "status", "srq_missing", "--json"])
        XCTAssertTrue(missingStatus.contains(#""ok":false"#))
        XCTAssertTrue(missingStatus.contains(#""code":"MESSAGE_NOT_FOUND""#))
        XCTAssertTrue(missingStatus.contains("Send request not found."))

        let missingCancel = try PlainpostCLIProcess.run(["send", "cancel", "srq_missing", "--json"])
        XCTAssertTrue(missingCancel.contains(#""ok":false"#))
        XCTAssertTrue(missingCancel.contains(#""code":"MESSAGE_NOT_FOUND""#))
        XCTAssertTrue(missingCancel.contains("Send request not found."))

        let forbidden = try PlainpostCLIProcess.run(["send", "now", "--json"])
        XCTAssertTrue(forbidden.contains(#""ok":false"#))
        XCTAssertTrue(forbidden.contains(#""code":"PERMISSION_DENIED""#))
        XCTAssertFalse(missingStatus.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(missingCancel.localizedCaseInsensitiveContains("secret"))
    }

    func testSendRequestStatusAndCancelPersistAcrossCLIInvocationsWithSQLite() throws {
        let dbURL = TemporarySQLiteFile.url()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let bodyFile = try TemporaryBodyFile.write("Durable send queue body.")

        let draft = try PlainpostCLIProcess.run([
            "draft", "create",
            "--to", "alice@example.com",
            "--subject", "Durable CLI Follow up",
            "--body-file", bodyFile.path,
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(draft.contains(#""ok":true"#))
        XCTAssertTrue(draft.contains(#""draft_id":"drf_cli_1""#))

        let request = try PlainpostCLIProcess.run([
            "send", "request",
            "--draft", "drf_cli_1",
            "--agent", "codex",
            "--reason", "Persist this send request",
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(request.contains(#""request_id":"srq_drf_cli_1""#))
        XCTAssertTrue(request.contains(#""status":"pending""#))
        XCTAssertFalse(request.contains("sent"))

        let status = try PlainpostCLIProcess.run([
            "send", "status",
            "srq_drf_cli_1",
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(status.contains(#""status":"pending""#))

        let cancel = try PlainpostCLIProcess.run([
            "send", "cancel",
            "srq_drf_cli_1",
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(cancel.contains(#""status":"cancelled""#))

        let cancelledStatus = try PlainpostCLIProcess.run([
            "send", "status",
            "srq_drf_cli_1",
            "--db-path", dbURL.path,
            "--json"
        ])
        XCTAssertTrue(cancelledStatus.contains(#""status":"cancelled""#))
        XCTAssertFalse(cancelledStatus.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(cancelledStatus.localizedCaseInsensitiveContains("secret"))
    }

    func testSendQueueUsesDefaultDataDirectoryAcrossCLIInvocations() throws {
        let dataDir = TemporarySQLiteFile.directory()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let bodyFile = try TemporaryBodyFile.write("Default data directory body.")
        let environment = ["PLAINPOST_DATA_DIR": dataDir.path]

        let draft = try PlainpostCLIProcess.run([
            "draft", "create",
            "--to", "alice@example.com",
            "--subject", "Default Store CLI Follow up",
            "--body-file", bodyFile.path,
            "--json"
        ], environment: environment)
        XCTAssertTrue(draft.contains(#""ok":true"#))
        XCTAssertTrue(draft.contains(#""draft_id":"drf_cli_1""#))

        let request = try PlainpostCLIProcess.run([
            "send", "request",
            "--draft", "drf_cli_1",
            "--agent", "codex",
            "--reason", "Use configured default data directory",
            "--json"
        ], environment: environment)
        XCTAssertTrue(request.contains(#""request_id":"srq_drf_cli_1""#))
        XCTAssertTrue(request.contains(#""status":"pending""#))

        let status = try PlainpostCLIProcess.run([
            "send", "status",
            "srq_drf_cli_1",
            "--json"
        ], environment: environment)
        XCTAssertTrue(status.contains(#""status":"pending""#))

        let cancel = try PlainpostCLIProcess.run([
            "send", "cancel",
            "srq_drf_cli_1",
            "--json"
        ], environment: environment)
        XCTAssertTrue(cancel.contains(#""status":"cancelled""#))

        let cancelledStatus = try PlainpostCLIProcess.run([
            "send", "status",
            "srq_drf_cli_1",
            "--json"
        ], environment: environment)
        XCTAssertTrue(cancelledStatus.contains(#""status":"cancelled""#))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("Plainpost.sqlite").path))
        XCTAssertFalse(cancelledStatus.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(cancelledStatus.localizedCaseInsensitiveContains("secret"))
    }
}

private enum TemporaryBodyFile {
    static func write(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-body-\(UUID().uuidString).txt")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private enum TemporarySQLiteFile {
    static func url() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-\(UUID().uuidString).sqlite")
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plainpost-cli-data-\(UUID().uuidString)", isDirectory: true)
    }
}

private enum PlainpostCLIProcess {
    static func run(
        _ arguments: [String],
        environment: [String: String] = [:],
        standardInput: String? = nil,
        executableURL: URL? = nil,
        timeout: TimeInterval = 45
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL ?? productsDirectory.appendingPathComponent("plainpost")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let inputPipe = standardInput.map { _ in Pipe() }
        process.standardInput = inputPipe
        try process.run()
        if let standardInput, let inputPipe {
            inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try inputPipe.fileHandleForWriting.close()
        }
        try PlainpostProcessWaiter.waitForExit(process, timeout: timeout)

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not find products directory")
    }
}

private enum PlainpostServiceProcess {
    struct Result {
        let status: Int32
        let output: String
    }

    static func run(_ arguments: [String]) throws -> Result {
        let executable = productsDirectory.appendingPathComponent("PlainpostService")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        try PlainpostProcessWaiter.waitForExit(process, timeout: 15)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private static var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("could not find products directory")
    }
}

private enum PlainpostProcessWaiter {
    private enum TimeoutError: LocalizedError {
        case timedOut(pid_t)
        case failedToKill(pid_t)
        case failedToReap(pid_t)

        var errorDescription: String? {
            switch self {
            case .timedOut(let pid):
                "Process \(pid) timed out and was terminated."
            case .failedToKill(let pid):
                "Process \(pid) timed out and could not be killed."
            case .failedToReap(let pid):
                "Process \(pid) timed out and could not be reaped."
            }
        }
    }

    static func waitForExit(_ process: Process, timeout: TimeInterval) throws {
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            let pid = process.processIdentifier
            process.terminate()

            if exited.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning, Darwin.kill(pid, SIGKILL) != 0, errno != ESRCH {
                    throw TimeoutError.failedToKill(pid)
                }
                guard exited.wait(timeout: .now() + 1) == .success else {
                    throw TimeoutError.failedToReap(pid)
                }
            }
            throw TimeoutError.timedOut(pid)
        }
    }
}
